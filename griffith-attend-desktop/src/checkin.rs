//! Beacon-gated check-in orchestration.
//!
//! A lesson is only checked in when ALL of these hold:
//!   * the lesson is currently in progress, and
//!   * `mobile_enabled` is true for it, and
//!   * the live BLE scan physically detected a beacon whose `major` equals the
//!     lesson's `bluetooth_id`, and
//!   * that beacon's signal is at least `min_rssi` (the proximity gate).
//!
//! There is no manual/forced path and no simulated beacon — presence is
//! required, enforced by the scanner and the checks below.

use std::collections::HashMap;

use anyhow::Result;

use crate::attendance::{AttendanceRecord, AttendanceService, Lesson};
use crate::auth::AuthService;
use crate::beacon::BeaconScanner;
use crate::config::{Config, CHECKIN_RETRY_BASE_DELAY_SECS, MAX_CHECKIN_RETRIES, RANGING_SECONDS};

#[derive(Clone)]
pub struct CheckInResult {
    pub module_name: String,
    pub success: bool,
    pub message: String,
}

impl std::fmt::Display for CheckInResult {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let icon = if self.success { "[OK]" } else { "[--]" };
        write!(f, "{icon} {}: {}", self.module_name, self.message)
    }
}

pub struct CheckInService {
    cfg: Config,
    scanner: BeaconScanner,
    attempts: HashMap<String, u32>,
}

impl CheckInService {
    pub fn new(cfg: Config) -> Self {
        let scanner = BeaconScanner::new(&cfg.beacon_uuid, RANGING_SECONDS);
        Self { cfg, scanner, attempts: HashMap::new() }
    }

    /// One full cycle: refresh timetable, scan once, check in any matched lessons.
    pub async fn run_once(
        &mut self,
        auth: &mut AuthService,
        svc: &AttendanceService,
    ) -> Result<Vec<CheckInResult>> {
        let lessons = match svc.get_timetable(auth).await {
            Ok(l) => l,
            Err(e) => {
                eprintln!("Failed to fetch timetable: {e}");
                return Ok(vec![]);
            }
        };
        let current = svc.current_lessons(&lessons);
        if current.is_empty() {
            println!("No lessons in progress right now.");
            return Ok(vec![]);
        }
        println!(
            "{} lesson(s) in progress. Scanning for beacons (~{}s)...",
            current.len(),
            RANGING_SECONDS
        );

        let beacons = match self.scanner.scan().await {
            Ok(b) => b,
            Err(e) => {
                eprintln!("BLE scan failed: {e}");
                return Ok(vec![]);
            }
        };
        println!(
            "Detected {} matching beacon(s): {:?}",
            beacons.len(),
            beacons.iter().map(|b| (b.major, b.rssi)).collect::<Vec<_>>()
        );

        let mut results = vec![];
        for lesson in &current {
            if !lesson.mobile_enabled {
                continue;
            }
            // Strongest matching beacon for this room.
            let matched = beacons
                .iter()
                .filter(|b| b.major == lesson.bluetooth_id)
                .max_by_key(|b| b.rssi);

            let Some(beacon) = matched else { continue };

            // Proximity gate: a detected-but-distant beacon is not "in the room".
            if beacon.rssi < self.cfg.min_rssi {
                println!(
                    "Beacon for {} seen but too weak ({} dBm < {} dBm) - not close enough, skipping.",
                    lesson.module_name, beacon.rssi, self.cfg.min_rssi
                );
                continue;
            }

            println!(
                "Beacon matched for {} (major={}, rssi={} dBm, {}).",
                lesson.module_name,
                beacon.major,
                beacon.rssi,
                beacon.proximity()
            );
            let r = self.checkin(auth, svc, lesson).await;
            println!("{r}");
            results.push(r);
        }
        Ok(results)
    }

    /// Continuous loop. `max_iterations == None` runs until interrupted.
    pub async fn run_loop(
        &mut self,
        auth: &mut AuthService,
        svc: &AttendanceService,
        max_iterations: Option<u32>,
    ) -> Result<()> {
        let mut i = 0u32;
        loop {
            self.run_once(auth, svc).await?;
            i += 1;
            if let Some(max) = max_iterations {
                if i >= max {
                    break;
                }
            }
            tokio::time::sleep(std::time::Duration::from_secs(RANGING_SECONDS)).await;
        }
        Ok(())
    }

    async fn checkin(
        &mut self,
        auth: &mut AuthService,
        svc: &AttendanceService,
        lesson: &Lesson,
    ) -> CheckInResult {
        let attempt = *self.attempts.get(&lesson.lesson_id).unwrap_or(&0);
        let raw = match svc.get_attendance(auth, &lesson.lesson_id).await {
            Ok(v) => v,
            Err(e) => {
                self.schedule_retry(lesson, attempt, &e.to_string()).await;
                return CheckInResult {
                    module_name: lesson.module_name.clone(),
                    success: false,
                    message: format!("Check-in error: {e}"),
                };
            }
        };

        let attendances = raw.get("attendances").and_then(|a| a.as_array()).cloned().unwrap_or_default();
        if attendances.is_empty() {
            let msg = "No attendance placeholder found (server not ready)".to_string();
            self.schedule_retry(lesson, attempt, &msg).await;
            return CheckInResult { module_name: lesson.module_name.clone(), success: false, message: msg };
        }

        let record = AttendanceRecord::from_json(&attendances[0]);
        if !record.status.is_empty() && record.status != "not-recorded" {
            return CheckInResult {
                module_name: lesson.module_name.clone(),
                success: true,
                message: format!("Already recorded as '{}' - skipping", record.status),
            };
        }

        match svc.set_attendance(auth, &record.attendance_id, &lesson.lesson_id).await {
            Ok(_) => {
                self.attempts.remove(&lesson.lesson_id);
                CheckInResult {
                    module_name: lesson.module_name.clone(),
                    success: true,
                    message: format!("Marked present (attendance_id={})", record.attendance_id),
                }
            }
            Err(e) => {
                self.schedule_retry(lesson, attempt, &e.to_string()).await;
                CheckInResult {
                    module_name: lesson.module_name.clone(),
                    success: false,
                    message: format!("Check-in error: {e}"),
                }
            }
        }
    }

    async fn schedule_retry(&mut self, lesson: &Lesson, attempt: u32, reason: &str) {
        if attempt >= MAX_CHECKIN_RETRIES {
            eprintln!(
                "Giving up check-in for {} after {} attempts. Reason: {}",
                lesson.module_name, attempt, reason
            );
            return;
        }
        let delay = CHECKIN_RETRY_BASE_DELAY_SECS * 2f64.powi(attempt as i32);
        println!(
            "Scheduling retry #{} for {} in {:.1}s. Reason: {}",
            attempt + 1,
            lesson.module_name,
            delay,
            reason
        );
        self.attempts.insert(lesson.lesson_id.clone(), attempt + 1);
    }
}
