//! omarchy-battery-collector — systemd user daemon.
//!
//! Polls the detected battery sysfs dir and appends *event-driven* rows:
//! a row is written only when capacity OR status changes, plus a heartbeat
//! row every ~15 min so idle stretches stay plottable. Result: a small,
//! clean stair-step log instead of a noisy flat time series.

use omarchy_battery::{
    cli_i64, default_db_path, detect_battery, get_sot, insert, last_row, now_secs, open_db,
    prune, put_sot, read_snapshot, screen_on,
};
use std::path::PathBuf;

fn main() {
    let db_path: PathBuf = omarchy_battery::cli_arg("db")
        .map(PathBuf::from)
        .unwrap_or_else(default_db_path);
    let poll_secs = cli_i64("poll-secs", "OMARCHY_BATTERY_POLL_SECS", 30).max(5);
    let heartbeat_secs = cli_i64("heartbeat-secs", "OMARCHY_BATTERY_HEARTBEAT_SECS", 900).max(60);
    let prune_days = cli_i64("prune-days", "OMARCHY_BATTERY_PRUNE_DAYS", 30).max(1);

    let bat = match detect_battery() {
        Ok(p) => p,
        Err(e) => {
            // Desktops have no battery: stay quiet and exit clean so the
            // user unit (Restart=on-failure) does not loop forever.
            eprintln!("omarchy-battery-collector: {e}; nothing to do.");
            std::process::exit(0);
        }
    };
    eprintln!("omarchy-battery-collector: watching {}", bat.display());

    let conn = open_db(&db_path).unwrap_or_else(|e| {
        eprintln!("cannot open db {}: {e}", db_path.display());
        std::process::exit(1);
    });
    match prune(&conn, prune_days, now_secs()) {
        Ok(n) if n > 0 => eprintln!("pruned {n} rows older than {prune_days}d"),
        Ok(_) => {}
        Err(e) => eprintln!("prune failed (continuing): {e}"),
    }

    // Baseline without a write if history already exists.
    let mut last = last_row(&conn).unwrap_or(None).map(|s| (s.ts, s.level, s.status));
    if last.is_none() {
        match read_snapshot(&bat) {
            Ok(snap) => {
                let now = now_secs();
                if insert(&conn, now, &snap).is_ok() {
                    eprintln!("seeded {now} {}% {}", snap.level, snap.status);
                    last = Some((now, snap.level, snap.status));
                }
            }
            Err(e) => eprintln!("first read failed (will retry): {e}"),
        }
    }

    // Screen-on-time state: survives restarts via SQLite.
    let mut sot = get_sot(&conn).unwrap_or_default();

    loop {
        std::thread::sleep(std::time::Duration::from_secs(poll_secs as u64));
        let snap = match read_snapshot(&bat) {
            Ok(s) => s,
            Err(e) => {
                eprintln!("read failed (retrying): {e}");
                continue;
            }
        };
        let now = now_secs();
        let (last_ts, last_level, last_status) = last.clone().unwrap_or((0, -1, String::new()));

        // ---- Screen-on-time: one cycle per discharge ----
        // New cycle on unplug (first Discharging after Charging/Full/unknown).
        // Frozen while charging; screen-on seconds accumulate only while
        // discharging with dpms on. Suspend gaps (dt >> poll) add nothing
        // since the loop itself was frozen.
        //
        // Offline charge: the collector never saw a Charging status when
        // the machine charges while powered off or suspended — on boot it
        // just sees Discharging at a much HIGHER level than the last row
        // (e.g. 4% -> 99%). That jump is a new discharge cycle, so reset
        // SOT instead of carrying the previous cycle's screen time over.
        // The +1 tolerance ignores sysfs re-estimation jitter (±1%); the
        // gap clause still catches a small top-up after a long offline
        // stretch (a live +1% jitter has no such gap).
        let discharging = snap.status == "Discharging";
        let level_up = snap.level > last_level;
        let offline_gap = now - last_ts > 2 * poll_secs;
        let charged_offline =
            discharging && level_up && (snap.level > last_level + 1 || offline_gap);
        if discharging && (sot.cycle_start == 0 || last_status != "Discharging" || charged_offline) {
            sot.cycle_start = now;
            sot.sot_sec = 0;
            eprintln!("sot: new cycle at {now}");
        }
        if discharging && sot.cycle_start > 0 {
            let dt = now - sot.last_tick;
            if sot.last_tick > 0 && dt > 0 && dt <= 2 * poll_secs {
                // hyprctl spawn only on ticks that can actually count.
                if screen_on() == Some(true) {
                    sot.sot_sec += dt;
                }
            }
        }
        sot.last_tick = now;
        if let Err(e) = put_sot(&conn, &sot) {
            eprintln!("sot persist failed (continuing): {e}");
        }

        let changed = snap.level != last_level || snap.status != last_status;
        let due_heartbeat = now - last_ts >= heartbeat_secs;
        if changed || due_heartbeat {
            match insert(&conn, now, &snap) {
                Ok(()) => {
                    let why = if changed { "change" } else { "heartbeat" };
                    eprintln!("{now} {}% {} ({why})", snap.level, snap.status);
                    last = Some((now, snap.level, snap.status));
                }
                Err(e) => eprintln!("insert failed (retrying): {e}"),
            }
        }
    }
}
