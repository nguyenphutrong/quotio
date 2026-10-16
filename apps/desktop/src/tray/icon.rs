//! Tray icon artwork. Windows and Linux trays show a small bitmap and no text, so the
//! icon is a ring gauge of the lowest remaining quota instead of the macOS "29% 11%" title.
use crate::model::{Tone, tone};

pub const SIZE: u32 = 32;

/// Returns straight (non-premultiplied) RGBA pixels, `SIZE` × `SIZE`.
pub fn gauge(remaining: Option<f32>) -> Vec<u8> {
    const TRACK: [u8; 4] = [163, 163, 163, 110];
    let fill = match remaining.map(|r| tone(r as f64 * 100.)) {
        Some(Tone::Good) => [29, 175, 97, 255],
        Some(Tone::Warning) => [246, 181, 30, 255],
        Some(Tone::Critical) => [251, 55, 72, 255],
        Some(Tone::Neutral) | None => TRACK,
    };
    let fraction = remaining.unwrap_or(0.).clamp(0., 1.);
    let center = SIZE as f32 / 2.;
    let (outer, inner) = (center - 1.5, center - 6.5);
    let mut pixels = vec![0u8; (SIZE * SIZE * 4) as usize];
    const SAMPLES: u32 = 4;
    for y in 0..SIZE {
        for x in 0..SIZE {
            // Supersample for anti-aliased edges.
            let (mut track, mut filled) = (0u32, 0u32);
            for sy in 0..SAMPLES {
                for sx in 0..SAMPLES {
                    let px = x as f32 + (sx as f32 + 0.5) / SAMPLES as f32 - center;
                    let py = y as f32 + (sy as f32 + 0.5) / SAMPLES as f32 - center;
                    let distance = (px * px + py * py).sqrt();
                    if distance > outer || distance < inner {
                        continue;
                    }
                    // Clockwise from 12 o'clock, in 0.0..1.0.
                    let turn = (px.atan2(-py) / std::f32::consts::TAU).rem_euclid(1.);
                    if turn < fraction {
                        filled += 1;
                    } else {
                        track += 1;
                    }
                }
            }
            let total = (SAMPLES * SAMPLES) as f32;
            let (f, t) = (filled as f32 / total, track as f32 / total);
            let alpha = f * fill[3] as f32 + t * TRACK[3] as f32;
            if alpha <= 0. {
                continue;
            }
            let i = ((y * SIZE + x) * 4) as usize;
            for c in 0..3 {
                pixels[i + c] = ((f * fill[3] as f32 * fill[c] as f32
                    + t * TRACK[3] as f32 * TRACK[c] as f32)
                    / alpha) as u8;
            }
            pixels[i + 3] = alpha.min(255.) as u8;
        }
    }
    pixels
}
