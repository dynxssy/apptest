//! Authentication against the Griffith attend API.
//!
//! The mobile app logs in through Microsoft SSO + MFA in an in-app browser and
//! receives a JWT (`token`) plus a `refreshToken`. On the desktop we reproduce
//! only the legitimate parts of that flow:
//!
//!   1. Open the real SSO URL in the user's own system browser.
//!   2. The user completes Microsoft SSO + MFA themselves.
//!   3. The user copies the auth JSON payload (from the Network tab / console)
//!      and pastes it once; we persist the session like Ionic Storage did.
//!
//! There is no credential capture or automation here — the user authenticates
//! directly with Microsoft in their own browser, exactly as on the phone.

use std::io::{self, Write};
use std::path::PathBuf;

use anyhow::{anyhow, Context, Result};
use chrono::Utc;
use serde::{Deserialize, Serialize};

use crate::config::Config;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct User {
    #[serde(default)]
    pub user_id: String,
    #[serde(default)]
    pub email: String,
    #[serde(default)]
    pub token: String,
    #[serde(default, rename = "refreshToken", alias = "refresh_token")]
    pub refresh_token: String,
    #[serde(default)]
    pub first_name: String,
    #[serde(default)]
    pub last_name: String,
}

impl User {
    pub fn full_name(&self) -> String {
        let n = format!("{} {}", self.first_name, self.last_name);
        let n = n.trim().to_string();
        if n.is_empty() {
            self.email.clone()
        } else {
            n
        }
    }

    /// Accept the various payload shapes the SSO page may emit.
    fn from_json(v: &serde_json::Value) -> Self {
        let get = |k: &str| v.get(k).and_then(|x| x.as_str()).unwrap_or("").to_string();
        let user_id = {
            let a = get("user_id");
            if a.is_empty() { get("_id") } else { a }
        };
        let refresh = {
            let a = get("refreshToken");
            if a.is_empty() { get("refresh_token") } else { a }
        };
        let (mut first, mut last) = (get("first_name"), get("last_name"));
        if first.is_empty() && last.is_empty() {
            let full = get("fullname");
            let mut parts = full.splitn(2, ' ');
            first = parts.next().unwrap_or("").to_string();
            last = parts.next().unwrap_or("").to_string();
        }
        Self {
            user_id,
            email: get("email"),
            token: get("token"),
            refresh_token: refresh,
            first_name: first,
            last_name: last,
        }
    }
}

pub struct AuthService {
    pub user: Option<User>,
    cfg: Config,
    http: reqwest::Client,
    session_file: PathBuf,
}

impl AuthService {
    pub fn new(cfg: Config, http: reqwest::Client) -> Self {
        let session_file = dirs::home_dir()
            .unwrap_or_else(|| PathBuf::from("."))
            .join(".griffith_attendance_session.json");
        let user = std::fs::read_to_string(&session_file)
            .ok()
            .and_then(|s| serde_json::from_str::<User>(&s).ok());
        Self { user, cfg, http, session_file }
    }

    pub fn is_authenticated(&self) -> bool {
        self.user.as_ref().map(|u| !u.token.is_empty()).unwrap_or(false)
    }

    pub fn has_refresh_token(&self) -> bool {
        self.user.as_ref().map(|u| !u.refresh_token.is_empty()).unwrap_or(false)
    }

    /// Seconds until the current access token's `exp`, if it can be decoded.
    /// `None` means we could not read an expiry (e.g. opaque token) — in that
    /// case we leave it to the normal 401 → refresh path rather than guessing.
    pub fn token_ttl_secs(&self) -> Option<i64> {
        let token = &self.user.as_ref()?.token;
        let exp = jwt_exp(token)?;
        Some(exp - Utc::now().timestamp())
    }

    /// True when the access token is expired, or within `leeway_secs` of it.
    pub fn token_expired(&self, leeway_secs: i64) -> bool {
        match self.token_ttl_secs() {
            Some(ttl) => ttl <= leeway_secs,
            None => false,
        }
    }

    /// Ensure a usable session at startup without forcing a fresh SSO login
    /// whenever possible: if the access token is expired but a refresh token
    /// is present, refresh silently; only return false when we genuinely need
    /// the user to log in again.
    pub async fn ensure_session(&mut self) -> bool {
        if !self.is_authenticated() {
            return false;
        }
        if self.token_expired(60) && self.has_refresh_token() {
            match self.refresh_token().await {
                Ok(Some(_)) => return true,
                _ => return false, // refresh token itself expired/invalid
            }
        }
        true
    }

    pub fn auth_headers(&self) -> reqwest::header::HeaderMap {
        use reqwest::header::{HeaderMap, HeaderValue, AUTHORIZATION, CONTENT_TYPE};
        let mut h = HeaderMap::new();
        h.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        if let Some(u) = &self.user {
            if !u.token.is_empty() {
                if let Ok(v) = HeaderValue::from_str(&format!("Bearer {}", u.token)) {
                    h.insert(AUTHORIZATION, v);
                }
            }
        }
        h
    }

    pub fn uid(&self) -> Result<String> {
        self.user
            .as_ref()
            .map(|u| u.user_id.clone())
            .ok_or_else(|| anyhow!("Not authenticated"))
    }

    /// Open the real SSO URL in the user's own system browser.
    pub fn open_sso(&self) {
        let _ = webbrowser::open(&self.cfg.sso_url());
    }

    /// Parse, validate and persist a pasted SSO auth payload. Shared by the CLI
    /// and GUI front-ends so there is one login code path.
    pub fn login_from_json(&mut self, raw: &str) -> Result<&User> {
        let v: serde_json::Value =
            serde_json::from_str(raw.trim()).context("That was not valid JSON")?;
        let user = User::from_json(&v);
        if user.token.is_empty() || user.user_id.is_empty() {
            return Err(anyhow!(
                "Payload is missing `token` and/or `user_id` — check you copied the right response."
            ));
        }
        self.user = Some(user);
        self.save();
        Ok(self.user.as_ref().unwrap())
    }

    /// Manual SSO (terminal): open the browser, user logs in, pastes payload.
    pub fn sso_login(&mut self) -> Result<&User> {
        let url = self.cfg.sso_url();
        println!("\n{}", "=".repeat(60));
        println!("  GRIFFITH SSO LOGIN");
        println!("{}", "=".repeat(60));
        println!("\n1. Opening the login page in your browser:\n   {url}");
        println!("   Complete your Microsoft login + MFA there, as on the phone.\n");
        println!("2. Once you reach the 'logging in' page, open DevTools (F12) and");
        println!("   grab the auth payload with EITHER:");
        println!("     • Network tab → filter 'logging_in' or 'token' → copy the JSON response, or");
        println!("     • Console (run BEFORE logging in):");
        println!("         window.addEventListener('message', e => console.log(JSON.stringify(e.data)))");
        println!("       then copy the printed JSON after login.\n");
        println!("3. Paste that JSON below.\n");
        println!("{}", "=".repeat(60));

        let _ = webbrowser::open(&url);

        print!("\nPaste the auth JSON and press Enter:\n> ");
        io::stdout().flush().ok();
        let mut raw = String::new();
        io::stdin().read_line(&mut raw)?;
        self.login_from_json(&raw)?;
        println!("\n[Auth] Logged in as {}", self.user.as_ref().unwrap().full_name());
        Ok(self.user.as_ref().unwrap())
    }

    /// POST /api/v2/token/refresh — exchange the refresh token for a new JWT.
    pub async fn refresh_token(&mut self) -> Result<Option<String>> {
        let refresh = self
            .user
            .as_ref()
            .map(|u| u.refresh_token.clone())
            .ok_or_else(|| anyhow!("No user session to refresh"))?;

        let resp = self
            .http
            .post(self.cfg.refresh_url())
            .json(&serde_json::json!({ "refreshToken": refresh }))
            .send()
            .await?
            .error_for_status()?;
        let data: serde_json::Value = resp.json().await?;
        let new_token = data.get("token").and_then(|t| t.as_str()).map(String::from);
        if let (Some(tok), Some(u)) = (&new_token, self.user.as_mut()) {
            u.token = tok.clone();
            self.save();
        }
        Ok(new_token)
    }

    pub async fn logout(&mut self) {
        if self.user.is_some() {
            let _ = self
                .http
                .post(self.cfg.logout_url())
                .headers(self.auth_headers())
                .send()
                .await;
        }
        self.user = None;
        let _ = std::fs::remove_file(&self.session_file);
    }

    fn save(&self) {
        if let Some(u) = &self.user {
            if let Ok(s) = serde_json::to_string_pretty(u) {
                let _ = std::fs::write(&self.session_file, s);
            }
        }
    }
}

/// Read the `exp` claim (seconds since epoch) from a JWT without verifying its
/// signature — we only use it to decide whether to refresh proactively.
fn jwt_exp(token: &str) -> Option<i64> {
    let payload_b64 = token.split('.').nth(1)?;
    let bytes = base64url_decode(payload_b64)?;
    let v: serde_json::Value = serde_json::from_slice(&bytes).ok()?;
    v.get("exp").and_then(|e| e.as_i64())
}

/// Minimal base64url decoder (no padding), enough for a JWT payload segment.
fn base64url_decode(s: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        match c {
            b'A'..=b'Z' => Some((c - b'A') as u32),
            b'a'..=b'z' => Some((c - b'a' + 26) as u32),
            b'0'..=b'9' => Some((c - b'0' + 52) as u32),
            b'-' => Some(62),
            b'_' => Some(63),
            _ => None,
        }
    }
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let mut buf = 0u32;
    let mut bits = 0u32;
    for &c in s.as_bytes() {
        if c == b'=' {
            break;
        }
        let v = val(c)?;
        buf = (buf << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_jwt_exp() {
        // header.payload.signature — payload = {"exp":1700000000,"sub":"x"}
        let payload = "eyJleHAiOjE3MDAwMDAwMDAsInN1YiI6IngifQ";
        let token = format!("aaa.{payload}.bbb");
        assert_eq!(jwt_exp(&token), Some(1700000000));
    }

    #[test]
    fn opaque_token_has_no_exp() {
        assert_eq!(jwt_exp("not-a-jwt"), None);
    }
}
