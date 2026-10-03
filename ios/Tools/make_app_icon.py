#!/usr/bin/env python3
"""Render the iOS app icon from breathe.py's own look.

The orb near the top of an inhale, its halo and the target ring, on the cream
the pacer falls back to without a compositor. Colours and geometry are read
from breathe.py, so the icon follows the pacer if its look changes. The image
is 1024 x 1024 and opaque (App Store icons may not carry alpha), drawn at 2x
and downsampled.

    python3 ios/Tools/make_app_icon.py      # rewrites AppIcon.png in place

Needs numpy and Pillow (requirements.txt).
"""

import math
import pathlib
import sys

import numpy as np
from PIL import Image

ROOT = pathlib.Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))
import breathe  # noqa: E402  - the pacer's constants are the source of truth

SIZE = 1024
SUPERSAMPLE = 2
FULLNESS = 0.8          # near the top of the inhale: big, warm, haloed
DRIFT = 4.0             # the moment the halo lobes are caught at
RING_EXTENT = 0.39      # ring's outer edge, as a fraction of the icon width
OUT = ROOT / "ios/Breathe/Assets.xcassets/AppIcon.appiconset/AppIcon.png"


def render():
    n = SIZE * SUPERSAMPLE
    scale = n * RING_EXTENT / (breathe.R_MAX + breathe.RING_W)
    cx = cy = n / 2.0
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float64) + 0.5
    image = np.empty((n, n, 3))
    image[:] = breathe.CREAM

    def over(colour, alpha):
        a = alpha[..., None]
        image[:] = image * (1.0 - a) + np.asarray(colour, dtype=np.float64) * a

    distance = np.hypot(xx - cx, yy - cy)

    # The target ring, its inner edge where the orb peaks.
    inner = breathe.R_MAX * scale
    outer = (breathe.R_MAX + breathe.RING_W) * scale
    ring = np.clip(np.minimum(distance - inner, outer - distance) + 0.5, 0.0, 1.0)
    over(breathe.TARGET_RING, ring * 199 / 255)

    # The halo: breathe.py's four lobes, same formula as Glass._halo_layer.
    r = breathe.orb_radius(FULLNESS)
    intensity = FULLNESS ** 2.6
    e = DRIFT
    for tint, span, orbit, orbit_rate, phase, size_rate, alpha_rate, weight in breathe.HALO_LOBES:
        diameter = max(2.0, r * 2 * breathe.GLOW_SPAN * span * (1 + 0.22 * math.sin(size_rate * e + phase)))
        peak = 118 * intensity * weight * (0.66 + 0.34 * math.sin(alpha_rate * e + phase * 1.7)) / 255
        offset = r * orbit * (1 + 0.20 * math.sin(size_rate * 0.7 * e + phase * 1.4))
        angle = phase + orbit_rate * e
        lx = cx + math.cos(angle) * offset * scale
        ly = cy + math.sin(angle) * offset * scale
        radius = diameter / 2 * scale
        core = radius / breathe.GLOW_SPAN
        d = np.hypot(xx - lx, yy - ly)
        tail = np.clip(1 - (d - core) / (radius - core), 0.0, 1.0) ** 2.3
        over(tint, peak * np.where(d <= core, 1.0, tail))

    colour = breathe.lerp3(breathe.ORB_REST, breathe.ORB_FULL, min(1.0, FULLNESS ** 1.15))
    over(colour, np.clip(r * scale - distance + 0.5, 0.0, 1.0))

    pixels = np.clip(image + 0.5, 0, 255).astype(np.uint8)
    return Image.fromarray(pixels, "RGB").resize((SIZE, SIZE), Image.LANCZOS)


if __name__ == "__main__":
    render().save(OUT, optimize=True)
    print(f"wrote {OUT.relative_to(ROOT)}")
