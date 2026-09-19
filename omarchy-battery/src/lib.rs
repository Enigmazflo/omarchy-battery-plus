//! Shared core: paths, SQLite schema, sysfs reading, battery detection,
//! local-time formatting. No heavy dependencies — rusqlite (bundled) only.

use rusqlite::{params, Connection};
use std::fs;
use std::path::{Path, PathBuf};

pub mod predict;

/// One log row. `ts` is UTC unix seconds.
#[derive(Debug, Clone)]
pub struct Sample {
    pub ts: i64,
    pub level: i32,
    pub status: String,
    pub current_ua: Option<i64>,
    pub energy_now: Option<i64>,
    pub energy_full: Option<i64>,
}

/// Live reading from /sys/class/power_supply/BAT*/.
#[derive(Debug, Clone)]
pub struct Snapshot {
    pub level: i32,
    pub status: String,
    pub current_ua: Option<i64>,
    pub energy_now: Option<i64>,
    pub energy_full: Option<i64>,
}

pub fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

fn data_home() -> PathBuf {
    if let Ok(x) = std::env::var("XDG_DATA_HOME") {
        if !x.is_empty() {
            return PathBuf::from(x);
        }
    }
    PathBuf::from(std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string()))
        .join(".local/share")
}

/// ~/.local/share/omarchy-battery/history.db (or $OMARCHY_BATTERY_DB).
pub fn default_db_path() -> PathBuf {
    if let Ok(p) = std::env::var("OMARCHY_BATTERY_DB") {
        if !p.is_empty() {
            return PathBuf::from(p);
        }
    }
    data_home().join("omarchy-battery/history.db")
}

/// Open (creating parents), ensure the exact spec schema.
pub fn open_db(path: &Path) -> rusqlite::Result<Connection> {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    let conn = Connection::open(path)?;
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS battery_log (
           ts INTEGER PRIMARY KEY,
           level INTEGER NOT NULL,
           status TEXT NOT NULL,
           current_ua INTEGER,
           energy_now INTEGER,
           energy_full INTEGER
         );
         CREATE INDEX IF NOT EXISTS idx_battery_log_ts ON battery_log(ts);
         CREATE TABLE IF NOT EXISTS sot_state (
           id INTEGER PRIMARY KEY CHECK (id = 1),
           cycle_start INTEGER NOT NULL DEFAULT 0,
           sot_sec INTEGER NOT NULL DEFAULT 0,
           last_tick INTEGER NOT NULL DEFAULT 0
         );",
    )?;
    Ok(conn)
}

/// Open read-only (CLI tools on a machine where the collector never ran).
pub fn open_db_readonly(path: &Path) -> rusqlite::Result<Connection> {
    Connection::open_with_flags(path, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
}

/// Delete rows older than `days`. Returns rows removed.
pub fn prune(conn: &Connection, days: i64, now: i64) -> rusqlite::Result<usize> {
    let cutoff = now - days * 86400;
    conn.execute("DELETE FROM battery_log WHERE ts < ?1", params![cutoff])
}

/// Find the battery sysfs dir at runtime (BAT0, BAT1, …). Never hardcode.
pub fn detect_battery() -> Result<PathBuf, String> {
    let base = Path::new("/sys/class/power_supply");
    let entries = fs::read_dir(base).map_err(|e| format!("cannot read {base:?}: {e}"))?;
    let mut cands: Vec<PathBuf> = vec![];
    for e in entries.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().into_owned();
        if name.starts_with("BAT") && p.join("capacity").is_file() {
            cands.push(p);
        }
    }
    cands.sort();
    cands
        .into_iter()
        .next()
        .ok_or_else(|| "no battery (BAT*) with a capacity file under /sys/class/power_supply".to_string())
}

fn read_trim(path: &Path) -> Option<String> {
    fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

fn read_i64(path: &Path) -> Option<i64> {
    read_trim(path)?.parse::<i64>().ok()
}

/// Read one snapshot. `energy_*` preferred, `charge_*` fallback (µAh —
/// the burn-rate math is identical: µA/µAh == 1/h, same as µA·V/µWh).
pub fn read_snapshot(dir: &Path) -> Result<Snapshot, String> {
    let level = read_i64(&dir.join("capacity"))
        .ok_or_else(|| format!("{}: cannot read capacity", dir.display()))?;
    if !(0..=100).contains(&level) {
        return Err(format!("capacity out of range: {level}"));
    }
    let status = read_trim(&dir.join("status")).unwrap_or_else(|| "Unknown".to_string());
    let current_ua = read_i64(&dir.join("current_now"));
    let energy_now = read_i64(&dir.join("energy_now")).or_else(|| read_i64(&dir.join("charge_now")));
    let energy_full = read_i64(&dir.join("energy_full")).or_else(|| read_i64(&dir.join("charge_full")));
    Ok(Snapshot {
        level: level as i32,
        status,
        current_ua,
        energy_now,
        energy_full,
    })
}

pub fn insert(conn: &Connection, ts: i64, s: &Snapshot) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO battery_log
           (ts, level, status, current_ua, energy_now, energy_full)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
        params![ts, s.level, s.status, s.current_ua, s.energy_now, s.energy_full],
    )?;
    Ok(())
}

/// Screen-on-time state: single row (id = 1). A cycle starts on unplug
/// (first Discharging sample after Charging/Full) and freezes on plug-in.
#[derive(Debug, Clone)]
pub struct SotState {
    pub cycle_start: i64,
    pub sot_sec: i64,
    pub last_tick: i64,
}

impl Default for SotState {
    fn default() -> Self {
        SotState { cycle_start: 0, sot_sec: 0, last_tick: 0 }
    }
}

/// Read-write fetch for the collector (creates the row if missing).
pub fn get_sot(conn: &Connection) -> rusqlite::Result<SotState> {
    conn.execute(
        "INSERT OR IGNORE INTO sot_state (id, cycle_start, sot_sec, last_tick)
         VALUES (1, 0, 0, 0)",
        [],
    )?;
    conn.query_row(
        "SELECT cycle_start, sot_sec, last_tick FROM sot_state WHERE id = 1",
        [],
        |r| {
            Ok(SotState {
                cycle_start: r.get(0)?,
                sot_sec: r.get(1)?,
                last_tick: r.get(2)?,
            })
        },
    )
}

pub fn put_sot(conn: &Connection, s: &SotState) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT OR REPLACE INTO sot_state (id, cycle_start, sot_sec, last_tick)
         VALUES (1, ?1, ?2, ?3)",
        params![s.cycle_start, s.sot_sec, s.last_tick],
    )?;
    Ok(())
}

/// Read-only SOT fetch for renderers. Old DBs may lack the table entirely —
/// that is a zeroed state, not an error.
pub fn read_sot_opt(conn: &Connection) -> SotState {
    conn.query_row(
        "SELECT cycle_start, sot_sec, last_tick FROM sot_state WHERE id = 1",
        [],
        |r| {
            Ok(SotState {
                cycle_start: r.get(0)?,
                sot_sec: r.get(1)?,
                last_tick: r.get(2)?,
            })
        },
    )
    .unwrap_or_default()
}

/// Screen-on detection for SOT accounting (best-effort).
/// `hyprctl monitors -j` reports `dpmsStatus` per monitor; true if ANY
/// monitor is on. Returns None when undetectable (no Hyprland session) —
/// the caller must skip accumulation rather than guess.
///
/// NOTE: the collector runs as a systemd user service, which often starts
/// before Hyprland exports HYPRLAND_INSTANCE_SIGNATURE into the manager
/// environment — so the service process may lack it even though the
/// compositor is running (hyprctl then fails with "signature not set" and
/// SOT freezes forever). When the env var is missing we rediscover the
/// instance by scanning $XDG_RUNTIME_DIR/hypr/*/.socket.sock (newest
/// wins) and pass it explicitly to the child. `hyprctl instances -j`
/// works without the variable, which proves hyprctl itself can find the
/// runtime dir — we just do the same lookup for the monitors call.
pub fn screen_on() -> Option<bool> {
    use std::process::Command;
    let mut cmd = Command::new("hyprctl");
    if std::env::var("HYPRLAND_INSTANCE_SIGNATURE")
        .ok()
        .filter(|s| !s.is_empty())
        .is_none()
    {
        if let Some(sig) = discover_hypr_signature() {
            cmd.env("HYPRLAND_INSTANCE_SIGNATURE", sig);
        }
    }
    let out = cmd.args(["monitors", "-j"]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let txt = String::from_utf8_lossy(&out.stdout);
    if !txt.contains("dpmsStatus") {
        return None;
    }
    Some(txt.contains("\"dpmsStatus\":true") || txt.contains("\"dpmsStatus\": true"))
}

/// Newest Hyprland instance signature under $XDG_RUNTIME_DIR/hypr/,
/// or None when there is no (readable) Hyprland runtime dir.
fn discover_hypr_signature() -> Option<String> {
    let runtime = std::env::var("XDG_RUNTIME_DIR").ok().filter(|s| !s.is_empty())?;
    let base = Path::new(&runtime).join("hypr");
    let entries = fs::read_dir(&base).ok()?;
    let mut best: Option<(i64, String)> = None;
    for e in entries.flatten() {
        let p = e.path();
        // Instance dirs contain .socket.sock; skip anything else.
        if !p.join(".socket.sock").exists() {
            continue;
        }
        let name = e.file_name().to_string_lossy().into_owned();
        // Newest socket wins (multi-seat / stale dirs after crashes).
        let mtime = fs::metadata(p.join(".socket.sock"))
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        if best.as_ref().is_none_or(|(t, _)| mtime >= *t) {
            best = Some((mtime, name));
        }
    }
    best.map(|(_, name)| name)
}

/// Newest row, if any.
pub fn last_row(conn: &Connection) -> rusqlite::Result<Option<Sample>> {
    let mut stmt = conn.prepare(
        "SELECT ts, level, status, current_ua, energy_now, energy_full
         FROM battery_log ORDER BY ts DESC LIMIT 1",
    )?;
    let mut rows = stmt.query([])?;
    if let Some(r) = rows.next()? {
        Ok(Some(Sample {
            ts: r.get(0)?,
            level: r.get(1)?,
            status: r.get(2)?,
            current_ua: r.get(3)?,
            energy_now: r.get(4)?,
            energy_full: r.get(5)?,
        }))
    } else {
        Ok(None)
    }
}

/// All rows with ts >= `since`, ascending.
pub fn samples_since(conn: &Connection, since: i64) -> rusqlite::Result<Vec<Sample>> {
    let mut stmt = conn.prepare(
        "SELECT ts, level, status, current_ua, energy_now, energy_full
         FROM battery_log WHERE ts >= ?1 ORDER BY ts ASC",
    )?;
    let rows = stmt.query_map(params![since], |r| {
        Ok(Sample {
            ts: r.get(0)?,
            level: r.get(1)?,
            status: r.get(2)?,
            current_ua: r.get(3)?,
            energy_now: r.get(4)?,
            energy_full: r.get(5)?,
        })
    })?;
    rows.collect::<rusqlite::Result<Vec<_>>>()
}

// ---------- tiny env/arg helpers (no clap — fewer deps) ----------

pub fn env_i64(key: &str, default: i64) -> i64 {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

pub fn env_f64(key: &str, default: f64) -> f64 {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// Long `--key value` or `--key=value` from argv. Returns None if absent.
pub fn cli_arg(key: &str) -> Option<String> {
    let want = format!("--{key}");
    let want_eq = format!("--{key}=");
    let args: Vec<String> = std::env::args().collect();
    let mut i = 1;
    while i < args.len() {
        if args[i] == want {
            return args.get(i + 1).cloned();
        }
        if let Some(v) = args[i].strip_prefix(&want_eq) {
            return Some(v.to_string());
        }
        i += 1;
    }
    None
}

pub fn cli_i64(key: &str, env_key: &str, default: i64) -> i64 {
    cli_arg(key).and_then(|v| v.parse().ok()).unwrap_or_else(|| env_i64(env_key, default))
}

pub fn cli_f64(key: &str, env_key: &str, default: f64) -> f64 {
    cli_arg(key).and_then(|v| v.parse().ok()).unwrap_or_else(|| env_f64(env_key, default))
}

// ---------- local time formatting (libc only, no chrono) ----------

#[repr(C)]
struct Tm {
    tm_sec: i32,
    tm_min: i32,
    tm_hour: i32,
    tm_mday: i32,
    tm_mon: i32,
    tm_year: i32,
    tm_wday: i32,
    tm_yday: i32,
    tm_isdst: i32,
    tm_gmtoff: i64,
    tm_zone: *const i8,
}

unsafe extern "C" {
    fn localtime_r(timep: *const i64, result: *mut Tm) -> *mut Tm;
}

/// "11:40 PM" in local time.
pub fn local_hh_mm(ts: i64) -> String {
    let mut tm = Tm {
        tm_sec: 0,
        tm_min: 0,
        tm_hour: 0,
        tm_mday: 0,
        tm_mon: 0,
        tm_year: 0,
        tm_wday: 0,
        tm_yday: 0,
        tm_isdst: 0,
        tm_gmtoff: 0,
        tm_zone: std::ptr::null(),
    };
    unsafe {
        localtime_r(&ts as *const i64, &mut tm as *mut Tm);
    }
    let h = tm.tm_hour;
    let (h12, ap) = if h == 0 {
        (12, "AM")
    } else if h < 12 {
        (h, "AM")
    } else if h == 12 {
        (12, "PM")
    } else {
        (h - 12, "PM")
    };
    format!("{h12}:{:02} {ap}", tm.tm_min)
}

/// 82.5 → "~1h 23m"; 35.0 → "~35m".
pub fn fmt_duration(mins: f64) -> String {
    let m = mins.round() as i64;
    if m >= 60 {
        format!("~{}h {}m", m / 60, m % 60)
    } else {
        format!("~{m}m")
    }
}
