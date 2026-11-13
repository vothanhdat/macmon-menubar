//! `macmon-indicator`: MacMon Indicator in a terminal, for example over SSH. It shows what the
//! menu shows (charts over a chosen range, top processes) and the process history, reading them
//! from the running app over a socket only your user can open (see client.rs and proto.rs).

mod app;
mod chart;
mod client;
mod proto;
mod style;
mod ui;

use std::io::{IsTerminal, Write};
use std::process::ExitCode;
use std::time::{Duration, Instant};

use ratatui::buffer::Buffer;
use ratatui::crossterm::event::{self, Event, KeyEventKind};
use ratatui::layout::Rect;

use app::{Action, App, View};

const VERSION: &str = match option_env!("MACMON_INDICATOR_VERSION") {
    Some(v) => v,
    None => env!("CARGO_PKG_VERSION"),
};

const HELP: &str = "\
macmon-indicator: MacMon Indicator in a terminal (also over SSH)

Shows what the menu shows (charts and top processes) and the process history, from
MacMon Indicator running on this Mac.

Usage: macmon-indicator [options]

  (no options)     live view; h switches to process history, q quits
  --history        start on process history
  --range RANGE    charts: 1m 5m 1h 24h 7d 30d (default 5m)
                   process history: today 24h 7d 30d 90d (default today)
  --executables    process history by executable instead of by app
  --once           print once and exit (also when the output isn't a terminal)
  --json           print the app's reply as JSON and exit
  -h, --help       this help
  -V, --version    the version

Keys, live view:     1-6 or ←→ range, s/S process sort, h process history, q quit
Keys, history:       1-5 or ←→ range, e apps/executables, s/S sort column, r reverse,
                     / filter, ↑↓ PgUp PgDn move, Esc back, q quit
";

const TIERS: [&str; 6] = ["1m", "5m", "1h", "24h", "7d", "30d"];
const RANGES: [&str; 5] = ["today", "24h", "7d", "30d", "90d"];

struct Opts {
    history: bool,
    range: Option<String>,
    executables: bool,
    once: bool,
    json: bool,
}

fn parse() -> Result<Option<Opts>, String> {
    let mut o = Opts { history: false, range: None, executables: false, once: false, json: false };
    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "-h" | "--help" => {
                print!("{HELP}");
                return Ok(None);
            }
            "-V" | "--version" => {
                println!("macmon-indicator {VERSION}");
                return Ok(None);
            }
            "--history" => o.history = true,
            "--executables" => o.executables = true,
            "--once" => o.once = true,
            "--json" => o.json = true,
            "--range" => o.range = Some(args.next().ok_or("--range needs a value")?),
            _ if a.starts_with("--range=") => o.range = Some(a["--range=".len()..].to_string()),
            _ => return Err(format!("unknown option: {a}")),
        }
    }
    Ok(Some(o))
}

fn main() -> ExitCode {
    let opts = match parse() {
        Ok(Some(o)) => o,
        Ok(None) => return ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("macmon-indicator: {e}\n\n{HELP}");
            return ExitCode::from(2);
        }
    };
    let list: &[&str] = if opts.history { &RANGES } else { &TIERS };
    let index = match &opts.range {
        None => if opts.history { 0 } else { 1 },
        Some(r) => match list.iter().position(|t| t.eq_ignore_ascii_case(r)) {
            Some(i) => i,
            None => {
                eprintln!("macmon-indicator: --range {r}: use one of {}", list.join(" "));
                return ExitCode::from(2);
            }
        },
    };
    let view = if opts.history { View::History } else { View::Live };
    let mut app = App::new(view, if opts.history { 1 } else { index }, if opts.history { index } else { 0 });
    app.by_executable = opts.executables;

    let tty = std::io::stdout().is_terminal() && std::io::stdin().is_terminal();
    if opts.json || opts.once || !tty {
        style::set_mode(style::detect(std::io::stdout().is_terminal() && !opts.json));
        return once(app, opts.json);
    }
    style::set_mode(style::detect(true));
    interactive(app)
}

/// Prints the view once. The app starts scanning processes when a terminal connects, and their
/// CPU use needs two scans, so the live view waits (up to 3 s) for those.
fn once(mut app: App, json: bool) -> ExitCode {
    let width = ratatui::crossterm::terminal::size().map(|s| s.0).ok()
        .filter(|_| std::io::stdout().is_terminal()).unwrap_or(100).max(60);
    let area = Rect::new(0, 0, width, 400);
    let start = Instant::now();
    loop {
        app.fetch();
        let ready = match app.view {
            View::Live => app.live.as_ref().is_some_and(|l| {
                l.processes.rows.as_ref().is_some_and(|r| r.iter().any(|p| p.cells.first().is_some_and(|c| c != "–")))
            }),
            View::History => app.history.is_some(),
        };
        let have = app.live.is_some() || app.history.is_some();
        if !have && app.error.is_some() {
            eprintln!("macmon-indicator: {}", app.error.as_deref().unwrap_or(""));
            return ExitCode::FAILURE;
        }
        // Lay out once so the next request asks for charts as wide as they'll be drawn.
        ui::render(&mut app, area, &mut Buffer::empty(area), true);
        if ready || start.elapsed() > Duration::from_secs(3) {
            break;
        }
        std::thread::sleep(Duration::from_millis(300));
    }
    let mut out = std::io::stdout().lock();
    if json {
        let pretty = serde_json::from_str::<serde_json::Value>(&app.raw)
            .and_then(|v| serde_json::to_string_pretty(&v)).unwrap_or_else(|_| app.raw.clone());
        let _ = writeln!(out, "{}", pretty.trim_end());
        return ExitCode::SUCCESS;
    }
    let mut buf = Buffer::empty(area);
    let rows = ui::render(&mut app, area, &mut buf, true);
    let _ = out.write_all(style::dump(&buf, rows, style::mode() != style::ColorMode::None).as_bytes());
    ExitCode::SUCCESS
}

fn interactive(mut app: App) -> ExitCode {
    let mut terminal = ratatui::init();
    let mut next = Instant::now();
    let result = (|| -> std::io::Result<()> {
        loop {
            if Instant::now() >= next {
                app.fetch();
                next = Instant::now() + app.period();
            }
            terminal.draw(|f| {
                let area = f.area();
                ui::render(&mut app, area, f.buffer_mut(), false);
            })?;
            if event::poll(next.saturating_duration_since(Instant::now()))? {
                if let Event::Key(k) = event::read()? {
                    if k.kind == KeyEventKind::Release {
                        continue;
                    }
                    match app.key(k) {
                        Action::Quit => return Ok(()),
                        Action::Fetch => next = Instant::now(),
                        Action::None => {}
                    }
                }
            }
        }
    })();
    ratatui::restore();
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("macmon-indicator: {e}");
            ExitCode::FAILURE
        }
    }
}
