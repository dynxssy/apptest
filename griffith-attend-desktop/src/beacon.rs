//! Bluetooth iBeacon scanner (cross-platform via `btleplug`:
//! BlueZ on Linux, Core Bluetooth on macOS).
//!
//! This module ONLY reports beacons that the adapter physically observes in a
//! live scan. There is deliberately no mock/simulated scanner and no way to
//! inject a beacon by hand — a check-in must be backed by a real radio
//! detection of the room's beacon. That is the whole point of the presence
//! safeguard, so it is enforced here at the source.

use std::collections::HashMap;
use std::time::Duration;

use anyhow::{anyhow, Result};
use btleplug::api::{Central, Manager as _, Peripheral as _, ScanFilter};
use btleplug::platform::Manager;

const APPLE_COMPANY_ID: u16 = 0x004C;

#[derive(Clone, Debug)]
pub struct RangedBeacon {
    pub uuid: String,
    pub major: i64,
    pub minor: i64,
    pub rssi: i16,
}

impl RangedBeacon {
    pub fn proximity(&self) -> &'static str {
        match self.rssi {
            r if r >= -50 => "immediate",
            r if r >= -70 => "near",
            r if r >= -90 => "far",
            _ => "unknown",
        }
    }
}

/// Parse Apple iBeacon manufacturer data (the bytes after the 0x004C company id):
/// `[0x02, 0x15, uuid(16), major(2 BE), minor(2 BE), tx_power(1)]`.
fn parse_ibeacon(data: &[u8]) -> Option<(String, i64, i64)> {
    if data.len() < 23 {
        return None;
    }
    if data[0] != 0x02 || data[1] != 0x15 {
        return None;
    }
    let u = &data[2..18];
    let major = u16::from_be_bytes([data[18], data[19]]) as i64;
    let minor = u16::from_be_bytes([data[20], data[21]]) as i64;
    let uuid = format!(
        "{}-{}-{}-{}-{}",
        hex(&u[0..4]),
        hex(&u[4..6]),
        hex(&u[6..8]),
        hex(&u[8..10]),
        hex(&u[10..16]),
    )
    .to_uppercase();
    Some((uuid, major, minor))
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

pub struct BeaconScanner {
    target_uuid: String,
    scan_duration: Duration,
}

impl BeaconScanner {
    pub fn new(target_uuid: &str, scan_seconds: u64) -> Self {
        Self {
            target_uuid: target_uuid.to_uppercase(),
            scan_duration: Duration::from_secs(scan_seconds),
        }
    }

    /// Run one live BLE ranging cycle and return every matching iBeacon
    /// physically detected, keeping the strongest RSSI seen per major+minor.
    pub async fn scan(&self) -> Result<Vec<RangedBeacon>> {
        let manager = Manager::new().await?;
        let adapters = manager.adapters().await?;
        let central = adapters
            .into_iter()
            .next()
            .ok_or_else(|| anyhow!("No Bluetooth adapter found. Is Bluetooth switched on?"))?;

        central.start_scan(ScanFilter::default()).await?;
        tokio::time::sleep(self.scan_duration).await;

        let mut found: HashMap<(i64, i64), RangedBeacon> = HashMap::new();
        for p in central.peripherals().await? {
            let props = match p.properties().await {
                Ok(Some(props)) => props,
                _ => continue,
            };
            let Some(apple) = props.manufacturer_data.get(&APPLE_COMPANY_ID) else {
                continue;
            };
            let Some((uuid, major, minor)) = parse_ibeacon(apple) else {
                continue;
            };
            if uuid != self.target_uuid {
                continue;
            }
            let rssi = props.rssi.unwrap_or(i16::MIN);
            let beacon = RangedBeacon { uuid, major, minor, rssi };
            found
                .entry((major, minor))
                .and_modify(|b| {
                    if beacon.rssi > b.rssi {
                        b.rssi = beacon.rssi;
                    }
                })
                .or_insert(beacon);
        }

        let _ = central.stop_scan().await;
        Ok(found.into_values().collect())
    }
}
