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
