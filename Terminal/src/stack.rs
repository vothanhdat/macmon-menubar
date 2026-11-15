//! The process history chart: a column per hour or day, each a stack of colored segments, in
//! block characters. A cell is eight steps high: where two segments meet inside a cell, the lower
//! one is the block (foreground) and the upper one the background, so the boundary is exact. A
//! third segment in the same cell isn't seen.

use ratatui::buffer::Buffer;
use ratatui::layout::Rect;
use ratatui::style::Style;

use crate::proto::HistoryChart;
use crate::style::{self, ColorMode};

const BLOCKS: [char; 9] = [' ', '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'];

/// Which columns fit: the newest `cols` (from `first`), each `step` cells wide with a `bar` of them filled.
#[derive(Clone, Copy, PartialEq, Debug)]
pub struct Layout {
    pub first: usize,
    pub cols: usize,
    pub step: u16,
    pub bar: u16,
}

/// Columns as wide as fit (up to three cells and a gap); when even one cell each is too many,
/// the oldest are left out.
pub fn layout(n: usize, width: u16) -> Layout {
    let w = width as usize;
    let (step, bar) = if n * 4 <= w { (4, 3) } else if n * 3 <= w { (3, 2) } else if n * 2 <= w { (2, 1) } else { (1, 1) };
    let cols = n.min(w / step as usize);
    Layout { first: n - cols, cols, step, bar }
}

/// One column's cells, bottom to top: the block character, the segment it is of, and the segment
/// above it in the same cell (its background). None: nothing reaches this cell.
pub fn column(values: &[f64], top: f64, rows: usize) -> Vec<Option<(char, usize, Option<usize>)>> {
    let steps = rows * 8;
    let mut sum = 0.0;
    // Where each segment ends, in steps from the bottom.
    let mut ends: Vec<usize> = values.iter().map(|v| {
        sum += v.max(0.0);
        if top > 0.0 { ((sum / top).min(1.0) * steps as f64).round() as usize } else { 0 }
    }).collect();
    // Anything at all shows as one step, of its biggest segment.
    if top > 0.0 && sum > 0.0 && ends.last() == Some(&0) {
        let big = (0..values.len()).max_by(|&a, &b| values[a].total_cmp(&values[b])).unwrap_or(0);
        for e in &mut ends[big..] {
            *e = 1;
        }
    }
    (0..rows).map(|r| {
        let (lo, hi) = (r * 8, r * 8 + 8);
        let a = ends.iter().position(|&e| e > lo)?;
        if ends[a] >= hi {
            return Some(('█', a, None));
        }
        let above = (a + 1..ends.len()).find(|&j| ends[j] > ends[a]);
        Some((BLOCKS[ends[a] - lo], a, above))
    }).collect()
}

/// Draws the columns of `lay` into `area` (the plot: no scale, no labels).
pub fn draw(buf: &mut Buffer, area: Rect, c: &HistoryChart, lay: &Layout) {
    let rows = area.height as usize;
    if rows == 0 || lay.cols == 0 {
        return;
    }
    let mono = style::mode() == ColorMode::None;
    let colors: Vec<_> = c.segments.iter().map(|s| style::color(style::hex(&s.color))).collect();
    for k in 0..lay.cols {
        let i = lay.first + k;
        let mut values: Vec<f64> = c.segments.iter().map(|s| s.values.get(i).copied().unwrap_or(0.0)).collect();
        if mono {
            // Without colors the parts can't be told apart: the column's height only.
            values = vec![values.iter().sum()];
        }
        for (r, cell) in column(&values, c.top, rows).into_iter().enumerate() {
            let Some((ch, a, above)) = cell else { continue };
            let mut st = Style::new();
            if !mono {
                st = st.fg(colors[a]);
                if let Some(b) = above {
                    st = st.bg(colors[b]);
                }
            }
            let y = area.bottom() - 1 - r as u16;
            for dx in 0..lay.bar {
                let x = area.x + k as u16 * lay.step + dx;
                if let Some(cell) = buf.cell_mut((x, y)) {
                    cell.set_char(ch);
                    cell.set_style(st);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn columns_get_as_wide_as_fits() {
        assert_eq!(layout(24, 100), Layout { first: 0, cols: 24, step: 4, bar: 3 });
        assert_eq!(layout(24, 80), Layout { first: 0, cols: 24, step: 3, bar: 2 });
        assert_eq!(layout(30, 70), Layout { first: 0, cols: 30, step: 2, bar: 1 });
        assert_eq!(layout(90, 100), Layout { first: 0, cols: 90, step: 1, bar: 1 });
        // Too narrow for all of them: the newest.
        assert_eq!(layout(90, 60), Layout { first: 30, cols: 60, step: 1, bar: 1 });
        assert_eq!(layout(0, 60).cols, 0);
    }

    #[test]
    fn a_cell_is_eight_steps_and_two_segments() {
        // Two rows = 16 steps, the scale's top at 16: values are steps.
        let c = column(&[4.0, 6.0, 2.0], 16.0, 2);
        // Bottom cell: the first segment's 4 steps, the second above it.
        assert_eq!(c[0], Some(('▄', 0, Some(1))));
        // Top cell: the second ends 2 steps in, the third above it (and ends inside the cell too).
        assert_eq!(c[1], Some(('▂', 1, Some(2))));
        // A full cell, and nothing above the column.
        assert_eq!(column(&[8.0], 16.0, 2), [Some(('█', 0, None)), None]);
        assert_eq!(column(&[12.0], 16.0, 2), [Some(('█', 0, None)), Some(('▄', 0, None))]);
        // Segments of nothing are skipped over.
        assert_eq!(column(&[0.0, 4.0, 0.0, 4.0], 16.0, 1), [Some(('▂', 1, Some(3)))]);
        assert_eq!(column(&[0.0, 0.0], 16.0, 2), [None, None]);
    }

    #[test]
    fn something_small_still_shows() {
        // Less than half a step: one step, of the biggest segment.
        assert_eq!(column(&[0.01, 0.2, 0.05], 1000.0, 2), [Some(('▁', 1, None)), None]);
        // Above the scale's top (it never is): a full column.
        assert_eq!(column(&[50.0], 16.0, 2), [Some(('█', 0, None)), Some(('█', 0, None))]);
        // No scale: nothing.
        assert_eq!(column(&[5.0], 0.0, 1), [None]);
    }
}
