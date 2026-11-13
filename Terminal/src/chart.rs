//! Bar charts in braille dots, as btop draws its graphs: two buckets per cell (one per dot
//! column), four dots high per row. As in the menu, each bucket's average is a bar in the
//! chart's color and its peak shows as muted dots above it. Mirrored charts (disk) show the second series
//! downward from the middle; signed charts (battery) show charging up and discharging down.

use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::{Modifier, Style};

use crate::proto::Chart;
use crate::style::{self, ColorMode, Rgb};

#[derive(Clone, Copy, PartialEq)]
enum Dir {
    Up,
    Down,
}

/// Rows a chart needs at a given chart height: two halves need an even number.
pub fn rows_for(c: &Chart, h: u16) -> u16 {
    if c.shape == "up" {
        h
    } else {
        (h + h % 2).max(2)
    }
}

pub fn draw(buf: &mut Buffer, area: Rect, c: &Chart) {
    if area.width == 0 || area.height == 0 {
        return;
    }
    let color = style::named(&c.color);
    match c.shape.as_str() {
        "mirrored" => {
            let (top, bottom) = halves(area);
            bars(buf, top, &c.avg, &c.max, c.lo, c.hi, color, Dir::Up, None);
            let none = vec![];
            bars(buf, bottom, c.avg2.as_ref().unwrap_or(&none), c.max2.as_ref().unwrap_or(&none),
                 c.lo2.unwrap_or(0.0), c.hi2.unwrap_or(c.hi), style::named(c.color2.as_deref().unwrap_or(&c.color)),
                 Dir::Down, None);
        }
        "signed" => {
            let (top, bottom) = halves(area);
            let up: Vec<Option<f32>> = c.avg.iter().map(|v| v.map(|x| x.max(0.0))).collect();
            let down: Vec<Option<f32>> = c.avg.iter().map(|v| v.map(|x| (-x).max(0.0))).collect();
            bars(buf, top, &up, &[], 0.0, c.hi, color, Dir::Up, None);
            bars(buf, bottom, &down, &[], 0.0, c.hi, color, Dir::Down, None);
        }
        _ => {
            let warn = c.warn_start.zip(c.limit);
            bars(buf, area, &c.avg, &c.max, c.lo, c.hi, color, Dir::Up, warn);
        }
    }
}

fn halves(area: Rect) -> (Rect, Rect) {
    let top_h = area.height.div_ceil(2);
    (Rect { height: top_h, ..area }, Rect { y: area.y + top_h, height: area.height - top_h, ..area })
}

/// The color for a value: the chart's color, blending into red from `warn.0` to `warn.1`.
fn tint(base: Rgb, v: f32, warn: Option<(f32, f32)>) -> Rgb {
    match warn {
        Some((_, limit)) if v >= limit => style::RED,
        Some((start, limit)) if v > start && limit > start => style::mix(base, style::RED, (v - start) / (limit - start)),
        _ => base,
    }
}

/// The braille character with `l` dots in its left column and `r` in its right (0…4 each),
/// counted from the bottom (Up) or from the top (Down).
fn dots(dir: Dir, l: usize, r: usize) -> char {
    // Dot bits by column, top to bottom: left 1 2 3 7, right 4 5 6 8.
    const LEFT: [u32; 4] = [0x01, 0x02, 0x04, 0x40];
    const RIGHT: [u32; 4] = [0x08, 0x10, 0x20, 0x80];
    let pick = |col: &[u32; 4], n: usize| -> u32 {
        match dir {
            Dir::Up => col[4 - n..].iter().sum(),
            Dir::Down => col[..n].iter().sum(),
        }
    };
    char::from_u32(0x2800 + pick(&LEFT, l) + pick(&RIGHT, r)).unwrap_or(' ')
}

/// Bars as btop draws its graphs: each cell holds two buckets side by side (its two dot
/// columns), four dots high per row. With a warning range the color follows the height: rows
/// blend into red toward the limit and are red above it, so a spike's tip turns red.
#[allow(clippy::too_many_arguments)]
fn bars(buf: &mut Buffer, area: Rect, avg: &[Option<f32>], max: &[Option<f32>], lo: f32, hi: f32, base: Rgb, dir: Dir,
        warn: Option<(f32, f32)>) {
    let n = avg.len();
    if n == 0 || area.height == 0 || hi <= lo {
        return;
    }
    let rows = area.height as usize;
    let total = rows as f32 * 4.0;
    // Dots of the chart's height a value fills: at least one for anything above the bottom.
    let height = |v: Option<f32>| -> i32 {
        match v {
            Some(v) if v > lo => (((v - lo) / (hi - lo)).clamp(0.0, 1.0) * total).round().max(1.0) as i32,
            _ => 0,
        }
    };
    let mono = style::mode() == ColorMode::None;
    // Each row's colors (average, peak), from the value at its middle.
    let colors: Vec<(Rgb, Rgb)> = (0..rows).map(|r| {
        let rgb = tint(base, lo + (r as f32 + 0.5) / rows as f32 * (hi - lo), warn);
        (rgb, style::faint(rgb))
    }).collect();
    // A cell has one color: `share` is how much of it is average (1) rather than peak (0).
    let style_of = |r: usize, share: f32| -> Style {
        if mono {
            return if share >= 0.5 { Style::new() } else { Style::new().add_modifier(Modifier::DIM) };
        }
        let (bar, peak) = colors[r];
        Style::new().fg(style::color(if share >= 1.0 { bar } else if share <= 0.0 { peak } else { style::mix(peak, bar, share) }))
    };
    // Newest at the right edge; a short window is stretched over the width.
    let cols = area.width as usize * 2;
    let at = |s: usize| (s * n / cols).min(n - 1);
    for x in 0..area.width as usize {
        let (i, j) = (at(2 * x), at(2 * x + 1));
        let (al, ar) = (height(avg[i]), height(avg[j]));
        let peak = |k: usize| max.get(k).copied().flatten();
        let (ml, mr) = (height(peak(i)).max(al), height(peak(j)).max(ar));
        for r in 0..rows {
            let fill = |h: i32| (h - 4 * r as i32).clamp(0, 4) as usize;
            let (fl, fr, pl, pr) = (fill(al), fill(ar), fill(ml), fill(mr));
            if fl + fr + pl + pr == 0 {
                continue;
            }
            let y = match dir {
                Dir::Up => area.bottom() - 1 - r as u16,
                Dir::Down => area.top() + r as u16,
            };
            let Some(cell) = buf.cell_mut((area.x + x as u16, y)) else { continue };
            // All the dots, average and peak (which starts where the average ends), so columns
            // have no holes. Where an average ends inside a cell below its peak, the cell's one
            // color is between the two, by how many of its dots are average.
            cell.set_char(dots(dir, pl, pr));
            cell.set_style(style_of(r, (fl + fr) as f32 / (pl + pr) as f32));
        }
    }
}
