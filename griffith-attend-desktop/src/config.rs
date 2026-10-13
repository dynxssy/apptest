//! Configuration constants.
//!
//! Endpoint paths mirror the original Angular `AttendanceService` as documented
//! in the reference Python port. The base URL can be overridden with the
//! `GRIFFITH_BASE_URL` environment variable so the client is not hard-wired to
//! one deployment.

use std::time::Duration;

/// Default API base. Override with `GRIFFITH_BASE_URL`.
pub const DEFAULT_BASE_URL: &str = "https://attend.griffith.ie";

/// iBeacon proximity UUID used by the Griffith room beacons.
pub const BEACON_UUID: &str = "00112233-4455-6677-8899-AABBCCDDEEFC";

/// How long each BLE ranging cycle lasts.
pub const RANGING_SECONDS: u64 = 10;

/// Allow check-in this many minutes before a lesson's official start.
pub const CHECKIN_EARLY_MINUTES: i64 = 0;

/// Retry budget for a transient check-in failure.
pub const MAX_CHECKIN_RETRIES: u32 = 3;
pub const CHECKIN_RETRY_BASE_DELAY_SECS: f64 = 2.0;

/// HTTP request timeout.
pub const HTTP_TIMEOUT: Duration = Duration::from_secs(20);

/// Presence gate. A matched beacon must be at least this strong (dBm) for a
/// check-in to proceed. This is the safeguard that keeps "detected a beacon"
/// honest: a faint signal bleeding through a wall from the next room does not
/// count as being in the room. Override with `GRIFFITH_MIN_RSSI`.
pub const DEFAULT_MIN_RSSI: i16 = -80;

/// Attendance-percentage thresholds for the report colouring.
pub const ATTENDANCE_BAD: f64 = 70.0;
pub const ATTENDANCE_WARNING: f64 = 80.0;

/// Resolved runtime configuration.
#[derive(Clone)]
pub struct Config {
    pub base_url: String,
    pub beacon_uuid: String,
    pub min_rssi: i16,
}

impl Config {
    pub fn from_env() -> Self {
        let base_url = std::env::var("GRIFFITH_BASE_URL")
            .unwrap_or_else(|_| DEFAULT_BASE_URL.to_string())
            .trim_end_matches('/')
            .to_string();
        let min_rssi = std::env::var("GRIFFITH_MIN_RSSI")
            .ok()
            .and_then(|v| v.parse().ok())
            .unwrap_or(DEFAULT_MIN_RSSI);
        Self {
            base_url,
            beacon_uuid: BEACON_UUID.to_string(),
            min_rssi,
        }
    }

    pub fn timetable_url(&self, uid: &str) -> String {
        format!("{}/api/v2/timetable/student/{}", self.base_url, uid)
    }
    pub fn lesson_url(&self, lesson_id: &str, uid: &str) -> String {
        format!("{}/api/v2/timetable/lesson/{}/{}", self.base_url, lesson_id, uid)
    }
    pub fn attendance_for_lesson_url(&self, uid: &str, lesson_id: &str) -> String {
        format!("{}/api/v2/attendance/student/{}/lesson/{}", self.base_url, uid, lesson_id)
    }
    pub fn set_attendance_url(&self, attendance_id: &str, uid: &str) -> String {
        format!("{}/api/v2/attendance/{}/{}", self.base_url, attendance_id, uid)
    }
    pub fn patch_attendance_url(&self, attendance_id: &str, uid: &str) -> String {
        format!("{}/api/v2/attendance/id/{}/{}", self.base_url, attendance_id, uid)
    }
    pub fn reports_url(&self, uid: &str) -> String {
        format!("{}/api/v2/reports/{}", self.base_url, uid)
    }
    pub fn refresh_url(&self) -> String {
        format!("{}/api/v2/token/refresh", self.base_url)
    }
    pub fn info_url(&self) -> String {
        format!("{}/api/v2/info", self.base_url)
    }
    pub fn logout_url(&self) -> String {
        format!("{}/api/auth/logout", self.base_url)
    }
    pub fn sso_url(&self) -> String {
        format!("{}/?next=/logging_in", self.base_url)
    }
}
