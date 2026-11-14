//! Messages between the app and the terminal view: one JSON request per line, one JSON reply per
//! line. Sources/MacMonIndicator/TerminalServer.swift defines the other side; keep them in step.
//! The app computes and formats everything, so the terminal shows the same numbers as the menu.

use serde::{Deserialize, Serialize};

/// The reply version this build understands (TerminalServer.version).
pub const VERSION: u32 = 1;

#[derive(Serialize, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub cmd: &'static str,
    // live
    #[serde(skip_serializing_if = "Option::is_none")]
    pub tier: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub points: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sort: Option<u8>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rows: Option<usize>,
    // history
    #[serde(skip_serializing_if = "Option::is_none")]
    pub range: Option<usize>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub by_executable: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub sort_by: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub ascending: Option<bool>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub filter: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub limit: Option<usize>,
}

/// Just the version, read first: a reply from a newer app may not fit the structs below.
#[derive(Deserialize, Default)]
#[serde(default)]
pub struct Header {
    pub version: u32,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct Live {
    pub version: u32,
    pub app: String,
    pub host: String,
    pub time: f64,
    pub interval_ms: u32,
    pub problem: Option<String>,
    pub tiers: Vec<String>,
    pub tier: usize,
    /// The menu's chart columns (Settings), 0 from an app that doesn't say.
    pub columns: u8,
    pub charts: Vec<Chart>,
    pub processes: Processes,
    pub process_history: bool,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct Chart {
    pub id: String,
    pub title: String,
    /// "up"; "mirrored": `avg2`/`max2` downward from the middle; "signed": centered at zero.
    pub shape: String,
    pub color: String,
    pub color2: Option<String>,
    pub main: String,
    pub detail: Option<String>,
    /// Over the warning limit now.
    pub hot: bool,
    pub lo: f32,
    pub hi: f32,
    pub lo2: Option<f32>,
    pub hi2: Option<f32>,
    /// Bars blend toward red from `warn_start`, and are red from `limit`.
    pub warn_start: Option<f32>,
    pub limit: Option<f32>,
    pub avg: Vec<Option<f32>>,
    pub max: Vec<Option<f32>>,
    pub avg2: Option<Vec<Option<f32>>>,
    pub max2: Option<Vec<Option<f32>>>,
}

#[derive(Deserialize, Default, Clone)]
#[serde(default)]
pub struct Processes {
    pub columns: Vec<Column>,
    pub sort: Option<u8>,
    /// None while the app's first process scans run.
    pub rows: Option<Vec<ProcessRow>>,
    pub note: String,
}

#[derive(Deserialize, Default, Clone)]
#[serde(default)]
pub struct Column {
    pub title: String,
    pub sort: u8,
}

#[derive(Deserialize, Default, Clone)]
#[serde(default)]
pub struct ProcessRow {
    pub pid: i32,
    pub name: String,
    pub cells: Vec<String>,
    /// The column it was picked for.
    pub strong: usize,
}

#[derive(Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase", default)]
pub struct History {
    pub version: u32,
    pub tracking: bool,
    pub ranges: Vec<String>,
    pub range: usize,
    pub by_executable: bool,
    pub columns: Vec<HistoryColumn>,
    pub sort_by: String,
    pub ascending: bool,
    /// Rows matching, before the limit.
    pub total: usize,
    pub rows: Vec<HistoryRow>,
    pub footer: Vec<String>,
}

#[derive(Deserialize, Default, Clone)]
#[serde(default)]
pub struct HistoryColumn {
    pub id: String,
    pub title: String,
    pub tip: String,
}

#[derive(Deserialize, Default, Clone)]
#[serde(default)]
pub struct HistoryRow {
    pub name: String,
    pub path: String,
    pub cells: Vec<String>,
    /// The value can't be known (system processes without the root helper).
    pub unknown: Vec<bool>,
}

/// Both sides of the protocol are tested against the files in Tests/protocol/ (see
/// Tests/MacMonIndicatorTests/ProtocolTests.swift, which says how to update them):
/// the replies there are what the app encodes, the requests what this program encodes.
#[cfg(test)]
mod tests {
    use super::*;

    const LIVE: &str = include_str!("../../Tests/protocol/live.json");
    const HISTORY: &str = include_str!("../../Tests/protocol/history.json");
    const REQUEST_LIVE: &str = include_str!("../../Tests/protocol/request-live.json");
    const REQUEST_HISTORY: &str = include_str!("../../Tests/protocol/request-history.json");

    fn some(v: &[Option<f32>]) -> Option<Vec<Option<f32>>> {
        Some(v.to_vec())
    }

    #[test]
    fn replies_carry_this_version() {
        assert_eq!(serde_json::from_str::<Header>(LIVE).unwrap().version, VERSION);
        assert_eq!(serde_json::from_str::<Header>(HISTORY).unwrap().version, VERSION);
        // A reply without one (not from the app) reads as version 0, which is never ours.
        assert_eq!(serde_json::from_str::<Header>("{}").unwrap().version, 0);
    }

    /// Every field has a value in the file that is not the field's default, so a field the app
    /// renamed or dropped (which would silently read as the default) fails here.
    #[test]
    fn reads_every_field_of_a_live_reply() {
        let l: Live = serde_json::from_str(LIVE).unwrap();
        assert_eq!(l.version, VERSION);
        assert_eq!(l.app, "9.8.7");
        assert_eq!(l.host, "mac-mini");
        assert_eq!(l.time, 1_800_000_000.5);
        assert_eq!(l.interval_ms, 2000);
        assert_eq!(l.problem.as_deref(), Some("macmon was not found"));
        assert_eq!(l.tiers, ["1m", "5m", "1h"]);
        assert_eq!(l.tier, 1);
        assert_eq!(l.columns, 2);
        assert!(l.process_history);

        assert_eq!(l.charts.len(), 2);
        let c = &l.charts[0];
        assert_eq!(c.id, "disk");
        assert_eq!(c.title, "Disk");
        assert_eq!(c.shape, "mirrored");
        assert_eq!(c.color, "blue");
        assert_eq!(c.color2.as_deref(), Some("pink"));
        assert_eq!(c.main, "12M");
        assert_eq!(c.detail.as_deref(), Some("R 8M  W 4M"));
        assert!(c.hot);
        assert_eq!((c.lo, c.hi), (0.5, 100.0));
        assert_eq!((c.lo2, c.hi2), (Some(0.25), Some(50.0)));
        assert_eq!((c.warn_start, c.limit), (Some(65.0), Some(90.0)));
        assert_eq!(c.avg, [Some(1.5), None, Some(3.0)]);
        assert_eq!(c.max, [Some(2.0), None, Some(4.0)]);
        assert_eq!(c.avg2, some(&[Some(0.75), None]));
        assert_eq!(c.max2, some(&[Some(1.25), None]));
        // A chart without the optional fields.
        let c = &l.charts[1];
        assert_eq!(c.id, "cpu");
        assert_eq!(c.shape, "up");
        assert!(c.color2.is_none() && c.detail.is_none() && c.lo2.is_none() && c.hi2.is_none());
        assert!(c.warn_start.is_none() && c.limit.is_none() && c.avg2.is_none() && c.max2.is_none());
        assert!(!c.hot && c.avg.is_empty() && c.max.is_empty());

        let p = &l.processes;
        assert_eq!(p.columns.len(), 1);
        assert_eq!(p.columns[0].title, "CPU");
        assert_eq!(p.columns[0].sort, 3);
        assert_eq!(p.sort, Some(3));
        assert_eq!(p.note, "System processes: 3% CPU");
        let rows = p.rows.as_ref().unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].pid, 4321);
        assert_eq!(rows[0].name, "node");
        assert_eq!(rows[0].cells, ["12.5%"]);
        assert_eq!(rows[0].strong, 1);
    }

    #[test]
    fn reads_every_field_of_a_history_reply() {
        let h: History = serde_json::from_str(HISTORY).unwrap();
        assert_eq!(h.version, VERSION);
        assert!(h.tracking);
        assert_eq!(h.ranges, ["Today", "24 Hours"]);
        assert_eq!(h.range, 1);
        assert!(h.by_executable);
        assert_eq!(h.columns.len(), 1);
        assert_eq!(h.columns[0].id, "cpu");
        assert_eq!(h.columns[0].title, "CPU time");
        assert_eq!(h.columns[0].tip, "CPU seconds used");
        assert_eq!(h.sort_by, "cpu");
        assert!(h.ascending);
        assert_eq!(h.total, 77);
        assert_eq!(h.rows.len(), 1);
        assert_eq!(h.rows[0].name, "node");
        assert_eq!(h.rows[0].path, "/opt/homebrew/Cellar/node/*/bin/node");
        assert_eq!(h.rows[0].cells, ["3h 12m"]);
        assert_eq!(h.rows[0].unknown, [true]);
        assert_eq!(h.footer, ["Unseen: 4.0s", "Last scan 10:05"]);
    }

    /// The file lists every key the app encodes. One this program doesn't read is fine (`kind`,
    /// and `values`, which is for `--json`), but a new one should be a decision, not an accident.
    #[test]
    fn knows_every_key_the_app_sends() {
        fn keys(v: &serde_json::Value) -> Vec<&str> {
            v.as_object().unwrap().keys().map(String::as_str).collect()
        }
        let l: serde_json::Value = serde_json::from_str(LIVE).unwrap();
        assert_eq!(
            keys(&l),
            [
                "app", "charts", "columns", "host", "intervalMs", "kind", "problem", "processHistory", "processes",
                "tier", "tiers", "time", "values", "version"
            ]
        );
        assert_eq!(
            keys(&l["charts"][0]),
            [
                "avg", "avg2", "color", "color2", "detail", "hi", "hi2", "hot", "id", "limit", "lo", "lo2", "main",
                "max", "max2", "shape", "title", "warnStart"
            ]
        );
        assert_eq!(keys(&l["processes"]), ["columns", "note", "rows", "sort"]);
        assert_eq!(keys(&l["processes"]["columns"][0]), ["sort", "title"]);
        assert_eq!(keys(&l["processes"]["rows"][0]), ["cells", "name", "pid", "strong"]);
        let h: serde_json::Value = serde_json::from_str(HISTORY).unwrap();
        assert_eq!(
            keys(&h),
            [
                "ascending", "byExecutable", "columns", "footer", "kind", "range", "ranges", "rows", "sortBy",
                "total", "tracking", "version"
            ]
        );
        assert_eq!(keys(&h["columns"][0]), ["id", "tip", "title"]);
        assert_eq!(keys(&h["rows"][0]), ["cells", "name", "path", "unknown"]);
    }

    #[test]
    fn writes_requests_as_the_app_reads_them() {
        let live = Request {
            cmd: "live",
            tier: Some(2),
            points: Some(120),
            sort: Some(3),
            rows: Some(15),
            ..Default::default()
        };
        assert_eq!(serde_json::to_string(&live).unwrap(), REQUEST_LIVE.trim_end());
        let history = Request {
            cmd: "history",
            range: Some(4),
            by_executable: Some(true),
            sort_by: Some("energy".into()),
            ascending: Some(true),
            filter: Some("chrome".into()),
            limit: Some(250),
            ..Default::default()
        };
        assert_eq!(serde_json::to_string(&history).unwrap(), REQUEST_HISTORY.trim_end());
        // Nothing but the command when nothing else is set (`--once`).
        let bare = Request { cmd: "live", ..Default::default() };
        assert_eq!(serde_json::to_string(&bare).unwrap(), r#"{"cmd":"live"}"#);
    }
}
