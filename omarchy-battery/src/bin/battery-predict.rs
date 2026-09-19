//! battery-predict — CLI test front-end for the prediction module.
//! Prints a human line on success; explains + exit 2 when suppressed.

use omarchy_battery::{cli_f64, cli_i64, default_db_path, fmt_duration, local_hh_mm, open_db_readonly};
use std::path::PathBuf;

fn main() {
    let db_path: PathBuf = omarchy_battery::cli_arg("db")
        .map(PathBuf::from)
        .unwrap_or_else(default_db_path);
    let window = cli_i64("window-minutes", "OMARCHY_BATTERY_WINDOW_MINUTES", 60).max(5);
    let alpha = cli_f64("alpha", "OMARCHY_BATTERY_EMA_ALPHA", 0.2);

    let conn = match open_db_readonly(&db_path) {
        Ok(c) => c,
        Err(_) => {
            eprintln!("no prediction: no database yet at {}", db_path.display());
            std::process::exit(2);
        }
    };
    match omarchy_battery::predict::predict(&conn, 0, window, alpha) {
        Ok(Some(p)) => {
            println!(
                "{} left (draining {:.1}%/h) — empty ~{}",
                fmt_duration(p.time_to_empty_minutes),
                p.rate_pct_per_min * 60.0,
                local_hh_mm(p.predicted_zero_timestamp)
            );
        }
        Ok(None) => {
            let reason = match omarchy_battery::last_row(&conn).unwrap_or(None) {
                None => "no samples yet".to_string(),
                Some(s) if s.status != "Discharging" => {
                    format!("status is '{}' (prediction only while Discharging)", s.status)
                }
                _ => "not enough discharging data in window".to_string(),
            };
            eprintln!("no prediction: {reason}");
            std::process::exit(2);
        }
        Err(e) => {
            eprintln!("prediction query failed: {e}");
            std::process::exit(1);
        }
    }
}
