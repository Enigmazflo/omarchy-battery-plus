//! Discharge-rate estimation with exponential moving average.
//!
//! Rate source preference per spec:
//!   1. `current_now / energy_full` (µWh burn → %/min) when present,
//!   2. otherwise `%` deltas between consecutive discharging samples.
//!
//! Only samples whose status is Discharging participate — anything else suppresses the prediction.

use rusqlite::Connection;

use crate::{now_secs, samples_since};

/// Result handed to the renderer: minutes from now until 0%, plus the
/// absolute (UTC unix) timestamp of the projected zero crossing.
#[derive(Debug, Clone)]
pub struct Prediction {
    /// Smoothed burn rate in percentage-points per minute.
    pub rate_pct_per_min: f64,
    pub time_to_empty_minutes: f64,
    pub predicted_zero_timestamp: i64,
}

/// Estimate over the last `window_minutes` of discharging samples.
///
/// `alpha` is the EMA weight for new observations (0.2 default): higher
/// reacts faster, lower rides through spikes.
pub fn predict(
    conn: &Connection,
    now: i64,
    window_minutes: i64,
    alpha: f64,
) -> rusqlite::Result<Option<Prediction>> {
    let now = if now <= 0 { now_secs() } else { now };
    let samples = samples_since(conn, now - window_minutes * 60)?;
    if samples.is_empty() {
        return Ok(None);
    }
    let last = &samples[samples.len() - 1];
    if last.status != "Discharging" {
        return Ok(None); // suppressed while charging / full / anything else
    }
    let level = last.level;

    let alpha = alpha.clamp(0.01, 1.0);
    let mut ema: Option<f64> = None;
    for w in samples.windows(2) {
        let (a, b) = (&w[0], &w[1]);
        if a.status != "Discharging" || b.status != "Discharging" {
            continue;
        }
        let dt_min = (b.ts - a.ts) as f64 / 60.0;
        if dt_min <= 0.0 {
            continue;
        }
        // Prefer the live burn rate; fall back to level deltas.
        let inst = match (b.current_ua, b.energy_full) {
            (Some(cur), Some(full)) if full > 0 => (cur.abs() as f64) / (full as f64) * 100.0 / 60.0,
            _ => {
                let d = (a.level - b.level) as f64;
                if d <= 0.0 {
                    continue; // rose or flat while "discharging" — bogus pair
                }
                // Sanity: >50%/h equivalent is suspend/resume or bad data.
                let r = d / dt_min;
                if r > 50.0 / 60.0 {
                    continue;
                }
                r
            }
        };
        if inst <= 0.0 || !inst.is_finite() {
            continue;
        }
        ema = Some(match ema {
            None => inst,
            Some(prev) => alpha * inst + (1.0 - alpha) * prev,
        });
    }

    let rate = match ema {
        Some(r) if r > 0.0 && r.is_finite() => r,
        _ => return Ok(None),
    };
    if level <= 0 {
        return Ok(None);
    }
    let minutes = level as f64 / rate;
    Ok(Some(Prediction {
        rate_pct_per_min: rate,
        time_to_empty_minutes: minutes,
        predicted_zero_timestamp: now + (minutes * 60.0).round() as i64,
    }))
}
