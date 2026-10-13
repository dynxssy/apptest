//! Graphical front-end (egui / eframe) for the Griffith attendance client.
//!
//! The window is a thin view over the exact same logic as the terminal
//! binary: SSO session with silent refresh, timetable, attendance report, and
//! beacon-gated check-in. All blocking/async work (HTTP, Bluetooth) runs on a
//! background Tokio thread; the UI communicates with it over channels so the
//! window never freezes. Check-in still requires a live beacon detection with
//! the proximity gate — the GUI cannot force or fake a check-in.

use std::sync::mpsc::{channel, Receiver, Sender};
use std::thread;
use std::time::Duration;

use chrono::{Local, Utc};
use eframe::egui;
use tokio::sync::mpsc::{unbounded_channel, UnboundedReceiver, UnboundedSender};

use griffith_attend_desktop::attendance::{AttendanceService, Lesson, ModuleReport};
use griffith_attend_desktop::auth::AuthService;
use griffith_attend_desktop::checkin::CheckInService;
use griffith_attend_desktop::config::{self, Config, RANGING_SECONDS};

/// The browser-console one-liner that prints the login JSON.
const TOKEN_CMD: &str =
    "fetch('/api/v2/token', { credentials: 'include' }).then(r => r.json()).then(d => console.log(JSON.stringify(d)))";

// ---------------------------------------------------------------------------
// Small UI helpers
// ---------------------------------------------------------------------------

/// A titled, outlined section used to lay the login steps out as cards.
fn step_frame(ui: &mut egui::Ui, title: &str, body: impl FnOnce(&mut egui::Ui)) {
    egui::Frame::group(ui.style())
        .inner_margin(egui::Margin::same(10.0))
        .show(ui, |ui| {
            ui.set_width(ui.available_width());
            ui.strong(title);
            ui.add_space(4.0);
            body(ui);
        });
    ui.add_space(8.0);
}

/// A read-only, selectable monospace box for showing a command.
fn code_box(ui: &mut egui::Ui, mut text: &str) {
    egui::Frame::none()
        .fill(ui.visuals().extreme_bg_color)
        .inner_margin(egui::Margin::same(8.0))
        .rounding(4.0)
        .show(ui, |ui| {
            ui.add(
                egui::TextEdit::multiline(&mut text)
                    .font(egui::TextStyle::Monospace)
                    .desired_width(f32::INFINITY)
                    .desired_rows(2),
            );
        });
}

/// A button that copies `text` to the clipboard when clicked.
fn copy_button(ui: &mut egui::Ui, label: &str, text: &str) -> egui::Response {
    let resp = ui.button(label);
    if resp.clicked() {
        ui.ctx().copy_text(text.to_owned());
    }
    resp
}

/// Slightly larger, roomier styling than the egui defaults.
fn setup_style(ctx: &egui::Context) {
    use egui::{FontFamily, FontId, TextStyle};
    let mut style = (*ctx.style()).clone();
    style.spacing.item_spacing = egui::vec2(8.0, 8.0);
    style.spacing.button_padding = egui::vec2(10.0, 6.0);
    style.text_styles = [
        (TextStyle::Heading, FontId::new(21.0, FontFamily::Proportional)),
        (TextStyle::Body, FontId::new(15.0, FontFamily::Proportional)),
        (TextStyle::Button, FontId::new(15.0, FontFamily::Proportional)),
        (TextStyle::Monospace, FontId::new(13.0, FontFamily::Monospace)),
        (TextStyle::Small, FontId::new(12.0, FontFamily::Proportional)),
    ]
    .into();
    ctx.set_style(style);
}

// ---------------------------------------------------------------------------
// Messages between the UI thread and the worker thread
// ---------------------------------------------------------------------------

enum Cmd {
    OpenSso,
    Login(String),
    Timetable,
    Report,
    RefreshToken,
    StartCheckin,
    StopCheckin,
    Logout,
}

enum Evt {
    Status(String),
    LoginState { logged_in: bool, name: String, ttl_min: i64 },
    Timetable(Vec<Lesson>),
    Report(Vec<ModuleReport>),
    Checkin(Vec<(bool, String, String)>),
    Error(String),
}

// ---------------------------------------------------------------------------
// Worker: owns the services, runs on its own Tokio runtime
// ---------------------------------------------------------------------------

fn spawn_worker(cfg: Config) -> (UnboundedSender<Cmd>, Receiver<Evt>) {
    let (cmd_tx, cmd_rx) = unbounded_channel::<Cmd>();
    let (evt_tx, evt_rx) = channel::<Evt>();
    thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("tokio runtime");
        rt.block_on(worker_loop(cfg, cmd_rx, evt_tx));
    });
    (cmd_tx, evt_rx)
}

fn send_login_state(evt: &Sender<Evt>, auth: &AuthService, usable: bool) {
    let logged_in = usable && auth.is_authenticated();
    let (name, ttl_min) = if logged_in {
        let name = auth.user.as_ref().map(|u| u.full_name()).unwrap_or_default();
        let ttl = auth.token_ttl_secs().map(|t| (t / 60).max(0)).unwrap_or(-1);
        (name, ttl)
    } else {
        (String::new(), 0)
    };
    let _ = evt.send(Evt::LoginState { logged_in, name, ttl_min });
}

async fn worker_loop(cfg: Config, mut cmd_rx: UnboundedReceiver<Cmd>, evt: Sender<Evt>) {
    let http = match reqwest::Client::builder().timeout(config::HTTP_TIMEOUT).build() {
        Ok(c) => c,
        Err(e) => {
            let _ = evt.send(Evt::Error(format!("HTTP client: {e}")));
            return;
        }
    };
    let mut auth = AuthService::new(cfg.clone(), http.clone());
    let svc = AttendanceService::new(cfg.clone(), http.clone());
    let mut checkin = CheckInService::new(cfg.clone());
    let mut checkin_active = false;

    let mut ticker = tokio::time::interval(Duration::from_secs(RANGING_SECONDS));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    // Resume saved session (silent refresh if possible).
    let usable = auth.ensure_session().await;
    send_login_state(&evt, &auth, usable);

    loop {
        tokio::select! {
            maybe = cmd_rx.recv() => {
                let Some(cmd) = maybe else { break };
                match cmd {
                    Cmd::OpenSso => auth.open_sso(),
                    Cmd::Login(raw) => match auth.login_from_json(&raw) {
                        Ok(_) => send_login_state(&evt, &auth, true),
                        Err(e) => { let _ = evt.send(Evt::Error(e.to_string())); }
                    },
                    Cmd::Timetable => {
                        let _ = evt.send(Evt::Status("Fetching timetable…".into()));
                        match svc.get_timetable(&mut auth).await {
                            Ok(l) => { let _ = evt.send(Evt::Timetable(l)); let _ = evt.send(Evt::Status("Ready".into())); }
                            Err(e) => { let _ = evt.send(Evt::Error(e.to_string())); }
                        }
                    }
                    Cmd::Report => {
                        let _ = evt.send(Evt::Status("Fetching report…".into()));
                        match svc.get_modules(&mut auth).await {
                            Ok(m) => { let _ = evt.send(Evt::Report(m)); let _ = evt.send(Evt::Status("Ready".into())); }
                            Err(e) => { let _ = evt.send(Evt::Error(e.to_string())); }
                        }
                    }
                    Cmd::RefreshToken => {
                        match auth.refresh_token().await {
                            Ok(_) => { let _ = evt.send(Evt::Status("Token refreshed".into())); }
                            Err(e) => { let _ = evt.send(Evt::Error(e.to_string())); }
                        }
                        send_login_state(&evt, &auth, true);
                    }
                    Cmd::StartCheckin => {
                        checkin_active = true;
                        ticker.reset();
                        let _ = evt.send(Evt::Status("Auto check-in on — waiting for the room beacon…".into()));
                    }
                    Cmd::StopCheckin => {
                        checkin_active = false;
                        let _ = evt.send(Evt::Status("Auto check-in stopped".into()));
                    }
                    Cmd::Logout => {
                        auth.logout().await;
                        checkin_active = false;
                        send_login_state(&evt, &auth, false);
                        let _ = evt.send(Evt::Status("Logged out".into()));
                    }
                }
            }
            _ = ticker.tick(), if checkin_active => {
                let _ = evt.send(Evt::Status("Scanning for beacons…".into()));
                match checkin.run_once(&mut auth, &svc).await {
                    Ok(results) => {
                        if !results.is_empty() {
                            let view = results.into_iter()
                                .map(|r| (r.success, r.module_name, r.message))
                                .collect();
                            let _ = evt.send(Evt::Checkin(view));
                        }
                        let _ = evt.send(Evt::Status("Auto check-in on — waiting for the room beacon…".into()));
                    }
                    Err(e) => { let _ = evt.send(Evt::Error(e.to_string())); }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// UI
// ---------------------------------------------------------------------------

#[derive(PartialEq)]
enum View {
    Timetable,
    Report,
    Checkin,
}

struct App {
    cmd: UnboundedSender<Cmd>,
    evt: Receiver<Evt>,
    cfg: Config,

    logged_in: bool,
    name: String,
    ttl_min: i64,
    status: String,
    error: String,

    lessons: Vec<Lesson>,
    report: Vec<ModuleReport>,
    checkin_log: Vec<String>,
    checkin_active: bool,

    paste: String,
    view: View,
    requested_initial: bool,
}

impl App {
    fn new(cmd: UnboundedSender<Cmd>, evt: Receiver<Evt>, cfg: Config) -> Self {
        Self {
            cmd,
            evt,
            cfg,
            logged_in: false,
            name: String::new(),
            ttl_min: 0,
            status: "Starting…".into(),
            error: String::new(),
            lessons: vec![],
            report: vec![],
            checkin_log: vec![],
            checkin_active: false,
            paste: String::new(),
            view: View::Timetable,
            requested_initial: false,
        }
    }

    fn drain_events(&mut self) {
        while let Ok(e) = self.evt.try_recv() {
            match e {
                Evt::Status(s) => self.status = s,
                Evt::Error(s) => self.error = s,
                Evt::LoginState { logged_in, name, ttl_min } => {
                    self.logged_in = logged_in;
                    self.name = name;
                    self.ttl_min = ttl_min;
                    if logged_in && !self.requested_initial {
                        self.requested_initial = true;
                        let _ = self.cmd.send(Cmd::Timetable);
                    }
                    if !logged_in {
                        self.requested_initial = false;
                        self.lessons.clear();
                        self.report.clear();
                        self.checkin_active = false;
                    }
                }
                Evt::Timetable(l) => self.lessons = l,
                Evt::Report(m) => self.report = m,
                Evt::Checkin(items) => {
                    let now = Local::now().format("%H:%M:%S");
                    for (ok, module, msg) in items {
                        let mark = if ok { "✓" } else { "✗" };
                        self.checkin_log.push(format!("[{now}] {mark} {module}: {msg}"));
                    }
                    while self.checkin_log.len() > 200 {
                        self.checkin_log.remove(0);
                    }
                }
            }
        }
    }

    fn login_ui(&mut self, ctx: &egui::Context) {
        egui::CentralPanel::default().show(ctx, |ui| {
            egui::ScrollArea::vertical().show(ui, |ui| {
                ui.add_space(6.0);
                ui.heading("Sign in to Griffith Attendance");
                ui.label(
                    "A quick one-time setup. You log in with Microsoft in your own browser, \
                     then copy one line back here. After this, the app keeps you signed in.",
                );
                ui.add_space(10.0);

                // Step 1 — open the login page
                step_frame(ui, "Step 1  ·  Open the Griffith login", |ui| {
                    ui.label("This opens the real Microsoft sign-in. Complete your login + MFA there.");
                    ui.add_space(4.0);
                    ui.horizontal(|ui| {
                        if ui.button("🌐  Open login in browser").clicked() {
                            let _ = self.cmd.send(Cmd::OpenSso);
                        }
                        copy_button(ui, "Copy login link", &self.cfg.sso_url());
                    });
                });

                // Step 2 — run the console command
                step_frame(ui, "Step 2  ·  Get your login details", |ui| {
                    ui.label(
                        "When the page says “Logging in, please wait…”, open your browser's \
                         developer console and paste this command, then press Enter:",
                    );
                    ui.add_space(4.0);
                    code_box(ui, TOKEN_CMD);
                    ui.add_space(4.0);
                    if copy_button(ui, "📋  Copy command", TOKEN_CMD).clicked() {
                        self.status = "Command copied — paste it into the browser console.".into();
                    }
                    ui.add_space(6.0);
                    ui.collapsing("How do I open the console?", |ui| {
                        ui.label("• Safari: Settings → Advanced → tick “Show features for web developers”, \
                                  then press ⌥⌘C. The first time, type  allow pasting  and press Enter before pasting.");
                        ui.label("• Chrome / Edge: press ⌥⌘I (Mac) or F12 (Windows/Linux) and pick the Console tab.");
                        ui.add_space(4.0);
                        ui.label("It prints a line of JSON. If it prints {} or nothing, wait a few seconds for \
                                  the page to finish and run it again.");
                    });
                });

                // Step 3 — paste the result
                step_frame(ui, "Step 3  ·  Paste the result here", |ui| {
                    ui.label("Copy the JSON line the console printed and paste it below:");
                    ui.add_space(4.0);
                    ui.add(
                        egui::TextEdit::multiline(&mut self.paste)
                            .desired_rows(5)
                            .desired_width(f32::INFINITY)
                            .hint_text("{ \"auth_status\": true, \"token\": \"…\", \"user_id\": \"…\", … }"),
                    );
                    ui.add_space(6.0);
                    ui.horizontal(|ui| {
                        if ui.add(egui::Button::new("✅  Sign in")).clicked() {
                            self.error.clear();
                            let _ = self.cmd.send(Cmd::Login(self.paste.clone()));
                        }
                        if ui.button("Clear").clicked() {
                            self.paste.clear();
                            self.error.clear();
                        }
                    });
                    if !self.error.is_empty() {
                        ui.add_space(6.0);
                        ui.colored_label(egui::Color32::LIGHT_RED, format!("⚠  {}", self.error));
                    }
                });

                ui.add_space(8.0);
                ui.weak(
                    "That line is a login credential for your account — don't share it with anyone. \
                     The app stores it only on this computer.",
                );
            });
        });
    }

    fn main_ui(&mut self, ctx: &egui::Context) {
        egui::SidePanel::left("nav").resizable(false).min_width(170.0).show(ctx, |ui| {
            ui.add_space(6.0);
            if ui.selectable_label(self.view == View::Timetable, "📅  Timetable").clicked() {
                self.view = View::Timetable;
                let _ = self.cmd.send(Cmd::Timetable);
            }
            if ui.selectable_label(self.view == View::Report, "📊  Attendance report").clicked() {
                self.view = View::Report;
                let _ = self.cmd.send(Cmd::Report);
            }
            if ui.selectable_label(self.view == View::Checkin, "📶  Check-in").clicked() {
                self.view = View::Checkin;
            }
            ui.separator();
            let toggle = if self.checkin_active { "■  Stop auto check-in" } else { "▶  Start auto check-in" };
            if ui.button(toggle).clicked() {
                self.checkin_active = !self.checkin_active;
                self.view = View::Checkin;
                let _ = self.cmd.send(if self.checkin_active { Cmd::StartCheckin } else { Cmd::StopCheckin });
            }
            if ui.button("↻  Refresh timetable").clicked() {
                let _ = self.cmd.send(Cmd::Timetable);
            }
            if ui.button("🔑  Refresh token").clicked() {
                let _ = self.cmd.send(Cmd::RefreshToken);
            }
            ui.separator();
            if ui.button("Log out").clicked() {
                let _ = self.cmd.send(Cmd::Logout);
            }
        });

        egui::CentralPanel::default().show(ctx, |ui| match self.view {
            View::Timetable => self.timetable_view(ui),
            View::Report => self.report_view(ui),
            View::Checkin => self.checkin_view(ui),
        });
    }

    fn timetable_view(&self, ui: &mut egui::Ui) {
        ui.heading("Timetable");
        if self.lessons.is_empty() {
            ui.label("No lessons loaded.");
            return;
        }
        let now = Utc::now();
        let mut lessons = self.lessons.clone();
        lessons.sort_by_key(|l| l.start_dt());
        egui::ScrollArea::vertical().show(ui, |ui| {
            egui::Grid::new("tt").striped(true).num_columns(6).show(ui, |ui| {
                for h in ["Date", "Time", "Module", "Room", "BT", "Now"] {
                    ui.strong(h);
                }
                ui.end_row();
                for l in &lessons {
                    let start = l.start_dt().with_timezone(&Local);
                    let end = l.end_dt().with_timezone(&Local);
                    ui.label(start.format("%a %d %b").to_string());
                    ui.label(format!("{}–{}", start.format("%H:%M"), end.format("%H:%M")));
                    ui.label(format!("{} {}", l.module_code, l.module_name));
                    ui.label(&l.room);
                    ui.label(l.bluetooth_id.to_string());
                    if l.is_in_progress(now, 0) {
                        ui.colored_label(egui::Color32::LIGHT_GREEN, "● in progress");
                    } else {
                        ui.label("");
                    }
                    ui.end_row();
                }
            });
        });
    }

    fn report_view(&self, ui: &mut egui::Ui) {
        ui.heading("Attendance report");
        if self.report.is_empty() {
            ui.label("No report data loaded.");
            return;
        }
        egui::ScrollArea::vertical().show(ui, |ui| {
            egui::Grid::new("rep").striped(true).num_columns(5).show(ui, |ui| {
                for h in ["Code", "Module", "Attended", "Total", "%"] {
                    ui.strong(h);
                }
                ui.end_row();
                for m in &self.report {
                    ui.label(&m.module_code);
                    ui.label(&m.module_name);
                    ui.label(m.attended.to_string());
                    ui.label(m.total.to_string());
                    let colour = match m.colour() {
                        "danger" => egui::Color32::LIGHT_RED,
                        "warning" => egui::Color32::YELLOW,
                        _ => egui::Color32::LIGHT_GREEN,
                    };
                    ui.colored_label(colour, format!("{:.1}%", m.attendance_percentage));
                    ui.end_row();
                }
            });
        });
    }

    fn checkin_view(&self, ui: &mut egui::Ui) {
        ui.heading("Beacon check-in");
        ui.label(format!(
            "Check-in needs this device's Bluetooth to physically detect the room beacon \
             (≥ {} dBm). There is no manual or simulated check-in.",
            self.cfg.min_rssi
        ));
        ui.horizontal(|ui| {
            ui.label("Status:");
            if self.checkin_active {
                ui.colored_label(egui::Color32::LIGHT_GREEN, "auto check-in running");
            } else {
                ui.label("idle");
            }
        });
        ui.separator();
        egui::ScrollArea::vertical().stick_to_bottom(true).show(ui, |ui| {
            if self.checkin_log.is_empty() {
                ui.label("No check-ins yet.");
            }
            for line in &self.checkin_log {
                ui.monospace(line);
            }
        });
    }
}

impl eframe::App for App {
    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        self.drain_events();

        egui::TopBottomPanel::top("top").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.heading("Griffith Attendance");
                ui.separator();
                if self.logged_in {
                    ui.label(format!("👤 {}", self.name));
                    if self.ttl_min >= 0 {
                        ui.weak(format!("· session ~{} min", self.ttl_min));
                    }
                } else {
                    ui.weak("not signed in");
                }
            });
        });

        egui::TopBottomPanel::bottom("status").show(ctx, |ui| {
            ui.horizontal(|ui| {
                ui.label(&self.status);
                if !self.error.is_empty() {
                    ui.separator();
                    ui.colored_label(egui::Color32::LIGHT_RED, &self.error);
                }
            });
        });

        if self.logged_in {
            self.main_ui(ctx);
        } else {
            self.login_ui(ctx);
        }

        // Poll the worker channel regularly without a busy loop.
        ctx.request_repaint_after(Duration::from_millis(200));
    }
}

fn main() -> eframe::Result<()> {
    let cfg = Config::from_env();
    let (cmd, evt) = spawn_worker(cfg.clone());
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default().with_inner_size([860.0, 600.0]),
        ..Default::default()
    };
    eframe::run_native(
        "Griffith Attendance",
        options,
        Box::new(move |cc| {
            setup_style(&cc.egui_ctx);
            Ok(Box::new(App::new(cmd, evt, cfg)) as Box<dyn eframe::App>)
        }),
    )
}
