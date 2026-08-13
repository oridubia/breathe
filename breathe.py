#!/usr/bin/env python3
"""
breathe.py - a soft-tick breathing pacer, terminal or floating glass window

Plays a soft tick at the start of each inhale and each exhale and shows the
breath as a single expanding disc with a drifting halo, on a transparent
window. The only text is a count that rises inside each phase (1,2,3,4 in;
1,2,3,4,5,6 out) in a small white tab. Default pattern is 4s in, 6s out, with
a still half-second at each turnaround.

    python3 breathe.py --gui                 # floating always-on-top window
    python3 breathe.py                       # terminal bar
    python3 breathe.py --gui --inhale 5.5 --exhale 5.5
    python3 breathe.py --interval 6          # plain metronome, tick every 6s
    python3 breathe.py --test                # check audio actually works
    python3 breathe.py --minutes 10          # stop after 10 min (default: forever)

deps:  pip install numpy sounddevice pillow
GUI keys:  drag to move · space pause · esc quit

ARCHITECTURE INVARIANTS - do not break these:

1. ONE CLOCK. phase_at(elapsed, inhale, exhale, hold) -> (cycle, phase,
   progress, seconds_left). Audio and visuals both call it on the same
   time.monotonic() value each frame. Ticks fire when (cycle, phase) changes.
   Never add a second timing source (no next_tick += inhale accumulators):
   that drifts permanently after a stall and fires catch-up bursts.

2. AUDIO. Ticks are synthesised with numpy (fundamental + two quiet partials,
   short noise transient, exponential decay, one-pole lowpass, fade in/out).
   Playback is one persistent sounddevice.OutputStream with a mixing callback
   - reopening the device per tick adds jitter. Fallback chain: stream ->
   system player -> terminal bell.

3. PILLOW. ImageDraw with a translucent fill or outline REPLACES pixels, it
   does not blend. Every translucent layer gets its own RGBA image and is
   merged with alpha_composite. Image.paste(colour, box, mask) does blend
   correctly, which is what the per-frame orb and halo use.

4. RENDER BUDGET. Static parts (target ring, white tab) render once at 3x and
   downscale with LANCZOS. Each frame only resizes cached alpha sprites
   (core + halo) and pastes them, so a frame is a few ms.

5. WINDOWS TRANSPARENCY is WS_EX_LAYERED + UpdateLayeredWindow with
   premultiplied BGRA. Do not go back to -transparentcolor: a chroma key is
   binary, so the soft halo would blend into the key colour and go muddy.

6. EASING is visual only. Ticks and the count stay exactly on the clock.
"""

import argparse
import math
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import wave

try:
    import numpy as np
except ImportError:
    sys.exit("need numpy:  pip install numpy")

SR = 44100


# ============================================================ APPEARANCE

CREAM       = (244, 239, 228)          # only the no-compositor fallback bg
TARGET_RING = (196, 178, 156)          # where full inhale lands
ORB_REST    = (198, 122, 100)          # muted terracotta, empty lungs
ORB_FULL    = (220, 62, 34)            # cinnabar at full saturation
# tint, span, orbit radius, orbit rate, phase, size rate, alpha rate, weight
HALO_LOBES  = (((228, 80, 46), 0.72, 0.30, 0.23, 0.0, 0.31, 0.19, 1.00),
               ((216, 58, 32), 0.86, 0.24, -0.17, 2.1, 0.24, 0.27, 0.78),
               ((235, 104, 58), 0.62, 0.40, 0.13, 4.2, 0.37, 0.22, 0.88),
               ((222, 70, 40), 0.95, 0.18, -0.29, 5.5, 0.19, 0.33, 0.58))
TAB         = (255, 255, 255)          # the little disc under the orb
TAB_INK     = (110, 88, 78)

WIN_W, WIN_H = 280, 250                # transparent window
ORB_C        = (140, 118)              # orb centre
R_MIN, R_MAX = 16.0, 56.0              # orb radius, px
RING_W       = 3                       # wall the orb arrives at, px
GLOW_SPAN    = 1.9                     # halo diameter / orb diameter
TAB_C        = (140, 202)              # count tab centre
TAB_D        = 34
SS           = 3                       # supersample for the static layers
CORE_TILE    = int(R_MAX * 2) + 4      # fixed tile the orb is drawn into
HALO_SCALE   = 2                       # the halo is soft; render it at 1/2
FPS          = 60

FONT_FILES = [r"C:\Windows\Fonts\segoeui.ttf",
              "/System/Library/Fonts/SFNS.ttf",
              "/System/Library/Fonts/Helvetica.ttc",
              "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"]
WIN_KEY = "#010203"                    # colour-key fallback only


# ============================================================ ONE CLOCK
# Audio and display both call this. There is no second source of truth,
# so they cannot drift apart no matter what stalls.

def phase_at(elapsed, inhale, exhale, hold=0.0):
    """Single source of truth for where we are in the breath.

    One cycle is in -> hold-in -> out -> hold-out. The holds are a still
    pause at each turnaround; ticks only fire on "in" and "out".

    -> (cycle_index, phase, progress 0..1, seconds_left_in_phase)
    """
    period = inhale + exhale + hold * 2.0
    cycle = int(elapsed // period)
    t = elapsed - cycle * period
    if t < inhale:
        return cycle, "in", t / inhale, inhale - t
    t -= inhale
    if t < hold:
        return cycle, "hold-in", (t / hold if hold else 1.0), hold - t
    t -= hold
    if t < exhale:
        return cycle, "out", t / exhale, exhale - t
    t -= exhale
    return cycle, "hold-out", (t / hold if hold else 1.0), hold - t


def ease(p):
    """Symmetric: slow at both turnarounds, quick through the middle.

    A little linear keeps it from ever looking frozen; smootherstep does the
    long, log-like arrival at each end.
    """
    p = min(1.0, max(0.0, p))
    smoothstep = p * p * (3.0 - 2.0 * p)
    smootherstep = p * p * p * (p * (p * 6.0 - 15.0) + 10.0)
    return 0.08 * p + 0.30 * smoothstep + 0.62 * smootherstep


def fullness_at(phase, progress):
    """0 = empty lungs, 1 = full. Visual only; the clock is untouched."""
    if phase == "in":
        return ease(progress)
    if phase == "out":
        return 1.0 - ease(progress)
    return 1.0 if phase == "hold-in" else 0.0


def orb_radius(fullness):
    """Interpolate AREA, not radius, so growth reads evenly to the eye."""
    a = R_MIN * R_MIN + (R_MAX * R_MAX - R_MIN * R_MIN) * fullness
    return math.sqrt(a)


def lerp3(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def phase_count(inhale, exhale, phase, left):
    """Seconds elapsed inside the phase, read like a stopwatch.

    Starts at 0 and turns over on each whole second, so the first second is
    the one you watch tick away rather than one you have already missed. A
    hold shows the phase length, which is the number the count was climbing
    toward: 0,1,2,3 through a 4s inhale, then 4 while it is held.
    """
    length = inhale if phase in ("in", "hold-in") else exhale
    top = int(math.ceil(length))
    if phase.startswith("hold"):
        return top
    return max(0, min(top, int(length - left)))


# ============================================================ SOUND

def make_tick(freq=660.0, dur=0.09, volume=0.25):
    """Soft woodblock-ish tick. Fast attack, exponential decay, no click."""
    n = int(SR * dur)
    t = np.arange(n) / SR

    body = (
        1.00 * np.sin(2 * math.pi * freq * t)
        + 0.30 * np.sin(2 * math.pi * freq * 2 * t)
        + 0.12 * np.sin(2 * math.pi * freq * 3 * t)
    )
    noise = np.random.default_rng(0).normal(0, 1, n) * np.exp(-t * 900) * 0.15

    env = np.exp(-t * 38.0)
    attack = np.minimum(t / 0.0025, 1.0)
    w = (body + noise) * env * attack

    # one-pole lowpass, vectorised via lfilter-style accumulation
    a = 0.32
    out = np.empty_like(w)
    acc = 0.0
    for i, s in enumerate(w):
        acc += a * (s - acc)
        out[i] = acc

    out *= volume / (np.max(np.abs(out)) + 1e-9)
    fade = int(SR * 0.005)
    out[-fade:] *= np.linspace(1, 0, fade)
    return out.astype(np.float32)


class Player:
    """Persistent output stream so a tick costs ~0ms instead of reopening
    the device every time. Falls back to a system player, then the bell."""

    def __init__(self, silent=False):
        self.mode = "bell"
        self.reason = ""
        self.tmp = {}
        self.voices = []
        self.lock = threading.Lock()
        if silent:
            self.mode = "silent"
            return
        try:
            import sounddevice as sd
            devs = sd.query_devices()
            if not any(d["max_output_channels"] > 0 for d in devs):
                raise RuntimeError("no output device exists")
            self.sd = sd
            self.stream = sd.OutputStream(
                samplerate=SR, channels=1, dtype="float32",
                blocksize=256, latency="low", callback=self._cb,
            )
            self.stream.start()
            self.mode = "sounddevice"
            return
        except ImportError:
            self.reason = "sounddevice not installed"
        except Exception as e:
            self.reason = f"sounddevice failed: {e}"

        for cmd in (["afplay"], ["paplay"], ["aplay", "-q"]):
            if shutil.which(cmd[0]):
                self.cmd = cmd
                self.mode = "system"
                if not self.reason:
                    self.reason = "using system player (higher latency)"
                return

    def _cb(self, outdata, frames, timeinfo, status):
        outdata.fill(0)
        with self.lock:
            still = []
            for samples, pos in self.voices:
                chunk = samples[pos:pos + frames]
                if len(chunk):
                    outdata[:len(chunk), 0] += chunk
                    if pos + frames < len(samples):
                        still.append((samples, pos + frames))
            self.voices = still

    def _wav(self, samples, key):
        if key in self.tmp:
            return self.tmp[key]
        path = os.path.join(tempfile.gettempdir(), f"breathe_{key}.wav")
        pcm = (np.clip(samples, -1, 1) * 32767).astype("<i2")
        with wave.open(path, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes(pcm.tobytes())
        self.tmp[key] = path
        return path

    def play(self, samples, key):
        if self.mode == "sounddevice":
            with self.lock:
                self.voices.append((samples, 0))
        elif self.mode == "system":
            subprocess.Popen(self.cmd + [self._wav(samples, key)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        elif self.mode == "bell":
            sys.stdout.write("\a")
            sys.stdout.flush()

    def close(self):
        if self.mode == "sounddevice":
            try:
                self.stream.stop()
                self.stream.close()
            except Exception:
                pass


# ============================================================ GLASS WINDOW


class Glass:
    """Borderless always-on-top pacer: an expanding disc with a drifting halo
    on a fully transparent background, plus one small white tab for the count.

    Windows gets true per-pixel alpha through UpdateLayeredWindow. A colour
    key cannot render a soft halo - every translucent pixel would blend
    toward the key colour and go muddy - so the layered path is the point,
    with the old key path kept only as a fallback. macOS uses -transparent;
    anything else falls back to a translucent window on a flat backdrop.
    """

    def __init__(self, inhale, exhale, hold, player, volume, total=None):
        from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont
        import tkinter as tk

        self.Image, self.ImageDraw = Image, ImageDraw
        self.ImageChops = ImageChops

        self.inhale, self.exhale, self.hold = inhale, exhale, hold
        self.player, self.total = player, total
        self.tick_in = make_tick(740.0, volume=volume)
        self.tick_out = make_tick(494.0, volume=volume * 0.85)
        self.last_key = None
        self.paused = False
        self.pause_at = 0.0
        self.offset = 0.0

        self.system = platform.system()
        self.canvas = None
        self.layered = False

        self.root = tk.Tk()
        self.root.title("breathe")
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        self.root.geometry("%dx%d+%d+%d" % (
            WIN_W, WIN_H,
            max(0, (self.root.winfo_screenwidth() - WIN_W) // 2),
            max(0, int(self.root.winfo_screenheight() * 0.58))))

        self._build_layers(Image, ImageDraw, ImageFilter)
        self._build_sprites(Image, ImageDraw)
        self.font = self._load_font(ImageFont)

        if self.system == "Windows":
            self.layered = self._init_layered()
        if not self.layered:
            self._init_canvas(tk)

        self.root.bind("<Button-1>", self._grab)
        self.root.bind("<B1-Motion>", self._drag)
        self.root.bind("<space>", lambda e: self._toggle())
        self.root.bind("<Escape>", self._quit)
        self.root.bind("q", self._quit)
        self.root.protocol("WM_DELETE_WINDOW", self._quit)
        self.root.focus_force()

        self.alive = True
        self.photo = None
        self.start = time.monotonic()
        self._due = self.start
        self._frame()

    # ---------------------------------------------------------- surfaces

    def _init_canvas(self, tk):
        from PIL import ImageTk
        self.ImageTk = ImageTk
        if self.system == "Darwin":
            self.root.wm_attributes("-transparent", True)
            bg = "systemTransparent"
        elif self.system == "Windows":
            self.root.wm_attributes("-transparentcolor", WIN_KEY)
            bg = WIN_KEY
        else:
            self.root.attributes("-alpha", 0.94)
            bg = "#%02x%02x%02x" % CREAM
        self.canvas = tk.Canvas(self.root, width=WIN_W, height=WIN_H,
                                highlightthickness=0, borderwidth=0, bg=bg)
        self.canvas.pack(fill="both", expand=True)
        self.canvas.bind("<Button-1>", self._grab)
        self.canvas.bind("<B1-Motion>", self._drag)
        self.image_id = self.canvas.create_image(0, 0, anchor="nw")

    def _init_layered(self):
        """WS_EX_LAYERED + UpdateLayeredWindow: per-pixel alpha on Windows."""
        try:
            import ctypes
            from ctypes import wintypes

            self.ctypes = ctypes
            u, g = ctypes.windll.user32, ctypes.windll.gdi32
            self.user32, self.gdi32 = u, g

            # argtypes matter: bare ints would truncate 64-bit handles.
            u.GetParent.restype = wintypes.HWND
            u.GetParent.argtypes = [wintypes.HWND]
            u.GetDC.restype = wintypes.HDC
            u.GetDC.argtypes = [wintypes.HWND]
            u.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
            g.CreateCompatibleDC.restype = wintypes.HDC
            g.CreateCompatibleDC.argtypes = [wintypes.HDC]
            g.CreateDIBSection.restype = wintypes.HBITMAP
            g.CreateDIBSection.argtypes = [
                wintypes.HDC, ctypes.c_void_p, wintypes.UINT,
                ctypes.POINTER(ctypes.c_void_p), wintypes.HANDLE,
                wintypes.DWORD]
            g.SelectObject.restype = wintypes.HGDIOBJ
            g.SelectObject.argtypes = [wintypes.HDC, wintypes.HGDIOBJ]

            class BITMAPINFOHEADER(ctypes.Structure):
                _fields_ = [("biSize", wintypes.DWORD),
                            ("biWidth", wintypes.LONG),
                            ("biHeight", wintypes.LONG),
                            ("biPlanes", wintypes.WORD),
                            ("biBitCount", wintypes.WORD),
                            ("biCompression", wintypes.DWORD),
                            ("biSizeImage", wintypes.DWORD),
                            ("biXPelsPerMeter", wintypes.LONG),
                            ("biYPelsPerMeter", wintypes.LONG),
                            ("biClrUsed", wintypes.DWORD),
                            ("biClrImportant", wintypes.DWORD)]

            class BLENDFUNCTION(ctypes.Structure):
                _fields_ = [("BlendOp", ctypes.c_byte),
                            ("BlendFlags", ctypes.c_byte),
                            ("SourceConstantAlpha", ctypes.c_byte),
                            ("AlphaFormat", ctypes.c_byte)]

            u.UpdateLayeredWindow.restype = wintypes.BOOL
            u.UpdateLayeredWindow.argtypes = [
                wintypes.HWND, wintypes.HDC, ctypes.POINTER(wintypes.POINT),
                ctypes.POINTER(wintypes.SIZE), wintypes.HDC,
                ctypes.POINTER(wintypes.POINT), wintypes.DWORD,
                ctypes.POINTER(BLENDFUNCTION), wintypes.DWORD]

            self.root.update_idletasks()
            wid = self.root.winfo_id()
            self.hwnd = u.GetParent(wid) or wid

            GWL_EXSTYLE, WS_EX_LAYERED = -20, 0x00080000
            ex = u.GetWindowLongW(self.hwnd, GWL_EXSTYLE)
            u.SetWindowLongW(self.hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED)

            hdr = BITMAPINFOHEADER()
            hdr.biSize = ctypes.sizeof(BITMAPINFOHEADER)
            hdr.biWidth, hdr.biHeight = WIN_W, -WIN_H     # top-down rows
            hdr.biPlanes, hdr.biBitCount = 1, 32
            hdr.biCompression = 0                          # BI_RGB

            self.screen_dc = u.GetDC(None)
            self.bits = ctypes.c_void_p()
            self.hbmp = g.CreateDIBSection(self.screen_dc, ctypes.byref(hdr),
                                           0, ctypes.byref(self.bits),
                                           None, 0)
            if not self.hbmp:
                return False
            self.mem_dc = g.CreateCompatibleDC(self.screen_dc)
            g.SelectObject(self.mem_dc, self.hbmp)

            self.blend = BLENDFUNCTION(0, 0, 255, 1)       # AC_SRC_ALPHA
            self.size = wintypes.SIZE(WIN_W, WIN_H)
            self.origin = wintypes.POINT(0, 0)
            self.nbytes = WIN_W * WIN_H * 4
            return True
        except Exception:
            return False

    def _show(self, frame):
        if self.layered:
            # UpdateLayeredWindow wants premultiplied BGRA. ImageChops does
            # the premultiply; merging out of order gives the byte order.
            r, g, b, a = frame.split()
            mul = self.ImageChops.multiply
            bgra = self.Image.merge("RGBA", (mul(b, a), mul(g, a),
                                             mul(r, a), a))
            buf = bgra.tobytes("raw", "RGBA")
            self.ctypes.memmove(self.bits, buf, min(len(buf), self.nbytes))
            self.user32.UpdateLayeredWindow(
                self.hwnd, self.screen_dc, None, self.ctypes.byref(self.size),
                self.mem_dc, self.ctypes.byref(self.origin), 0,
                self.ctypes.byref(self.blend), 2)          # ULW_ALPHA
            return
        if self.system == "Windows":                       # colour-key path
            flat = self.Image.new("RGB", frame.size, (0x01, 0x02, 0x03))
            flat.paste(frame, (0, 0), frame)
            frame = flat
        if self.photo is None:                             # build once, then
            self.photo = self.ImageTk.PhotoImage(frame)     # repaint in place:
            self.canvas.itemconfigure(self.image_id, image=self.photo)
        else:
            self.photo.paste(frame)                         # no realloc, no GC

    # ------------------------------------------------------ static layers

    def _build_layers(self, Image, ImageDraw, ImageFilter):
        W, H, S = WIN_W * SS, WIN_H * SS, SS
        cx, cy = ORB_C[0] * S, ORB_C[1] * S

        ring = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        rr = (R_MAX + RING_W) * S       # inner edge == the orb's peak
        ImageDraw.Draw(ring).ellipse((cx - rr, cy - rr, cx + rr, cy + rr),
                                     outline=TARGET_RING + (199,),
                                     width=RING_W * S)
        self.base = ring.resize((WIN_W, WIN_H), Image.LANCZOS)

        # The tab is composited last, so the halo never tints it.
        tx, ty = TAB_C[0] * S, TAB_C[1] * S
        tr = (TAB_D * S) // 2
        tab = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        shade = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(shade).ellipse(
            (tx - tr, ty - tr + S * 2, tx + tr, ty + tr + S * 2),
            fill=(84, 58, 46, 66))
        tab = Image.alpha_composite(tab, shade.filter(
            ImageFilter.GaussianBlur(S * 2)))
        disc = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        ImageDraw.Draw(disc).ellipse((tx - tr, ty - tr, tx + tr, ty + tr),
                                     fill=TAB + (255,))
        tab = Image.alpha_composite(tab, disc)
        self.tab = tab.resize((WIN_W, WIN_H), Image.LANCZOS)

    def _load_font(self, ImageFont):
        for path in FONT_FILES:
            try:
                if os.path.exists(path):
                    return ImageFont.truetype(path, 15)
            except Exception:
                continue
        return ImageFont.load_default()

    def _build_sprites(self, Image, ImageDraw):
        # Lazily filled: whole-pixel orb masters, halo alpha LUTs, and one
        # pre-composed tab per value the count can show. All bounded and all
        # full within the first breath, so no frame pays to build twice.
        self._core_masters = {}
        self._luts = {}
        self._tabs = {}

        N = 512
        big = Image.new("L", (N * 2, N * 2), 0)
        ImageDraw.Draw(big).ellipse((0, 0, N * 2 - 1, N * 2 - 1), fill=255)
        self.sprite_core = big.resize((N, N), Image.LANCZOS)

        # Radial falloff for the bloom, a pure alpha map we tint and rescale
        # each frame. GLOW_SPAN keeps the tail inside the window.
        N, span = 384, GLOW_SPAN
        glow = Image.new("L", (N, N), 0)
        px = glow.load()
        c = (N - 1) / 2.0
        r_core = c / span
        for y in range(N):
            dy = y - c
            for x in range(N):
                d = math.hypot(x - c, dy)
                if d <= r_core:
                    px[x, y] = 255
                elif d < c:
                    k = 1.0 - (d - r_core) / (c - r_core)
                    px[x, y] = int(255 * (k ** 2.3))
        self.sprite_glow = glow

    # -------------------------------------------------- sub-pixel sprites
    # ease() flattens hard at each turnaround, so late in the inhale the orb
    # grows by well under a pixel per frame. Rounding a diameter to whole
    # pixels there freezes it for a dozen frames and then jumps it one pixel,
    # which is the stutter you see. So nothing is drawn at an integer size or
    # an integer offset: a master sprite is resampled into a FIXED tile by an
    # AFFINE transform, whose scale and translation are floats. The tile is
    # pasted at a constant integer position, and every sub-pixel change lands
    # in the anti-aliased edge instead of being rounded away.

    def _core_tile(self, dd):
        """The orb as an alpha tile, at float diameter dd."""
        Image = self.Image
        # Resample from the next whole-pixel master up, so the transform is
        # always a slight minification and never a blurring enlargement, and
        # never lands exactly on 1:1 (which would be a visible sharpness step
        # each time the diameter crosses an integer).
        n = max(4, int(dd) + 2)
        master = self._core_masters.get(n)
        if master is None:
            master = self.sprite_core.resize((n, n), Image.LANCZOS)
            self._core_masters[n] = master
        s = n / dd
        c = n / 2.0 - s * (CORE_TILE / 2.0)
        return master.transform((CORE_TILE, CORE_TILE), Image.AFFINE,
                                (s, 0, c, 0, s, c), resample=Image.BILINEAR)

    def _halo_layer(self, r, gi, e):
        """All four lobes, composed at half resolution and scaled back up.

        The halo carries no detail - it is a k**2.3 radial falloff - so half
        the pixels look the same and cost a quarter. Sub-pixel motion survives
        the shortcut because the size and offset stay floats inside the
        affine; only the grid they land on is coarser, and it is blurry.
        """
        Image = self.Image
        hw, hh = WIN_W // HALO_SCALE, WIN_H // HALO_SCALE
        layer = Image.new("RGBA", (hw, hh), (0, 0, 0, 0))
        n = self.sprite_glow.width

        # Four lobes, each on its own orbit, breathing size and intensity at
        # unequal rates: the halo is never the same thickness twice round, and
        # it keeps moving through the hold. Cosmetic only - it never feeds
        # back into the tick clock.
        for tint, span, dist, wo, ph, ws, wa, weight in HALO_LOBES:
            gd = max(2.0, r * 2 * GLOW_SPAN * span *
                     (1 + 0.22 * math.sin(ws * e + ph)))
            peak = int(118 * gi * weight *
                       (0.66 + 0.34 * math.sin(wa * e + ph * 1.7)))
            if peak <= 0:
                continue
            off = r * dist * (1 + 0.20 * math.sin(ws * 0.7 * e + ph * 1.4))
            ang = ph + wo * e
            s = n * HALO_SCALE / gd
            cx = n / 2.0 - s * ((ORB_C[0] + math.cos(ang) * off) / HALO_SCALE)
            cy = n / 2.0 - s * ((ORB_C[1] + math.sin(ang) * off) / HALO_SCALE)
            mask = self.sprite_glow.transform(
                (hw, hh), Image.AFFINE, (s, 0, cx, 0, s, cy),
                resample=Image.BILINEAR)
            lut = self._luts.get(peak)
            if lut is None:
                lut = self._luts[peak] = bytes(
                    (a * peak) // 255 for a in range(256))
            layer.paste(tint + (255,), (0, 0), mask.point(lut))
        return layer.resize((WIN_W, WIN_H), Image.BILINEAR)

    def _tab_tile(self, count):
        """Tab and its digit, pre-composed once per value the count can take."""
        tile = self._tabs.get(count)
        if tile is not None:
            return tile
        tile = self.tab.copy()
        label = str(count)
        drw = self.ImageDraw.Draw(tile)
        try:
            drw.text(TAB_C, label, font=self.font, fill=TAB_INK + (255,),
                     anchor="mm")
        except (TypeError, ValueError):
            w = drw.textlength(label, font=self.font)
            drw.text((TAB_C[0] - w / 2, TAB_C[1] - 8), label, font=self.font,
                     fill=TAB_INK + (255,))
        self._tabs[count] = tile
        return tile

    # ---------------------------------------------------------- per frame

    def render(self, phase, fullness, left, e):
        """Compose one frame. Pure: no window, no clock - so it is testable."""
        dd = orb_radius(fullness) * 2.0
        colour = lerp3(ORB_REST, ORB_FULL, min(1.0, fullness ** 1.15))
        if self.paused:
            colour = lerp3(colour, (176, 158, 146), 0.55)

        frame = self.base.copy()
        cx, cy = ORB_C

        gi = 0.0 if self.paused else fullness ** 2.6
        if gi > 0.01:
            frame.alpha_composite(self._halo_layer(dd / 2.0, gi, e))

        frame.paste(colour + (255,),
                    (cx - CORE_TILE // 2, cy - CORE_TILE // 2),
                    self._core_tile(dd))
        return self.Image.alpha_composite(
            frame, self._tab_tile(phase_count(self.inhale, self.exhale,
                                              phase, left)))

    def _frame(self):
        if not self.alive:
            return
        now = time.monotonic()
        e = (self.pause_at if self.paused else now) - self.start - self.offset

        if self.total is not None and e >= self.total:
            return self._quit()

        cycle, phase, progress, left = phase_at(e, self.inhale, self.exhale,
                                                self.hold)

        if not self.paused:
            key = (cycle, phase)
            if key != self.last_key:
                self.last_key = key
                if phase == "in":
                    self.player.play(self.tick_in, "in")
                elif phase == "out":
                    self.player.play(self.tick_out, "out")

        self._show(self.render(phase, fullness_at(phase, progress), left, e))

        # Pace against a fixed grid, not against "now + 16ms": the latter adds
        # however long the frame took to every interval, so the cadence sags
        # and wobbles with the render cost. If we fall more than a frame
        # behind, drop the arrears rather than sprinting to catch up.
        self._due += 1.0 / FPS
        slack = self._due - time.monotonic()
        if slack < -1.0 / FPS:
            self._due = time.monotonic()
            slack = 0.0
        self.root.after(max(1, int(slack * 1000)), self._frame)

    # ------------------------------------------------------ window chrome

    def _toggle(self):
        now = time.monotonic()
        if self.paused:
            self.offset += now - self.pause_at
            self.paused = False
        else:
            self.pause_at = now
            self.paused = True

    def _grab(self, e):
        self._ox, self._oy = e.x, e.y

    def _drag(self, e):
        self.root.geometry("+%d+%d" % (e.x_root - self._ox,
                                       e.y_root - self._oy))

    def _quit(self, *_):
        self.alive = False
        if self.layered:
            try:
                self.gdi32.DeleteObject(self.hbmp)
                self.gdi32.DeleteDC(self.mem_dc)
                self.user32.ReleaseDC(None, self.screen_dc)
            except Exception:
                pass
        try:
            self.root.destroy()
        except Exception:
            pass

    def run(self):
        try:
            self.root.mainloop()
        except KeyboardInterrupt:
            self._quit()


# ============================================================ TERMINAL

BLOCKS = " ▁▂▃▄▅▆▇█"
LABELS = {"in": "in ", "hold-in": " · ", "out": "out", "hold-out": " · "}


def bar(frac, width=34):
    pos = min(max(frac, 0.0), 1.0) * width
    full = int(pos)
    s = "█" * full
    if full < width:
        s += BLOCKS[int((pos - full) * 8)]
    return s.ljust(width)


def fmt(sec):
    return f"{int(sec) // 60:d}:{int(sec) % 60:02d}"


def run_term(inhale, exhale, hold, total, volume, silent, plain):
    player = Player(silent)
    if player.mode == "bell":
        print(f"  \033[91mno audio backend ({player.reason or 'none found'}).\033[0m")
        print("  \033[2mrun: pip install sounddevice     then try again\033[0m")
        print("  \033[2mcontinuing with the visual bar only.\033[0m\n")

    tick_in = make_tick(740.0, volume=volume)
    tick_out = make_tick(494.0, volume=volume * 0.85)
    start = time.monotonic()
    last_key = None
    cycles = 0

    sys.stdout.write("\033[?25l")
    try:
        while True:
            elapsed = time.monotonic() - start
            if total is not None and elapsed >= total:
                break

            if plain:
                idx = int(elapsed // exhale)
                frac = (elapsed - idx * exhale) / exhale
                ph, left = "in", exhale - (elapsed - idx * exhale)
            else:
                idx, ph, frac, left = phase_at(elapsed, inhale, exhale, hold)

            key = (idx, ph)
            if key != last_key:
                if ph == "in":
                    player.play(tick_in, "in")
                    if last_key is not None:
                        cycles += 1
                elif ph == "out":
                    player.play(tick_out, "out")
                last_key = key

            if plain:
                line = f"  \033[2m{bar(frac)}\033[0m   tick every {exhale:g}s"
            else:
                shown = fullness_at(ph, frac)
                col = "\033[96m" if ph.endswith("in") else "\033[38;5;141m"
                count = phase_count(inhale, exhale, ph, left)
                line = (f"  {col}{LABELS[ph]}\033[0m  {col}{bar(shown)}\033[0m"
                        f"  {col}{count:2d}\033[0m")

            clock = f"{fmt(elapsed)} elapsed" if total is None else f"{fmt(total - elapsed)} left"
            sys.stdout.write(f"\r{line}   \033[2m{clock}\033[0m ")
            sys.stdout.flush()
            time.sleep(0.033)
    except KeyboardInterrupt:
        pass
    finally:
        sys.stdout.write("\033[?25h\r" + " " * 100 + "\r")
        sys.stdout.flush()
        player.close()

    print(f"done. {fmt(time.monotonic() - start)}, {cycles} cycles")


def selftest(volume):
    p = Player(False)
    print(f"\n  backend: \033[1m{p.mode}\033[0m")
    if p.reason:
        print(f"  \033[2m{p.reason}\033[0m")
    if p.mode == "sounddevice":
        import sounddevice as sd
        try:
            print(f"  output device: {sd.query_devices(kind='output')['name']}")
        except Exception as e:
            print(f"  couldn't read device: {e}")
    elif p.mode == "bell":
        print("  \033[91m  no real audio backend. you will hear nothing.\033[0m")
        print("  \033[2m  fix: pip install sounddevice\033[0m")
        print("  \033[2m  linux also needs: sudo apt install libportaudio2\033[0m")

    print(f"\n  playing 3 ticks at volume {volume:g}...")
    t = make_tick(volume=volume)
    for i in range(3):
        p.play(t, "in")
        print(f"    tick {i + 1}")
        time.sleep(1.0)
    time.sleep(0.4)
    p.close()
    print("\n  heard nothing? try --volume 0.8, check system volume,")
    print("  and note ssh / WSL / docker have no audio device at all.\n")


# ============================================================ MAIN

def main():
    p = argparse.ArgumentParser(description="soft-tick breathing pacer")
    p.add_argument("--gui", action="store_true", help="floating always-on-top glass window")
    p.add_argument("--inhale", type=float, default=4.0)
    p.add_argument("--exhale", type=float, default=6.0)
    p.add_argument("--hold", type=float, default=0.5,
                   help="still pause at each turnaround (default 0.5)")
    p.add_argument("--interval", type=float, default=None,
                   help="plain metronome: one tick every N seconds (terminal only)")
    p.add_argument("--minutes", type=float, default=None,
                   help="stop after N minutes (default: forever)")
    p.add_argument("--volume", type=float, default=0.25)
    p.add_argument("--silent", action="store_true")
    p.add_argument("--test", action="store_true", help="check audio, then exit")
    a = p.parse_args()

    if a.inhale <= 0 or a.exhale <= 0:
        p.error("--inhale and --exhale must be positive")
    hold = max(0.0, a.hold)

    if a.test:
        return selftest(a.volume)

    total = None if a.minutes is None else a.minutes * 60

    if a.gui:
        try:
            import tkinter  # noqa: F401
            from PIL import Image  # noqa: F401
        except ImportError as e:
            sys.exit(f"gui needs tkinter and pillow ({e})\n"
                     f"  pip install pillow\n"
                     f"  linux also: sudo apt install python3-tk")
        pl = Player(a.silent)
        g = Glass(a.inhale, a.exhale, hold, pl, a.volume, total)
        try:
            g.run()
        finally:
            pl.close()
        return

    plain = a.interval is not None
    exhale = a.interval if plain else a.exhale
    length = "forever" if total is None else f"{a.minutes:g} min"
    print()
    if plain:
        print(f"  \033[2msoft tick every {exhale:g}s  ·  {length}  ·  ctrl-c to stop\033[0m")
    else:
        print(f"  \033[2m{a.inhale:g} in / {exhale:g} out  ·  {length}  ·  ctrl-c to stop\033[0m")
    print("\033[2m  nose only. belly moves, chest doesn't. keep it small.\033[0m\n")
    time.sleep(1.5)
    run_term(a.inhale, exhale, hold, total, a.volume, a.silent, plain)


if __name__ == "__main__":
    main()
