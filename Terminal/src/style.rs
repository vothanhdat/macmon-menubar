//! Colors, text width and plain/ANSI output of a rendered buffer.

use std::sync::OnceLock;

use ratatui::buffer::Buffer;
use ratatui::style::{Color, Modifier, Style};
use unicode_width::UnicodeWidthStr;

#[derive(Clone, Copy, PartialEq)]
pub enum ColorMode {
    /// 24-bit colors (COLORTERM=truecolor, or a terminal known to have them).
    True,
    /// The 256-color palette: works everywhere, also over SSH, where COLORTERM rarely arrives.
    Indexed,
    /// NO_COLOR, or output that isn't a terminal: no colors, only bold/dim/reverse.
    None,
}

static MODE: OnceLock<ColorMode> = OnceLock::new();

pub fn set_mode(m: ColorMode) {
    let _ = MODE.set(m);
}

pub fn mode() -> ColorMode {
    *MODE.get().unwrap_or(&ColorMode::Indexed)
}

/// What the terminal can show, from the environment.
pub fn detect(tty: bool) -> ColorMode {
    let var = |k: &str| std::env::var(k).unwrap_or_default();
    if !tty || std::env::var_os("NO_COLOR").is_some_and(|v| !v.is_empty()) || var("TERM") == "dumb" {
        return ColorMode::None;
    }
    let ct = var("COLORTERM").to_ascii_lowercase();
    let tp = var("TERM_PROGRAM");
    if ct.contains("truecolor") || ct.contains("24bit")
        || ["iTerm.app", "WezTerm", "ghostty", "vscode", "WarpTerminal"].contains(&tp.as_str())
    {
        ColorMode::True
    } else {
        ColorMode::Indexed
    }
}

pub type Rgb = (u8, u8, u8);

/// The menu's chart colors (macOS system colors, dark appearance).
pub fn named(name: &str) -> Rgb {
    match name {
        "indigo" => (94, 92, 230),
        "green" => (48, 209, 88),
        "orange" => (255, 159, 10),
        "blue" => (10, 132, 255),
        "pink" => (255, 55, 95),
        "red" => RED,
        _ => (142, 142, 147), // gray
    }
}

pub const RED: Rgb = (255, 69, 58);

/// A color for the terminal at hand.
pub fn color(c: Rgb) -> Color {
    match mode() {
        ColorMode::True => Color::Rgb(c.0, c.1, c.2),
        ColorMode::Indexed => Color::Indexed(to_256(c)),
        ColorMode::None => Color::Reset,
    }
}

/// `a` blended toward `b` by `t` (0…1).
pub fn mix(a: Rgb, b: Rgb, t: f32) -> Rgb {
    let t = t.clamp(0.0, 1.0);
    let m = |x: u8, y: u8| (x as f32 + (y as f32 - x as f32) * t).round() as u8;
    (m(a.0, b.0), m(a.1, b.1), m(a.2, b.2))
}

/// The bucket peaks behind the averages: the chart's color, muted.
pub fn faint(c: Rgb) -> Rgb {
    mix(c, (72, 72, 72), 0.5)
}

/// Nearest color in the xterm 256-color palette (its 6×6×6 cube or its gray ramp). Pink (disk
/// writes) would round to the same entry as warning red, so it gets a pinker one.
fn to_256(c: Rgb) -> u8 {
    let pink = named("pink");
    if c == pink {
        return 204; // #ff5f87
    }
    if c == faint(pink) {
        return 132; // #af5f87
    }
    const LV: [i32; 6] = [0, 95, 135, 175, 215, 255];
    let near = |v: u8| (0..6).min_by_key(|&i| (LV[i] - v as i32).abs()).unwrap_or(0);
    let d = |a: (i32, i32, i32)| {
        let (r, g, b) = (a.0 - c.0 as i32, a.1 - c.1 as i32, a.2 - c.2 as i32);
        r * r + g * g + b * b
    };
    let (ri, gi, bi) = (near(c.0), near(c.1), near(c.2));
    let cube = d((LV[ri], LV[gi], LV[bi]));
    let avg = (c.0 as i32 + c.1 as i32 + c.2 as i32) / 3;
    let g = ((avg - 8).max(0) / 10).min(23);
    let gv = 8 + 10 * g;
    if d((gv, gv, gv)) < cube {
        (232 + g) as u8
    } else {
        (16 + 36 * ri + 6 * gi + bi) as u8
    }
}

pub fn dim() -> Style {
    Style::new().add_modifier(Modifier::DIM)
}

pub fn bold() -> Style {
    Style::new().add_modifier(Modifier::BOLD)
}

pub fn fg(c: Rgb) -> Style {
    match mode() {
        ColorMode::None => Style::new(),
        _ => Style::new().fg(color(c)),
    }
}

/// Selected tab or sorted column.
pub fn selected() -> Style {
    Style::new().add_modifier(Modifier::REVERSED | Modifier::BOLD)
}

pub fn width(s: &str) -> usize {
    UnicodeWidthStr::width(s)
}

/// `s` cut to `w` columns, ending in "…" when cut.
pub fn fit(s: &str, w: usize) -> String {
    if width(s) <= w {
        return s.to_string();
    }
    if w == 0 {
        return String::new();
    }
    let mut out = String::new();
    let mut used = 0;
    for ch in s.chars() {
        let cw = unicode_width::UnicodeWidthChar::width(ch).unwrap_or(0);
        if used + cw > w - 1 {
            break;
        }
        out.push(ch);
        used += cw;
    }
    out.push('…');
    out
}

/// `s` right-aligned in `w` columns.
pub fn right(s: &str, w: usize) -> String {
    let s = fit(s, w);
    format!("{}{}", " ".repeat(w.saturating_sub(width(&s))), s)
}

/// Words of `text` in lines of at most `w` columns.
pub fn wrap(text: &str, w: usize) -> Vec<String> {
    let mut lines = vec![];
    let mut line = String::new();
    for word in text.split_whitespace() {
        if !line.is_empty() && width(&line) + 1 + width(word) > w {
            lines.push(std::mem::take(&mut line));
        }
        if !line.is_empty() {
            line.push(' ');
        }
        line.push_str(word);
    }
    if !line.is_empty() {
        lines.push(line);
    }
    lines
}

/// The first `rows` of a rendered buffer as text for stdout: with escape codes for its styles, or plain.
pub fn dump(buf: &Buffer, rows: u16, styled: bool) -> String {
    let area = buf.area;
    let mut out = String::new();
    for y in area.top()..area.bottom().min(area.top() + rows) {
        let mut line = String::new();
        let mut last = Style::new();
        let mut skip = 0;
        for x in area.left()..area.right() {
            let Some(cell) = buf.cell((x, y)) else { continue };
            if skip > 0 {
                skip -= 1;
                continue;
            }
            let sym = cell.symbol();
            skip = width(sym).saturating_sub(1);
            if styled {
                let st = Style::new().fg(cell.fg).bg(cell.bg).add_modifier(cell.modifier);
                if st != last {
                    line.push_str(&sgr(&st));
                    last = st;
                }
            }
            line.push_str(sym);
        }
        if styled {
            line.push_str("\x1b[0m");
        } else {
            line.truncate(line.trim_end().len());
        }
        out.push_str(&line);
        out.push('\n');
    }
    out
}

fn sgr(st: &Style) -> String {
    let mut codes = vec!["0".to_string()];
    let m = st.add_modifier;
    for (flag, code) in [(Modifier::BOLD, "1"), (Modifier::DIM, "2"), (Modifier::ITALIC, "3"),
                         (Modifier::UNDERLINED, "4"), (Modifier::REVERSED, "7")] {
        if m.contains(flag) {
            codes.push(code.into());
        }
    }
    let col = |c: Option<Color>, base: u8| match c {
        Some(Color::Indexed(n)) => Some(format!("{};5;{n}", base)),
        Some(Color::Rgb(r, g, b)) => Some(format!("{};2;{r};{g};{b}", base)),
        _ => None,
    };
    codes.extend(col(st.fg, 38));
    codes.extend(col(st.bg, 48));
    format!("\x1b[{}m", codes.join(";"))
}
