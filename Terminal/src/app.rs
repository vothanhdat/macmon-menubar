//! What the terminal view shows and asks the app for, and what the keys do.

use std::time::Duration;

use ratatui::crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

use crate::client::Client;
use crate::proto::{self, Header, History, Live, Request};

#[derive(Clone, Copy, PartialEq)]
pub enum View {
    Live,
    History,
}

pub enum Action {
    None,
    Quit,
    /// Ask the app again now (a setting changed).
    Fetch,
}

pub struct App {
    pub view: View,
    client: Option<Client>,
    /// Why there is nothing (new) to show: not connected, or the app answered something unreadable.
    pub error: Option<String>,
    pub live: Option<Live>,
    pub history: Option<History>,
    /// The raw reply, for --json.
    pub raw: String,

    // Live view
    pub tier: usize,
    /// ProcessListView.Sort raw value, None for the top few by each column.
    pub sort: Option<u8>,
    /// Chart width and process rows at the last draw: what to ask for next.
    pub points: usize,
    pub proc_rows: usize,

    // Process history
    pub range: usize,
    pub by_executable: bool,
    pub sort_by: String,
    pub ascending: bool,
    pub filter: String,
    pub filtering: bool,
    pub selected: usize,
    pub scroll: usize,
    /// Table rows visible at the last draw.
    pub page: usize,
    pub limit: usize,
}

impl App {
    pub fn new(view: View, tier: usize, range: usize) -> App {
        App {
            view,
            client: None,
            error: None,
            live: None,
            history: None,
            raw: String::new(),
            tier,
            sort: None,
            points: 120,
            proc_rows: 10,
            range,
            by_executable: false,
            sort_by: "cpu".into(),
            ascending: false,
            filter: String::new(),
            filtering: false,
            selected: 0,
            scroll: 0,
            page: 20,
            limit: 500,
        }
    }

    /// How long until the next request: live readings every second, process history (scanned
    /// every 5 minutes) every 10 s.
    pub fn period(&self) -> Duration {
        match (self.view, &self.error) {
            (_, Some(_)) | (View::Live, _) => Duration::from_secs(1),
            (View::History, None) => Duration::from_secs(10),
        }
    }

    fn request(&self) -> Request {
        match self.view {
            View::Live => Request {
                cmd: "live",
                tier: Some(self.tier),
                points: Some(self.points.max(8)),
                sort: self.sort,
                rows: Some(self.proc_rows.max(1)),
                ..Default::default()
            },
            View::History => Request {
                cmd: "history",
                range: Some(self.range),
                by_executable: Some(self.by_executable),
                sort_by: Some(self.sort_by.clone()),
                ascending: Some(self.ascending),
                filter: Some(self.filter.clone()),
                limit: Some(self.limit),
                ..Default::default()
            },
        }
    }

    /// Asks the app for what the current view shows, connecting first if needed.
    pub fn fetch(&mut self) {
        if self.client.is_none() {
            match Client::connect() {
                Ok(c) => self.client = Some(c),
                Err(e) => {
                    self.error = Some(e);
                    return;
                }
            }
        }
        let req = self.request();
        let reply = match self.client.as_mut().map(|c| c.request(&req)) {
            Some(Ok(r)) => r,
            Some(Err(e)) => {
                self.client = None; // reconnect next time (the app may have restarted)
                self.error = Some(e);
                return;
            }
            None => return,
        };
        let version = serde_json::from_str::<Header>(&reply).map(|h| h.version).unwrap_or(0);
        if version != proto::VERSION {
            self.error = Some(format!(
                "The running MacMon Indicator speaks terminal version {version}, this command version {}. \
                 Update both to the same release (and restart the app).",
                proto::VERSION
            ));
            return;
        }
        let parsed = match self.view {
            View::Live => serde_json::from_str::<Live>(&reply).map(|l| self.live = Some(l)),
            View::History => serde_json::from_str::<History>(&reply).map(|h| self.history = Some(h)),
        };
        match parsed {
            Ok(()) => {
                self.error = None;
                self.raw = reply;
            }
            Err(e) => self.error = Some(format!("Can't read the app's reply: {e}")),
        }
    }

    fn tiers(&self) -> usize {
        self.live.as_ref().map(|l| l.tiers.len()).filter(|&n| n > 0).unwrap_or(6)
    }

    fn ranges(&self) -> usize {
        self.history.as_ref().map(|h| h.ranges.len()).filter(|&n| n > 0).unwrap_or(5)
    }

    pub fn key(&mut self, k: KeyEvent) -> Action {
        if k.modifiers.contains(KeyModifiers::CONTROL) && matches!(k.code, KeyCode::Char('c') | KeyCode::Char('d')) {
            return Action::Quit;
        }
        if self.filtering {
            return self.filter_key(k);
        }
        match k.code {
            KeyCode::Char('q') => return Action::Quit,
            KeyCode::Tab | KeyCode::BackTab | KeyCode::Char('h') => {
                self.view = if self.view == View::Live { View::History } else { View::Live };
                return Action::Fetch;
            }
            _ => {}
        }
        match self.view {
            View::Live => self.live_key(k),
            View::History => self.history_key(k),
        }
    }

    fn live_key(&mut self, k: KeyEvent) -> Action {
        let n = self.tiers();
        match k.code {
            KeyCode::Char(c @ '1'..='9') if (c as usize - '1' as usize) < n => self.tier = c as usize - '1' as usize,
            KeyCode::Left => self.tier = (self.tier + n - 1) % n,
            KeyCode::Right => self.tier = (self.tier + 1) % n,
            KeyCode::Char('s') => self.sort = self.next_sort(1),
            KeyCode::Char('S') => self.sort = self.next_sort(-1),
            _ => return Action::None,
        }
        Action::Fetch
    }

    /// The next process sort: none (the top few by each column), then each column in turn.
    fn next_sort(&self, step: isize) -> Option<u8> {
        let cols: Vec<Option<u8>> = std::iter::once(None)
            .chain(self.live.iter().flat_map(|l| l.processes.columns.iter().map(|c| Some(c.sort))))
            .collect();
        let i = cols.iter().position(|&s| s == self.sort).unwrap_or(0) as isize;
        cols[(i + step).rem_euclid(cols.len() as isize) as usize]
    }

    fn history_key(&mut self, k: KeyEvent) -> Action {
        let n = self.ranges();
        let rows = self.history.as_ref().map(|h| h.rows.len()).unwrap_or(0);
        let page = self.page.max(1);
        match k.code {
            KeyCode::Char(c @ '1'..='9') if (c as usize - '1' as usize) < n => self.range = c as usize - '1' as usize,
            KeyCode::Left => self.range = (self.range + n - 1) % n,
            KeyCode::Right => self.range = (self.range + 1) % n,
            KeyCode::Char('e') => {
                self.by_executable = !self.by_executable;
                self.selected = 0;
            }
            KeyCode::Char('s') | KeyCode::Char('S') => {
                let ids: Vec<String> = self.history.iter().flat_map(|h| h.columns.iter().map(|c| c.id.clone())).collect();
                if ids.is_empty() {
                    return Action::None;
                }
                let i = ids.iter().position(|id| *id == self.sort_by).unwrap_or(0) as isize;
                let step = if k.code == KeyCode::Char('s') { 1 } else { -1 };
                self.sort_by = ids[(i + step).rem_euclid(ids.len() as isize) as usize].clone();
                self.ascending = self.sort_by == "name";
            }
            KeyCode::Char('r') => self.ascending = !self.ascending,
            KeyCode::Char('/') => {
                self.filtering = true;
                return Action::None;
            }
            KeyCode::Esc if !self.filter.is_empty() => {
                self.filter.clear();
                self.selected = 0;
            }
            KeyCode::Esc => {
                self.view = View::Live;
            }
            KeyCode::Up | KeyCode::Char('k') => {
                self.selected = self.selected.saturating_sub(1);
                return Action::None;
            }
            KeyCode::Down | KeyCode::Char('j') => {
                self.selected = (self.selected + 1).min(rows.saturating_sub(1));
                return Action::None;
            }
            KeyCode::PageUp => {
                self.selected = self.selected.saturating_sub(page);
                return Action::None;
            }
            KeyCode::PageDown | KeyCode::Char(' ') => {
                self.selected = (self.selected + page).min(rows.saturating_sub(1));
                return Action::None;
            }
            KeyCode::Home | KeyCode::Char('g') => {
                self.selected = 0;
                return Action::None;
            }
            KeyCode::End | KeyCode::Char('G') => {
                self.selected = rows.saturating_sub(1);
                return Action::None;
            }
            _ => return Action::None,
        }
        Action::Fetch
    }

    /// Typing a filter: it applies as you type; Enter keeps it, Esc clears it.
    fn filter_key(&mut self, k: KeyEvent) -> Action {
        match k.code {
            KeyCode::Enter => {
                self.filtering = false;
                return Action::None;
            }
            KeyCode::Esc => {
                self.filtering = false;
                self.filter.clear();
            }
            KeyCode::Backspace => {
                self.filter.pop();
            }
            KeyCode::Char(c) if !k.modifiers.contains(KeyModifiers::CONTROL) => self.filter.push(c),
            _ => return Action::None,
        }
        self.selected = 0;
        Action::Fetch
    }
}
