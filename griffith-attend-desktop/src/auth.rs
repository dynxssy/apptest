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

    /// Manual SSO: open the browser, user logs in with Microsoft, pastes payload.
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
