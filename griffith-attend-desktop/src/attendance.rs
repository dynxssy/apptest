//! Timetable & attendance REST client. Mirrors the original `AttendanceService`.

use anyhow::Result;
use chrono::{DateTime, Duration, TimeZone, Utc};
use serde_json::Value;

use crate::auth::AuthService;
use crate::config::{Config, ATTENDANCE_BAD, ATTENDANCE_WARNING};

#[derive(Clone, Debug)]
pub struct Lesson {
    pub lesson_id: String,
    pub module_name: String,
    pub module_code: String,
    pub lecturer: String,
    pub room: String,
    pub start: String,
    pub end: String,
    /// iBeacon `major` value for this room.
    pub bluetooth_id: i64,
    pub mobile_enabled: bool,
}

fn s(v: &Value, k: &str) -> String {
    v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string()
}

impl Lesson {
    pub fn from_json(v: &Value) -> Self {
        let lesson_id = {
            let a = s(v, "lesson_id");
            if a.is_empty() { s(v, "_id") } else { a }
        };
        let bluetooth_id = v
            .get("bluetooth_id")
            .map(|x| x.as_i64().or_else(|| x.as_str().and_then(|t| t.parse().ok())).unwrap_or(0))
            .unwrap_or(0);
        let mobile_enabled = v.get("mobile_enabled").and_then(|x| x.as_bool()).unwrap_or(true);
        Self {
            lesson_id,
            module_name: s(v, "module_name"),
            module_code: s(v, "module_code"),
            lecturer: s(v, "lecturer"),
            room: s(v, "room"),
            start: s(v, "start"),
            end: s(v, "end"),
            bluetooth_id,
            mobile_enabled,
        }
    }

    pub fn start_dt(&self) -> DateTime<Utc> {
        parse_utc(&self.start)
    }
    pub fn end_dt(&self) -> DateTime<Utc> {
        parse_utc(&self.end)
    }

    pub fn is_in_progress(&self, now: DateTime<Utc>, early_minutes: i64) -> bool {
        let window_start = self.start_dt() - Duration::minutes(early_minutes);
        window_start <= now && now <= self.end_dt()
    }
}

#[derive(Clone, Debug)]
pub struct AttendanceRecord {
    pub attendance_id: String,
    pub status: String,
    pub lesson_id: String,
}

impl AttendanceRecord {
    pub fn from_json(v: &Value) -> Self {
        let attendance_id = {
            let a = s(v, "_id");
            if a.is_empty() { s(v, "id") } else { a }
        };
        let status = {
            let st = s(v, "status");
            if st.is_empty() { "not-recorded".to_string() } else { st }
        };
        Self { attendance_id, status, lesson_id: s(v, "lesson_id") }
    }
}

#[derive(Clone, Debug)]
pub struct ModuleReport {
    pub module_name: String,
    pub module_code: String,
    pub attendance_percentage: f64,
    pub attended: i64,
    pub total: i64,
}

impl ModuleReport {
    pub fn from_json(v: &Value) -> Self {
        let f = |k: &str| v.get(k).and_then(|x| x.as_f64()).unwrap_or(0.0);
        let i = |k: &str| v.get(k).and_then(|x| x.as_i64()).unwrap_or(0);
        Self {
            module_name: s(v, "module_name"),
            module_code: s(v, "module_code"),
            attendance_percentage: f("attendance_percentage"),
            attended: i("attended"),
            total: i("total"),
        }
    }

    pub fn colour(&self) -> &'static str {
        if self.attendance_percentage < ATTENDANCE_BAD {
            "danger"
        } else if self.attendance_percentage < ATTENDANCE_WARNING {
            "warning"
        } else {
            "success"
        }
    }
}

pub struct AttendanceService {
    cfg: Config,
    http: reqwest::Client,
}

impl AttendanceService {
    pub fn new(cfg: Config, http: reqwest::Client) -> Self {
        Self { cfg, http }
    }

    /// GET with a single 401 → refresh → retry, mirroring the original client.
    async fn get(&self, auth: &mut AuthService, url: &str) -> Result<Value> {
        let resp = self.http.get(url).headers(auth.auth_headers()).send().await?;
        let resp = if resp.status().as_u16() == 401 {
            let _ = auth.refresh_token().await;
            self.http.get(url).headers(auth.auth_headers()).send().await?
        } else {
            resp
        };
        Ok(resp.error_for_status()?.json().await?)
    }

    pub async fn get_timetable(&self, auth: &mut AuthService) -> Result<Vec<Lesson>> {
        let uid = auth.uid()?;
        let raw = self.get(auth, &self.cfg.timetable_url(&uid)).await?;
        let arr = raw
            .get("timetables")
            .or_else(|| raw.get("lessons"))
            .and_then(|x| x.as_array())
            .cloned()
            .unwrap_or_default();
        Ok(arr.iter().map(Lesson::from_json).collect())
    }

    pub async fn get_lesson(&self, auth: &mut AuthService, lesson_id: &str) -> Result<Value> {
        let uid = auth.uid()?;
        self.get(auth, &self.cfg.lesson_url(lesson_id, &uid)).await
    }

    pub fn current_lessons(&self, lessons: &[Lesson]) -> Vec<Lesson> {
        let now = Utc::now();
        lessons
            .iter()
            .filter(|l| l.is_in_progress(now, crate::config::CHECKIN_EARLY_MINUTES))
            .cloned()
            .collect()
    }

    pub async fn get_attendance(&self, auth: &mut AuthService, lesson_id: &str) -> Result<Value> {
        let uid = auth.uid()?;
        self.get(auth, &self.cfg.attendance_for_lesson_url(&uid, lesson_id)).await
    }

    /// PUT /api/v2/attendance/{attendance_id}/{uid} — mark present.
    /// Called only after a real beacon match (see `checkin`).
    pub async fn set_attendance(
        &self,
        auth: &mut AuthService,
        attendance_id: &str,
        lesson_id: &str,
    ) -> Result<Value> {
        let uid = auth.uid()?;
        let payload = serde_json::json!({
            "attendanceStatus": "present",
            "attendanceSource": "api",
            "recordedAt": Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true),
            "lesson_id": lesson_id,
        });
        let resp = self
            .http
            .put(self.cfg.set_attendance_url(attendance_id, &uid))
            .headers(auth.auth_headers())
            .json(&payload)
            .send()
            .await?
            .error_for_status()?;
        Ok(resp.json().await?)
    }

    pub async fn update_attendance(&self, auth: &mut AuthService, attendance_id: &str) -> Result<Value> {
        let uid = auth.uid()?;
        let resp = self
            .http
            .patch(self.cfg.patch_attendance_url(attendance_id, &uid))
            .headers(auth.auth_headers())
            .json(&serde_json::json!({ "status": "P" }))
            .send()
            .await?
            .error_for_status()?;
        Ok(resp.json().await?)
    }

    pub async fn get_modules(&self, auth: &mut AuthService) -> Result<Vec<ModuleReport>> {
        let uid = auth.uid()?;
        let raw = self.get(auth, &self.cfg.reports_url(&uid)).await?;
        let arr = raw
            .get("modules")
            .and_then(|x| x.as_array())
            .cloned()
            .or_else(|| raw.as_array().cloned())
            .unwrap_or_default();
        Ok(arr.iter().map(ModuleReport::from_json).collect())
    }

    pub async fn get_api_version(&self, auth: &mut AuthService) -> Result<Value> {
        let url = format!(
            "{}?t={}",
            self.cfg.info_url(),
            Utc::now().timestamp()
        );
        self.get(auth, &url).await
    }
}

/// Parse an ISO 8601 UTC timestamp, tolerating a few shapes.
fn parse_utc(s: &str) -> DateTime<Utc> {
    if s.is_empty() {
        return Utc.timestamp_opt(0, 0).unwrap();
    }
    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return dt.with_timezone(&Utc);
    }
    let trimmed = s.trim_end_matches('Z');
    for fmt in [
        "%Y-%m-%dT%H:%M:%S%.f",
        "%Y-%m-%dT%H:%M:%S",
        "%Y-%m-%d %H:%M:%S",
    ] {
        if let Ok(ndt) = chrono::NaiveDateTime::parse_from_str(trimmed, fmt) {
            return Utc.from_utc_datetime(&ndt);
        }
    }
    Utc.timestamp_opt(0, 0).unwrap()
}
