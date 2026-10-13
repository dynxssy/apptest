//! Griffith College attendance — unofficial desktop client (Linux/macOS).
//!
//! A faithful port of the mobile client's legitimate behaviour: SSO login,
//! timetable, attendance report, token refresh, and beacon-gated check-in.
//! Check-in requires a live Bluetooth detection of the room's iBeacon (plus a
//! proximity gate) — there is no simulated or manual-override path.

// Some endpoint helpers and beacon fields mirror the original API surface for
// completeness even though the CLI does not call every one yet.
#![allow(dead_code)]

mod attendance;
mod auth;
mod beacon;
mod checkin;
mod config;

use std::io::{self, Write};

use anyhow::Result;
use chrono::{Local, Utc};

use attendance::{AttendanceService, Lesson, ModuleReport};
use auth::AuthService;
use checkin::CheckInService;
use config::Config;

#[tokio::main]
async fn main() -> Result<()> {
    let cfg = Config::from_env();
    let http = reqwest::Client::builder()
        .timeout(config::HTTP_TIMEOUT)
        .build()?;

    let mut auth = AuthService::new(cfg.clone(), http.clone());
    let svc = AttendanceService::new(cfg.clone(), http.clone());

    banner(&cfg);

    // Try to resume the saved session first. If the access token has expired
    // but the refresh token is still valid, this refreshes silently so you are
    // not sent back to the Microsoft login every time you open the app.
    if auth.ensure_session().await {
        if let Some(ttl) = auth.token_ttl_secs() {
            println!(
                "Logged in as {} (session valid ~{} min).",
                auth.user.as_ref().unwrap().full_name(),
                (ttl / 60).max(0)
            );
        } else {
            println!("Logged in as {}", auth.user.as_ref().unwrap().full_name());
        }
    } else {
        if auth.is_authenticated() {
            println!("Your saved session has fully expired. Please log in again.");
        } else {
            println!("No active session. Please log in.");
        }
        if let Err(e) = auth.sso_login() {
            eprintln!("Login failed: {e}");
            return Ok(());
        }
    }

    let mut lessons_cache: Vec<Lesson> = vec![];

    loop {
        println!("\nMain Menu");
        println!("  1 - Today's timetable");
        println!("  2 - Full timetable (all upcoming)");
        println!("  3 - Attendance report");
        println!("  4 - Check in to current lesson (one live beacon scan)");
        println!("  5 - Auto check-in loop (live beacon scanning)");
        println!("  6 - Refresh token");
        println!("  7 - Logout");
        println!("  0 - Exit");
        let choice = prompt("\nChoice: ");

        match choice.as_str() {
            "1" => show_today(&mut auth, &svc, &mut lessons_cache).await,
            "2" => show_all(&mut auth, &svc, &mut lessons_cache).await,
            "3" => show_report(&mut auth, &svc).await,
            "4" => {
                let mut ci = CheckInService::new(cfg.clone());
                if let Err(e) = ci.run_once(&mut auth, &svc).await {
                    eprintln!("Error: {e}");
                }
            }
            "5" => auto_loop(&mut auth, &svc, &cfg).await,
            "6" => match auth.refresh_token().await {
                Ok(Some(_)) => println!("Token refreshed successfully."),
                Ok(None) => println!("Token refresh returned no new token."),
                Err(e) => eprintln!("Error refreshing token: {e}"),
            },
            "7" => {
                auth.logout().await;
                println!("Logged out.");
                break;
            }
            "0" => {
                println!("Goodbye!");
                break;
            }
            _ => println!("Invalid choice."),
        }
    }
    Ok(())
}

fn banner(cfg: &Config) {
    println!("==================================================");
    println!("  Griffith College Attendance - Desktop (unofficial)");
    println!("  {}", cfg.base_url);
    println!("  Check-in requires live beacon presence (min {} dBm)", cfg.min_rssi);
    println!("==================================================");
}

fn prompt(msg: &str) -> String {
    print!("{msg}");
    io::stdout().flush().ok();
    let mut s = String::new();
    io::stdin().read_line(&mut s).ok();
    s.trim().to_string()
}

async fn fetch_lessons(
    auth: &mut AuthService,
    svc: &AttendanceService,
    cache: &mut Vec<Lesson>,
    force: bool,
) -> Vec<Lesson> {
    if cache.is_empty() || force {
        println!("Fetching timetable...");
        match svc.get_timetable(auth).await {
            Ok(l) => *cache = l,
            Err(e) => {
                eprintln!("Error: {e}");
                return vec![];
            }
        }
    }
    cache.clone()
}

async fn show_today(auth: &mut AuthService, svc: &AttendanceService, cache: &mut Vec<Lesson>) {
    let lessons = fetch_lessons(auth, svc, cache, false).await;
    let today = Local::now().date_naive();
    let mut today_lessons: Vec<Lesson> = lessons
        .into_iter()
        .filter(|l| l.start_dt().with_timezone(&Local).date_naive() == today)
        .collect();
    today_lessons.sort_by_key(|l| l.start_dt());
    print_lessons(&today_lessons, "Today's Timetable");
}

async fn show_all(auth: &mut AuthService, svc: &AttendanceService, cache: &mut Vec<Lesson>) {
    let mut lessons = fetch_lessons(auth, svc, cache, true).await;
    lessons.sort_by_key(|l| l.start_dt());
    print_lessons(&lessons, "Full Timetable");
}

fn print_lessons(lessons: &[Lesson], title: &str) {
    println!("\n{title}");
    println!("{}", "-".repeat(78));
    if lessons.is_empty() {
        println!("No lessons found.");
        return;
    }
    let now = Utc::now();
    for l in lessons {
        let start = l.start_dt().with_timezone(&Local);
        let end = l.end_dt().with_timezone(&Local);
        let status = if l.is_in_progress(now, 0) { "  <- in progress" } else { "" };
        println!(
            "[{}] {}-{}  {} - {}  Room: {}  BT: {}{}",
            start.format("%a %d %b"),
            start.format("%H:%M"),
            end.format("%H:%M"),
            l.module_code,
            l.module_name,
            l.room,
            l.bluetooth_id,
            status
        );
    }
}

async fn show_report(auth: &mut AuthService, svc: &AttendanceService) {
    println!("Fetching attendance report...");
    match svc.get_modules(auth).await {
        Ok(modules) => print_report(&modules),
        Err(e) => eprintln!("Error fetching report: {e}"),
    }
}

fn print_report(modules: &[ModuleReport]) {
    println!("\nAttendance Report");
    println!("{}", "-".repeat(60));
    if modules.is_empty() {
        println!("No report data available.");
        return;
    }
    for m in modules {
        println!(
            "  {:<10} {:<38} {:>5.1}%  ({}/{})  [{}]",
            m.module_code, m.module_name, m.attendance_percentage, m.attended, m.total, m.colour()
        );
    }
}

async fn auto_loop(auth: &mut AuthService, svc: &AttendanceService, cfg: &Config) {
    println!("\nAuto Check-In (live Bluetooth scanning)");
    println!("  Beacon UUID: {}", cfg.beacon_uuid);
    println!("  A check-in needs the room beacon physically detected at >= {} dBm.", cfg.min_rssi);
    let cycles = prompt("Number of scan cycles (0 = continuous until Ctrl-C): ");
    let max_iter = match cycles.parse::<u32>() {
        Ok(0) => None,
        Ok(n) => Some(n),
        Err(_) => Some(1),
    };
    let mut ci = CheckInService::new(cfg.clone());
    println!("Starting... press Ctrl-C to stop.\n");
    tokio::select! {
        r = ci.run_loop(auth, svc, max_iter) => {
            if let Err(e) = r { eprintln!("Loop error: {e}"); }
        }
        _ = tokio::signal::ctrl_c() => {
            println!("\nStopped.");
        }
    }
}
