//! battery-chart — Samsung One UI-style battery graph.
//!
//! Two outputs from one fresh SQLite query (never cached):
//!   * SVG (--out): 24h stair-step, charge/discharge colors, dotted
//!     forecast with zero-crossing label. Handy standalone / debugging.
//!   * JSON (--json-out): the same dataset for the Quickshell popup,
//!     which renders it natively on Canvas (splines, gradient, reveal
//!     animation, hover details).
//!
//! Window: last `--hours` (default 24), but the visible start is the
//! timestamp of the earliest sample ≥ (now - window) — like Samsung, the
//! baseline starts wherever the battery actually was, not at 100%.

use omarchy_battery::{
    cli_f64, cli_i64, default_db_path, fmt_duration, local_hh_mm, open_db_readonly,
};
use omarchy_battery::{predict, Sample};
use std::path::{Path, PathBuf};

const FG: &str = "#E8E8E8"; // discharge
const CHG: &str = "#4CC38A"; // charging rises
const PRED: &str = "#7FB4FF"; // forecast
const GRID: &str = "rgba(255,255,255,0.14)";
const DIM: &str = "#9AA0A6";

/// Everything both renderers need, queried once.
struct ChartData {
    now: i64,
    t0: i64,
    t1: i64,
    points: Vec<Sample>,
    forecast: Option<predict::Prediction>,
    sot_sec: i64,
    sot_since: i64,
}

fn gather(db: &Path, hours: i64, alpha: f64) -> Result<ChartData, String> {
    let conn =
        open_db_readonly(db).map_err(|_| "no database yet — is the collector running?".to_string())?;
    let now = omarchy_battery::now_secs();
    let rows = omarchy_battery::samples_since(&conn, now - hours * 3600)
        .map_err(|e| e.to_string())?;
    if rows.is_empty() {
        return Err("empty".to_string());
    }
    let t0 = rows[0].ts;
    let last = &rows[rows.len() - 1];
    let fc = predict::predict(&conn, now, 60, alpha).map_err(|e| e.to_string())?;
    let forecast = match fc {
        Some(p) if last.status == "Discharging" => Some(p),
        _ => None,
    };
    // X domain covers history + forecast zero point. The forecast arm is
    // capped at +12h so a slow burn rate can't crush the history flat
    // against the left edge; the label still prints the full estimate.
    let mut t1 = now.max(last.ts);
    if let Some(p) = &forecast {
        t1 = t1.max((now + 12 * 3600).min(p.predicted_zero_timestamp));
    }
    if t1 <= t0 {
        t1 = t0 + 60;
    }
    let sot = omarchy_battery::read_sot_opt(&conn);
    Ok(ChartData { now, t0, t1, points: rows, forecast, sot_sec: sot.sot_sec, sot_since: sot.cycle_start })
}

fn esc(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

fn jesc(s: &str) -> String {
    s.replace('\\', "\\\\").replace('"', "\\\"")
}

fn empty_svg(w: i64, h: i64, msg: &str) -> String {
    format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {w} {h}\">\
         <text x=\"{}\" y=\"{}\" font-family=\"monospace\" font-size=\"11\" fill=\"{DIM}\" \
         text-anchor=\"middle\">{}</text></svg>",
        w / 2,
        h / 2,
        esc(msg)
    )
}

/// Compact JSON for the QML Canvas renderer. Statuses come from the kernel
/// ([A-Za-z ] only) but are escaped anyway; levels are integers.
fn render_json(d: &ChartData) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "{{\"t0\":{},\"t1\":{},\"now\":{},\"current\":{{\"level\":{},\"status\":\"{}\"}},\"points\":[",
        d.t0,
        d.t1,
        d.now,
        d.points.last().map(|p| p.level).unwrap_or(0),
        d.points.last().map(|p| jesc(&p.status)).unwrap_or_default()
    ));
    for (i, p) in d.points.iter().enumerate() {
        if i > 0 {
            s.push(',');
        }
        s.push_str(&format!(
            "{{\"t\":{},\"level\":{},\"status\":\"{}\"}}",
            p.ts,
            p.level,
            jesc(&p.status)
        ));
    }
    s.push_str("],\"prediction\":");
    match &d.forecast {
        Some(f) => s.push_str(&format!(
            "{{\"rate\":{:.4},\"minutes\":{:.1},\"zero\":{},\"label\":\"{}\"}}",
            f.rate_pct_per_min,
            f.time_to_empty_minutes,
            f.predicted_zero_timestamp,
            jesc(&format!(
                "{} left, empty ~{}",
                fmt_duration(f.time_to_empty_minutes).trim_start_matches('~'),
                local_hh_mm(f.predicted_zero_timestamp)
            ))
        )),
        None => s.push_str("null"),
    }
    s.push_str(&format!(",\"sot\":{{\"sec\":{},\"since\":{}}}", d.sot_sec, d.sot_since));
    s.push('}');
    s
}

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

/// "23:40" local — compact axis labels.
fn local_hm24(ts: i64) -> String {
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
    format!("{:02}:{:02}", tm.tm_hour, tm.tm_min)
}

fn main() {
    let db_path: PathBuf = omarchy_battery::cli_arg("db")
        .map(PathBuf::from)
        .unwrap_or_else(default_db_path);
    let out: PathBuf = omarchy_battery::cli_arg("out").map(PathBuf::from).unwrap_or_else(|| {
        db_path.parent().unwrap_or(std::path::Path::new(".")).join("chart.svg")
    });
    let json_out: Option<PathBuf> = omarchy_battery::cli_arg("json-out").map(PathBuf::from);
    let hours = cli_i64("hours", "OMARCHY_BATTERY_WINDOW_HOURS", 24).max(1);
    let width = cli_i64("width", "OMARCHY_BATTERY_CHART_W", 280).clamp(120, 1600);
    let height = cli_i64("height", "OMARCHY_BATTERY_CHART_H", 180).clamp(80, 900);
    let alpha = cli_f64("alpha", "OMARCHY_BATTERY_EMA_ALPHA", 0.2);

    let data = match gather(&db_path, hours, alpha) {
        Ok(d) => Some(d),
        Err(e) if e == "empty" => None,
        Err(e) => {
            eprintln!("battery-chart: {e}");
            std::process::exit(1);
        }
    };
    let svg = match &data {
        Some(d) => render_svg(d, width, height),
        None => empty_svg(width, height, "No battery data in window yet"),
    };
    // Atomic writes: the widget may be reading either file concurrently.
    let tmp = out.with_extension("svg.tmp");
    if let Err(e) = std::fs::write(&tmp, svg).and_then(|_| std::fs::rename(&tmp, &out)) {
        eprintln!("battery-chart: cannot write {}: {e}", out.display());
        std::process::exit(1);
    }
    if let Some(jpath) = json_out {
        let json = match &data {
            Some(d) => render_json(d),
            None => "{\"t0\":0,\"t1\":0,\"now\":0,\"current\":{\"level\":0,\"status\":\"\"},\"points\":[],\"prediction\":null,\"sot\":{\"sec\":0,\"since\":0}}".to_string(),
        };
        let jtmp = jpath.with_extension("json.tmp");
        if let Err(e) = std::fs::write(&jtmp, json).and_then(|_| std::fs::rename(&jtmp, &jpath)) {
            eprintln!("battery-chart: cannot write {}: {e}", jpath.display());
            std::process::exit(1);
        }
    }
}

fn render_svg(d: &ChartData, w: i64, h: i64) -> String {
    let last = &d.points[d.points.len() - 1];

    // Layout.
    let (ml, mr, mt, mb) = (30.0, 8.0, 20.0, 16.0);
    let pw = w as f64 - ml - mr;
    let ph = h as f64 - mt - mb;
    let x = |t: i64| ml + (t - d.t0) as f64 / (d.t1 - d.t0) as f64 * pw;
    let y = |lvl: i32| mt + (1.0 - lvl.clamp(0, 100) as f64 / 100.0) * ph;

    let mut s = String::new();
    s.push_str(&format!(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 {w} {h}\" \
         font-family=\"monospace\">"
    ));

    // Legend.
    s.push_str(&format!(
        "<g font-size=\"9\" fill=\"{DIM}\">\
         <rect x=\"{ml}\" y=\"5\" width=\"8\" height=\"8\" fill=\"{FG}\"/>\
         <text x=\"{}\" y=\"13\">Discharge</text>",
        ml + 11.0
    ));
    s.push_str(&format!(
        "<rect x=\"{}\" y=\"5\" width=\"8\" height=\"8\" fill=\"{CHG}\"/>\
         <text x=\"{}\" y=\"13\">Charge</text>",
        ml + 82.0,
        ml + 93.0
    ));
    s.push_str(&format!(
        "<rect x=\"{}\" y=\"5\" width=\"8\" height=\"8\" fill=\"none\" stroke=\"{PRED}\" \
         stroke-width=\"1.5\" stroke-dasharray=\"3 2\"/>\
         <text x=\"{}\" y=\"13\">Forecast</text></g>",
        ml + 148.0,
        ml + 159.0
    ));

    // Y gridlines + labels (fixed 0–100 per spec).
    for lvl in [0, 25, 50, 75, 100] {
        let gy = y(lvl);
        s.push_str(&format!(
            "<line x1=\"{ml}\" y1=\"{gy:.1}\" x2=\"{}\" y2=\"{gy:.1}\" stroke=\"{GRID}\" \
             stroke-width=\"1\"/>",
            ml + pw
        ));
        s.push_str(&format!(
            "<text x=\"{}\" y=\"{:.1}\" font-size=\"9\" fill=\"{DIM}\" \
             text-anchor=\"end\" dominant-baseline=\"middle\">{lvl}%</text>",
            ml - 4.0,
            gy + 0.5
        ));
    }

    // X ticks (~6, time of day). Edge ticks anchor inward so labels
    // never run off the canvas.
    for i in 0..=5 {
        let t = d.t0 + (d.t1 - d.t0) * i / 5;
        let tx = x(t);
        let anchor = if i == 0 { "start" } else if i == 5 { "end" } else { "middle" };
        s.push_str(&format!(
            "<text x=\"{tx:.1}\" y=\"{}\" font-size=\"9\" fill=\"{DIM}\" \
             text-anchor=\"{anchor}\">{}</text>",
            h as f64 - 4.0,
            esc(&local_hm24(t))
        ));
    }

    // Segments: charging rises green, everything else light.
    // Charging is much faster than drain on the same time scale, so rises
    // naturally render as steep "spikes".
    let mut path_d = String::new();
    let mut path_c = String::new();
    for pair in d.points.windows(2) {
        let (a, b) = (&pair[0], &pair[1]);
        let seg = format!("M{:.1},{:.1}L{:.1},{:.1}", x(a.ts), y(a.level), x(b.ts), y(b.level));
        if b.status == "Charging" && b.level > a.level {
            path_c.push_str(&seg);
        } else {
            path_d.push_str(&seg);
        }
    }
    if d.points.len() == 1 {
        path_d.push_str(&format!("M{:.1},{:.1}h0.5", x(d.points[0].ts), y(d.points[0].level)));
    }
    s.push_str(&format!(
        "<path d=\"{path_d}\" fill=\"none\" stroke=\"{FG}\" stroke-width=\"1.6\" \
         stroke-linejoin=\"round\" stroke-linecap=\"round\"/>"
    ));
    if !path_c.is_empty() {
        s.push_str(&format!(
            "<path d=\"{path_c}\" fill=\"none\" stroke=\"{CHG}\" stroke-width=\"1.8\" \
             stroke-linejoin=\"round\" stroke-linecap=\"round\"/>"
        ));
    }
    // "Now" dot.
    s.push_str(&format!(
        "<circle cx=\"{:.1}\" cy=\"{:.1}\" r=\"2.6\" fill=\"{FG}\"/>",
        x(last.ts),
        y(last.level)
    ));

    // Dotted forecast + zero-crossing label. Ends at the (possibly
    // domain-capped) zero point, or at the domain edge at the level the
    // rate projects there — never below the plot floor.
    if let Some(p) = &d.forecast {
        let end_t = d.t1.min(p.predicted_zero_timestamp);
        let end_lvl =
            (last.level as f64 - p.rate_pct_per_min * (end_t - d.now) as f64 / 60.0).clamp(0.0, 100.0);
        let zx = x(end_t);
        let zy = y(end_lvl.round() as i32);
        s.push_str(&format!(
            "<line x1=\"{:.1}\" y1=\"{:.1}\" x2=\"{zx:.1}\" y2=\"{zy:.1}\" \
             stroke=\"{PRED}\" stroke-width=\"1.6\" stroke-dasharray=\"4 3\"/>",
            x(d.now),
            y(last.level)
        ));
        s.push_str(&format!(
            "<circle cx=\"{zx:.1}\" cy=\"{zy:.1}\" r=\"3\" fill=\"none\" \
             stroke=\"{PRED}\" stroke-width=\"1.5\"/>"
        ));
        let label = format!(
            "{} left, empty ~{}",
            omarchy_battery::fmt_duration(p.time_to_empty_minutes).trim_start_matches('~'),
            local_hh_mm(p.predicted_zero_timestamp)
        );
        let (anchor, lx) = if zx > ml + pw - 90.0 {
            ("end", zx - 6.0)
        } else {
            ("start", zx + 6.0)
        };
        s.push_str(&format!(
            "<text x=\"{lx:.1}\" y=\"{:.1}\" font-size=\"10\" fill=\"{PRED}\" \
             text-anchor=\"{anchor}\">{}</text>",
            (zy - 7.0).max(mt + 2.0),
            esc(&label)
        ));
    }

    s.push_str("</svg>");
    s
}
