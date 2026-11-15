//! The two screens: live (charts and top processes, as in the menu) and process history. Charts
//! and tables sit in boxes, with their titles and values in the top border.

use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};
use ratatui::text::{Line, Span};
use ratatui::widgets::{Block, BorderType, Widget};

use crate::app::{App, View};
use crate::chart;
use crate::proto::{Chart, History, HistoryChart, Processes};
use crate::stack;
use crate::style::{self, bold, dim, fit, fg, right, selected, width, wrap, Rgb, RED};

/// Smallest usable size.
const MIN_W: u16 = 44;
const MIN_H: u16 = 12;

/// Draws the current view; returns the rows used (for `--once`, which prints only those).
/// `once`: printing once to stdout: compact charts, no key hints.
pub fn render(app: &mut App, area: Rect, buf: &mut Buffer, once: bool) -> u16 {
    if !once && (area.width < MIN_W || area.height < MIN_H) {
        put(buf, area.x, area.y, "Make the terminal a bit bigger (q quits).", area.width, dim());
        return area.height;
    }
    match app.view {
        View::Live if app.live.is_some() => live(app, area, buf, once),
        View::History if app.history.is_some() => history(app, area, buf, once),
        _ => waiting(app, area, buf),
    }
}

/// Writes `s` at (x, y), at most `w` columns; returns the column after it.
fn put(buf: &mut Buffer, x: u16, y: u16, s: &str, w: u16, st: Style) -> u16 {
    if w == 0 || y >= buf.area.bottom() || x >= buf.area.right() {
        return x;
    }
    buf.set_stringn(x, y, s, w as usize, st).0
}

/// A rounded box with titles in its top border (left and right) and optionally its bottom
/// border; returns the space inside.
fn boxed(buf: &mut Buffer, area: Rect, left: Line, right: Option<Line>, bottom: Option<Line>) -> Rect {
    let mut b = Block::bordered().border_type(BorderType::Rounded).border_style(dim()).title_top(left.left_aligned());
    if let Some(r) = right {
        b = b.title_top(r.right_aligned());
    }
    if let Some(l) = bottom {
        b = b.title_bottom(l.left_aligned());
    }
    let inner = b.inner(area);
    b.render(area, buf);
    inner
}

/// The first of `options` (longest first) that fits in `w` columns, else the last.
fn longest_fitting<'a>(options: &[&'a str], w: u16) -> &'a str {
    options.iter().copied().find(|o| width(o) <= w as usize).unwrap_or(options[options.len() - 1])
}

/// Local time of day.
fn clock(t: f64) -> String {
    let secs = t as libc::time_t;
    // SAFETY: localtime_r fills the zeroed struct.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    unsafe { libc::localtime_r(&secs, &mut tm) };
    format!("{:02}:{:02}:{:02}", tm.tm_hour, tm.tm_min, tm.tm_sec)
}

fn waiting(app: &App, area: Rect, buf: &mut Buffer) -> u16 {
    let msg = app.error.clone().unwrap_or_else(|| "Connecting to MacMon Indicator…".into());
    let mut lines: Vec<(String, Style)> = vec![("MacMon Indicator".into(), bold()), (String::new(), Style::new())];
    for l in wrap(&msg, (area.width as usize).saturating_sub(4).max(20)) {
        lines.push((l, Style::new()));
    }
    lines.push((String::new(), Style::new()));
    lines.push(("Start it on this Mac:  open -a \"MacMon Indicator\"".into(), dim()));
    lines.push(("Retrying every second. q quits.".into(), dim()));
    let top = area.y + area.height.saturating_sub(lines.len() as u16) / 2;
    for (i, (l, st)) in lines.iter().enumerate() {
        let x = area.x + area.width.saturating_sub(width(l) as u16) / 2;
        put(buf, x, top + i as u16, l, area.width, *st);
    }
    area.height
}

/// Tabs like " 5m ", the selected one highlighted; returns the column after them.
fn tabs(buf: &mut Buffer, mut x: u16, y: u16, labels: &[String], sel: usize, end: u16) -> u16 {
    for (i, l) in labels.iter().enumerate() {
        let t = format!(" {l} ");
        if x + width(&t) as u16 > end {
            break;
        }
        x = put(buf, x, y, &t, end - x, if i == sel { selected() } else { dim() });
    }
    x
}

fn messages(app: &App, problem: Option<&String>, area: Rect, buf: &mut Buffer, mut y: u16) -> u16 {
    for msg in [problem, app.error.as_ref()].into_iter().flatten() {
        put(buf, area.x, y, &fit(msg, area.width as usize), area.width, fg(RED));
        y += 1;
    }
    y
}

// MARK: - Live

fn live(app: &mut App, area: Rect, buf: &mut Buffer, once: bool) -> u16 {
    let Some(d) = app.live.as_ref() else { return 0 };
    let w = area.width;
    let end = area.right();

    // Header: name, host, range tabs, the app's clock.
    let mut x = put(buf, area.x, area.y, "MacMon Indicator", w, bold());
    x = put(buf, x, area.y, &format!(" · {}", d.host), end - x, dim());
    let time = clock(d.time);
    let tabs_end = end.saturating_sub(width(&time) as u16 + 2);
    if !once {
        tabs(buf, x + 3, area.y, &d.tiers, d.tier, tabs_end);
    } else if let Some(t) = d.tiers.get(d.tier) {
        put(buf, x + 3, area.y, &format!("last {t}"), tabs_end.saturating_sub(x + 3), dim());
    }
    put(buf, end - width(&time) as u16, area.y, &time, width(&time) as u16, dim());
    let mut y = messages(app, d.problem.as_ref(), area, buf, area.y + 1);

    let footer_y = if once { u16::MAX } else { area.bottom() - 1 };
    // Rows for the chart boxes and the process rows: all but the process box's borders and
    // column titles, and the keys.
    let avail = if once { u16::MAX } else { footer_y.saturating_sub(y + 3) };

    // Charts in a grid of boxes, as in the menu's grid: title, details and value in the top
    // border, the bars inside. The menu's number of columns (Settings), or more when the terminal
    // is too short for them and wide enough; the charts as tall as fits while leaving ten
    // process rows.
    let gap: u16 = 1;
    let width_cols = ((w + gap) / (34 + gap)).clamp(1, (d.charts.len() as u16).clamp(1, 3));
    let row_h = |g: &[Chart], h: u16| 2 + g.iter().map(|c| chart::rows_for(c, h)).max().unwrap_or(0);
    let need = |cols: u16, h: u16| -> u16 { d.charts.chunks(cols as usize).map(|g| row_h(g, h)).sum() };
    let mut cols = (if d.columns == 0 { 2 } else { d.columns as u16 }).clamp(1, width_cols);
    while !once && cols < width_cols && need(cols, 1) + 5 > avail {
        cols += 1;
    }
    let h = if once { 1 } else { (1..=8).rev().find(|&h| need(cols, h) + 10 <= avail).unwrap_or(1) };
    let charts_end = if once { u16::MAX } else { y + need(cols, h).min(avail.saturating_sub(3)) };
    let cell_w = (w - gap * (cols - 1)) / cols;

    for g in d.charts.chunks(cols as usize) {
        // Boxes in a row are as tall as the tallest, so they line up.
        let gh = row_h(g, h);
        if y + gh > charts_end {
            break;
        }
        for (ci, c) in g.iter().enumerate() {
            let x0 = area.x + ci as u16 * (cell_w + gap);
            let (left, right) = chart_titles(c, cell_w);
            let inner = boxed(buf, Rect::new(x0, y, cell_w, gh), left, Some(right), None);
            chart::draw(buf, inner, c);
        }
        y += gh;
    }

    // Top processes, as many rows as fit (10 when printing once).
    let max_rows = if once { 10 } else { footer_y.saturating_sub(y + 3).min(20) };
    y += processes(buf, Rect::new(area.x, y, w, 3 + max_rows), &d.processes);

    // Two buckets per cell (see chart.rs).
    let (points, proc_rows) = ((cell_w.saturating_sub(2)) as usize * 2, max_rows as usize);
    if !once {
        let keys = longest_fitting(&["1–6 ←→ range   s sort   h process history   q quit",
                                     "1–6 range  s sort  h history  q quit"], w);
        put(buf, area.x, footer_y, keys, w, dim());
        let info = format!("v{} · every {} s", d.app, (d.interval_ms as f32 / 1000.0).max(1.0).round());
        if width(keys) + width(&info) + 2 < w as usize {
            put(buf, end - width(&info) as u16, footer_y, &info, width(&info) as u16, dim());
        }
        y = area.bottom();
    }
    app.points = points;
    app.proc_rows = proc_rows;
    y - area.y
}

/// A chart box's titles: its name at the left; the details and the value at the right, as on
/// the menu's label row. The value is red over the warning limit; a mirrored chart's two values
/// ("R … · W …") take the colors of its two halves. The details go first when there's no room.
fn chart_titles(c: &Chart, box_w: u16) -> (Line<'static>, Line<'static>) {
    let left = Line::from(Span::styled(format!(" {} ", c.title), fg(style::named(&c.color))));
    // Corners, the left title and a bit of border between the two.
    let room = (box_w as usize).saturating_sub(2 + width(&c.title) + 2 + 1);
    let strong = |st: Style| st.add_modifier(Modifier::BOLD);
    let main = fit(&c.main, room.saturating_sub(2));
    let mut spans = vec![Span::raw(" ")];
    if let Some(det) = &c.detail {
        let space = room.saturating_sub(width(&main) + 4);
        if space >= 4 {
            spans.push(Span::styled(fit(det, space), dim()));
            spans.push(Span::raw("  "));
        }
    }
    match (c.shape.as_str(), c.main.split_once(" · ")) {
        ("mirrored", Some((a, b))) if main == c.main => {
            spans.push(Span::styled(a.to_string(), strong(fg(style::named(&c.color)))));
            spans.push(Span::styled(" · ", dim()));
            spans.push(Span::styled(b.to_string(), strong(fg(style::named(c.color2.as_deref().unwrap_or(&c.color))))));
        }
        _ => spans.push(Span::styled(main, strong(if c.hot { fg(RED) } else { Style::new() }))),
    }
    spans.push(Span::raw(" "));
    (left, Line::from(spans))
}

/// The top processes box, with the note in its bottom border; returns the rows used.
fn processes(buf: &mut Buffer, area: Rect, p: &Processes) -> u16 {
    let list = p.rows.as_deref().unwrap_or(&[]);
    let rows = list.len().min(area.height.saturating_sub(3) as usize).max(1);
    let rect = Rect { height: (3 + rows as u16).min(area.height), ..area };
    let note = (!p.note.is_empty()).then(|| {
        Line::from(Span::styled(format!(" {} ", fit(&p.note, (area.width as usize).saturating_sub(6))), dim()))
    });
    let inner = boxed(buf, rect, Line::from(Span::styled(" Top processes ", bold())), None, note);

    let sorted = |i: usize| p.sort == p.columns.get(i).map(|c| c.sort);
    let mut widths: Vec<usize> = p.columns.iter().enumerate().map(|(i, c)| {
        let title = width(&c.title) + if sorted(i) { 2 } else { 0 };
        list.iter().take(rows).filter_map(|r| r.cells.get(i)).map(|s| width(s)).max().unwrap_or(0).max(title).max(4)
    }).collect();
    // Narrow terminal: drop columns from the right while the name gets too little room.
    let name_w = |ws: &[usize]| (inner.width as usize).saturating_sub(ws.iter().map(|w| w + 2).sum::<usize>());
    while widths.len() > 1 && name_w(&widths) < 14 {
        widths.pop();
    }
    let nw = name_w(&widths);

    put(buf, inner.x, inner.y, "Name", nw as u16, dim());
    let mut x = inner.x + nw as u16;
    for (i, cw) in widths.iter().enumerate() {
        let t = if sorted(i) { format!("{} ▾", p.columns[i].title) } else { p.columns[i].title.clone() };
        put(buf, x + 2, inner.y, &right(&t, *cw), *cw as u16, if sorted(i) { selected() } else { dim() });
        x += 2 + *cw as u16;
    }
    if p.rows.is_none() {
        put(buf, inner.x, inner.y + 1, "Collecting…", inner.width, dim());
    }
    for (ri, r) in list.iter().take(rows).enumerate() {
        let y = inner.y + 1 + ri as u16;
        put(buf, inner.x, y, &fit(&r.name, nw), nw as u16, Style::new());
        let mut x = inner.x + nw as u16;
        for (i, cw) in widths.iter().enumerate() {
            let cell = r.cells.get(i).map(String::as_str).unwrap_or("");
            put(buf, x + 2, y, &right(cell, *cw), *cw as u16, if r.strong == i { Style::new() } else { dim() });
            x += 2 + *cw as u16;
        }
    }
    rect.height
}

// MARK: - Process history

/// Columns the history table keeps first when the terminal is too narrow for all of them.
const PRIORITY: [&str; 14] = ["name", "cpu", "cpuPct", "ramAvg", "energy", "running", "ramPeak", "diskRead",
                              "diskWritten", "power", "launches", "copies", "life", "childCpu"];

/// Rows for the chart's columns in a terminal `h` rows high; None when the table needs them all.
fn chart_rows(h: u16, once: bool) -> Option<u16> {
    match h {
        _ if once => Some(8),
        44.. => Some(10),
        32.. => Some(8),
        26.. => Some(6),
        _ => None,
    }
}

/// The chart in a box at the top of `area` (its height is not used): the title and the measures
/// in the border; inside, the scale and the columns, their times, and two lines for what the
/// colors are or, with the column cursor, that column's numbers. Returns the rows used.
fn history_chart(app: &mut App, c: &HistoryChart, area: Rect, rows: u16, buf: &mut Buffer, once: bool) -> u16 {
    let box_h = rows + 5;
    let measures: Vec<Span> = c.metrics.iter().enumerate()
        .filter(|(i, _)| !once || *i == c.metric)
        .map(|(i, m)| Span::styled(format!(" {m} "), if i == c.metric && !once { selected() } else { dim() }))
        .collect();
    let measures_w: usize = measures.iter().map(|s| width(&s.content)).sum();
    let title = fit(&c.title, (area.width as usize).saturating_sub(measures_w + 6));
    let inner = boxed(buf, Rect::new(area.x, area.y, area.width, box_h),
                      Line::from(Span::styled(format!(" {title} "), bold())), Some(Line::from(measures)), None);
    let n = c.labels.len();
    if c.message.is_some() || n == 0 || c.segments.is_empty() {
        let msg = c.message.as_deref().unwrap_or("Nothing to draw.");
        let x = inner.x + inner.width.saturating_sub(width(msg) as u16) / 2;
        put(buf, x, inner.y + rows / 2, msg, inner.width, dim());
        return box_h;
    }

    // The scale at the left: its top, its middle and 0.
    let gutter = c.scale.iter().map(|s| width(s)).max().unwrap_or(1).max(1) as u16 + 1;
    for (label, row) in [(c.scale.first().map(String::as_str).unwrap_or(""), 0), (c.scale.get(1).map(String::as_str).unwrap_or(""), rows / 2),
                         ("0", rows - 1)] {
        put(buf, inner.x, inner.y + row, &right(label, gutter as usize - 1), gutter, dim());
    }
    let plot = Rect::new(inner.x + gutter, inner.y, inner.width.saturating_sub(gutter), rows);
    let lay = stack::layout(n, plot.width);
    stack::draw(buf, plot, c, &lay);
    app.chart_cols = lay.cols.max(1);
    // The column the cursor is on: counted back from the newest, which is at the right.
    let cursor = app.cursor.filter(|_| !once && lay.cols > 0).map(|back| lay.cols - 1 - back.min(lay.cols - 1));

    // Times under the columns: the cursor's, then from the newest back each one that has room.
    let ly = plot.bottom();
    let mut taken: Vec<(u16, u16)> = vec![];
    let mut place = |buf: &mut Buffer, k: usize, st: Style| {
        let Some(label) = c.labels.get(lay.first + k) else { return };
        let lw = width(label) as u16;
        if lw > plot.width {
            return;
        }
        let x = (plot.x + k as u16 * lay.step).min(plot.right() - lw);
        if taken.iter().any(|&(a, b)| x < b + 2 && a < x + lw + 2) {
            return;
        }
        put(buf, x, ly, label, lw, st);
        taken.push((x, x + lw));
    };
    if let Some(k) = cursor {
        place(buf, k, selected());
    }
    for k in (0..lay.cols).rev() {
        place(buf, k, dim());
    }

    // What the colors are; with the cursor, that column from the top down.
    let mut items: Vec<(Option<Rgb>, String, Style)> = vec![];
    if let Some(i) = cursor.map(|k| lay.first + k) {
        let cell = |cells: &[String]| cells.get(i).cloned().unwrap_or_default();
        items.push((None, cell(&c.times), bold()));
        for s in c.segments.iter().rev().filter(|s| cell(&s.cells) != "–" || c.segments.len() == 1) {
            items.push((Some(style::hex(&s.color)), format!("{} {}", s.name, cell(&s.cells)), Style::new()));
        }
        if let Some(l) = &c.line {
            items.push((None, format!("{} {}", l.name, cell(&l.cells)), Style::new()));
        }
        if c.segments.len() > 1 {
            items.push((None, format!("Total {}", cell(&c.totals)), Style::new()));
        }
        if !cell(&c.notes).is_empty() {
            items.push((None, cell(&c.notes), dim()));
        }
    } else {
        items.extend(c.segments.iter().map(|s| (Some(style::hex(&s.color)), s.name.clone(), dim())));
        if let Some(l) = &c.line {
            items.push((None, format!("{}: with [ ]", l.name), dim()));
        }
    }
    let (left, end) = (inner.x + 1, inner.right());
    let (mut x, mut row) = (left, 0);
    for (color, text, st) in items {
        let iw = width(&text) as u16 + if color.is_some() { 2 } else { 0 };
        if x > left && x + iw > end {
            (x, row) = (left, row + 1);
        }
        if row > 1 {
            break;
        }
        let y = ly + 1 + row;
        if let Some(rgb) = color {
            x = put(buf, x, y, "■ ", end - x, fg(rgb));
        }
        x = put(buf, x, y, &text, end.saturating_sub(x), st) + 3;
    }
    box_h
}

fn history(app: &mut App, area: Rect, buf: &mut Buffer, once: bool) -> u16 {
    let Some(d) = app.history.take() else { return 0 };
    let used = history_table(app, &d, area, buf, once);
    app.history = Some(d);
    used
}

fn history_table(app: &mut App, d: &History, area: Rect, buf: &mut Buffer, once: bool) -> u16 {
    let w = area.width;
    let end = area.right();

    // "Process history", or "History" when the tabs wouldn't fit after it.
    let tabs_w: usize = d.ranges.iter().map(|r| width(r) + 2).sum::<usize>() + 2 + 21;
    let title = if once || width("Process history") + 2 + tabs_w <= w as usize { "Process history" } else { "History" };
    let mut x = put(buf, area.x, area.y, title, w, bold());
    if once {
        let r = d.ranges.get(d.range).cloned().unwrap_or_default();
        let g = if d.by_executable { "executables" } else { "apps" };
        put(buf, x, area.y, &format!(" · {r} · by {g}"), end - x, dim());
    } else {
        x = tabs(buf, x + 2, area.y, &d.ranges, d.range, end);
        tabs(buf, x + 2, area.y, &["Apps".into(), "Executables".into()], d.by_executable as usize, end);
    }
    let mut y = messages(app, None, area, buf, area.y + 1);
    if app.filtering || !app.filter.is_empty() {
        let f = format!("Filter: {}{}", app.filter, if app.filtering { "▏" } else { "" });
        put(buf, area.x, y, &f, w, if app.filtering { bold() } else { dim() });
        y += 1;
    }
    if !d.tracking {
        put(buf, area.x, y + 1, "Process history is off. Turn it on in MacMon Indicator's Settings.", w, Style::new());
        return y + 2 - area.y;
    }
    if let (Some(c), Some(rows)) = (d.chart.as_ref(), chart_rows(area.height, once)) {
        y += history_chart(app, c, Rect::new(area.x, y, w, 0), rows, buf, once);
    }

    // Under the box: the selected row's path, the window's notes, the keys.
    let mut footer: Vec<(String, Style)> = vec![];
    if !once {
        if let Some(r) = d.rows.get(app.selected) {
            footer.push((fit(&r.path, w as usize), dim()));
        }
    }
    for f in &d.footer {
        footer.extend(wrap(f, w as usize).into_iter().map(|l| (l, dim())));
    }
    if !once {
        let keys = longest_fitting(&[
            "1–5 ←→ range  e apps/executables  s sort  r reverse  / filter  ⏎ chart the row  c measure  w with the rest  [ ] column  v chart  h live  q quit",
            "1–5 range  e apps/exe  s r sort  / filter  ⏎ chart row  c measure  w rest  [ ] column  v chart  h live  q quit",
            "1–5 range  e group  s r sort  / filter  ⏎ c w [ ] v chart  h live  q quit",
            "1–5 range  e s r /  ⏎ c w [ ] v chart  h  q",
        ], w);
        footer.push((keys.to_string(), dim()));
    }

    // The box: borders and the column titles around `page` rows.
    let page = if once { d.rows.len().clamp(1, 30) } else {
        (area.bottom().saturating_sub(y + 3 + footer.len() as u16)) as usize
    };
    let box_h = 3 + page as u16;
    if !once {
        app.selected = app.selected.min(d.rows.len().saturating_sub(1));
        if app.selected < app.scroll {
            app.scroll = app.selected;
        } else if app.selected >= app.scroll + page.max(1) {
            app.scroll = app.selected + 1 - page.max(1);
        }
    }
    let scroll = if once { 0 } else { app.scroll.min(d.rows.len().saturating_sub(1)) };
    let group = if d.by_executable { " Executables " } else { " Apps " };
    let count = (d.total > d.rows.len()).then(|| Line::from(Span::styled(format!(" {} of {} ", d.rows.len(), d.total), dim())));
    let inner = boxed(buf, Rect::new(area.x, y, w, box_h), Line::from(Span::styled(group, bold())), count, None);

    // Columns: as wide as their widest visible cell; the name takes what is left.
    let cols = &d.columns;
    let visible = d.rows.iter().skip(scroll).take(page);
    let mut widths: Vec<usize> = cols.iter().enumerate().map(|(i, c)| {
        let t = width(&c.title) + if c.id == d.sort_by { 2 } else { 0 };
        visible.clone().filter_map(|r| r.cells.get(i)).map(|s| width(s)).max().unwrap_or(0).max(t)
    }).collect();
    let mut shown: Vec<usize> = (0..cols.len()).collect();
    let name_i = cols.iter().position(|c| c.id == "name");
    let iw = inner.width as usize;
    let name_w = |shown: &[usize], widths: &[usize]| {
        iw.saturating_sub(shown.iter().filter(|&&i| Some(i) != name_i).map(|&i| widths[i] + 2).sum::<usize>())
    };
    while name_w(&shown, &widths) < 18 && shown.len() > 1 {
        // Drop the column that matters least.
        let least = shown.iter().copied().filter(|&i| Some(i) != name_i)
            .max_by_key(|&i| PRIORITY.iter().position(|p| *p == cols[i].id).unwrap_or(99));
        let Some(least) = least else { break };
        shown.retain(|&i| i != least);
    }
    if let Some(n) = name_i {
        widths[n] = name_w(&shown, &widths);
    }

    let row_line = |buf: &mut Buffer, y: u16, cells: &[(String, Style)]| {
        let mut x = inner.x;
        for (k, &i) in shown.iter().enumerate() {
            let cw = widths[i];
            let (text, st) = &cells[i];
            let s = if Some(i) == name_i { fit(text, cw) } else { right(text, cw) };
            if k > 0 {
                x += 2;
            }
            put(buf, x, y, &s, cw as u16, *st);
            x += cw as u16;
        }
    };
    let titles: Vec<(String, Style)> = cols.iter().map(|c| {
        if c.id == d.sort_by {
            (format!("{} {}", c.title, if d.ascending { "▴" } else { "▾" }), selected())
        } else {
            (c.title.clone(), dim())
        }
    }).collect();
    row_line(buf, inner.y, &titles);
    for (k, r) in d.rows.iter().skip(scroll).take(page).enumerate() {
        let ry = inner.y + 1 + k as u16;
        let sel = !once && scroll + k == app.selected;
        let cells: Vec<(String, Style)> = (0..cols.len()).map(|i| {
            let unknown = r.unknown.get(i).copied().unwrap_or(false);
            let st = if unknown { dim() } else { Style::new() };
            let mut text = r.cells.get(i).cloned().unwrap_or_default();
            // The program the chart is of.
            if Some(i) == name_i && app.pinned.as_deref() == Some(r.path.as_str()) {
                text = format!("▸ {text}");
            }
            (text, if sel { st.add_modifier(Modifier::REVERSED) } else { st })
        }).collect();
        if sel {
            buf.set_style(Rect::new(inner.x, ry, inner.width, 1), Style::new().add_modifier(Modifier::REVERSED));
        }
        row_line(buf, ry, &cells);
    }
    if d.rows.is_empty() {
        let msg = if app.filter.is_empty() { "Nothing recorded yet." } else { "Nothing matches the filter." };
        put(buf, inner.x, inner.y + 1, msg, inner.width, dim());
    }
    app.page = page;

    let fy = if once { y + box_h } else { area.bottom() - footer.len() as u16 };
    for (i, (l, st)) in footer.iter().enumerate() {
        put(buf, area.x, fy + i as u16, l, w, *st);
    }
    if once { fy + footer.len() as u16 - area.y } else { area.height }
}
