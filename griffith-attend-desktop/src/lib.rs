//! Shared library for the Griffith attendance desktop client.
//!
//! The same modules back both the terminal binary (`griffith-attend`) and the
//! graphical one (`griffith-attend-gui`). The presence-gated check-in logic and
//! session handling live here and are identical across both front-ends.

// Some endpoint helpers and struct fields mirror the original API surface for
// completeness even though not every one is called from each front-end.
#![allow(dead_code)]

pub mod attendance;
pub mod auth;
pub mod beacon;
pub mod checkin;
pub mod config;
