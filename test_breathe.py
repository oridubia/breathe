"""Tests for breathe.py — the clock, the tick synthesis, and the frame render.

The GUI needs a display, but Glass.render() is pure (no window, no clock), so
the whole drawing path is exercised here headlessly.
"""

import math
import os
import sys
import wave

import pytest

import breathe


# ------------------------------------------------------------------ the clock

def test_phase_at_walks_in_hold_out_hold():
    """4 in / 6 out / 0.5 hold -> an 11s period in four named stretches."""
    seq = [(0.0, "in"), (3.9, "in"),
           (4.2, "hold-in"),
           (4.6, "out"), (10.4, "out"),
           (10.6, "hold-out"), (10.9, "hold-out")]
    for t, expected in seq:
        assert breathe.phase_at(t, 4.0, 6.0, 0.5)[1] == expected, t


def test_phase_at_cycle_index_advances_with_the_period():
    period = 4.0 + 6.0 + 0.5 * 2
    assert breathe.phase_at(0.0, 4.0, 6.0, 0.5)[0] == 0
    assert breathe.phase_at(period - 0.01, 4.0, 6.0, 0.5)[0] == 0
    assert breathe.phase_at(period + 0.01, 4.0, 6.0, 0.5)[0] == 1
    assert breathe.phase_at(period * 7 + 0.01, 4.0, 6.0, 0.5)[0] == 7


def test_phase_at_progress_and_time_left_agree():
    for t in (0.0, 1.0, 3.99, 5.0, 9.0):
        _, phase, progress, left = breathe.phase_at(t, 4.0, 6.0, 0.5)
        length = 4.0 if phase == "in" else 6.0
        assert progress == pytest.approx(1.0 - left / length)
        assert 0.0 <= progress <= 1.0
        assert left > 0.0


def test_phase_at_without_hold_is_only_in_and_out():
    for i in range(200):
        phase = breathe.phase_at(i * 0.05, 4.0, 6.0, 0.0)[1]
        assert phase in ("in", "out")


def test_phase_at_is_stateless_so_a_stall_cannot_drift():
    """Sampling out of order must give the same answer as sampling in order."""
    forwards = [breathe.phase_at(i * 0.1, 4.0, 6.0, 0.5) for i in range(300)]
    backwards = [breathe.phase_at(i * 0.1, 4.0, 6.0, 0.5)
                 for i in reversed(range(300))]
    assert forwards == list(reversed(backwards))


# ----------------------------------------------------------------- the easing

def test_ease_spans_zero_to_one_and_never_goes_backwards():
    assert breathe.ease(0.0) == pytest.approx(0.0)
    assert breathe.ease(1.0) == pytest.approx(1.0)
    prev = -1.0
    for i in range(1001):
        v = breathe.ease(i / 1000.0)
        assert v >= prev
        prev = v


def test_ease_clamps_outside_the_unit_interval():
    assert breathe.ease(-3.0) == pytest.approx(0.0)
    assert breathe.ease(9.0) == pytest.approx(1.0)


def test_ease_is_slower_at_the_turnarounds_than_mid_phase():
    step = 0.02
    at_edge = breathe.ease(step) - breathe.ease(0.0)
    at_middle = breathe.ease(0.5 + step) - breathe.ease(0.5)
    assert at_middle > at_edge * 3


def test_fullness_runs_full_at_the_top_and_empty_at_the_bottom():
    assert breathe.fullness_at("in", 0.0) == pytest.approx(0.0)
    assert breathe.fullness_at("in", 1.0) == pytest.approx(1.0)
    assert breathe.fullness_at("out", 0.0) == pytest.approx(1.0)
    assert breathe.fullness_at("out", 1.0) == pytest.approx(0.0)
    assert breathe.fullness_at("hold-in", 0.5) == 1.0
    assert breathe.fullness_at("hold-out", 0.5) == 0.0


# -------------------------------------------------------------------- the orb

def test_orb_radius_hits_both_ends():
    assert breathe.orb_radius(0.0) == pytest.approx(breathe.R_MIN)
    assert breathe.orb_radius(1.0) == pytest.approx(breathe.R_MAX)


def test_orb_interpolates_area_not_radius():
    """Half fullness is half the area, so the radius is above the midpoint."""
    half = breathe.orb_radius(0.5)
    area_mid = math.pi * (breathe.R_MIN ** 2 + breathe.R_MAX ** 2) / 2
    assert math.pi * half ** 2 == pytest.approx(area_mid)
    assert half > (breathe.R_MIN + breathe.R_MAX) / 2


def test_lerp3_blends_between_two_colours():
    assert breathe.lerp3((0, 0, 0), (10, 20, 30), 0.0) == (0, 0, 0)
    assert breathe.lerp3((0, 0, 0), (10, 20, 30), 1.0) == (10, 20, 30)
    assert breathe.lerp3((0, 0, 0), (10, 20, 30), 0.5) == (5, 10, 15)


# ------------------------------------------------------------------ the count

def test_count_starts_at_zero_and_turns_over_each_whole_second():
    seen = [breathe.phase_count(4.0, 6.0, "in", 4.0 - t)
            for t in (0.0, 0.9, 1.0, 1.1, 2.5, 3.99)]
    assert seen == [0, 0, 1, 1, 2, 3]


def test_count_shows_zero_for_the_whole_first_second():
    """The first second is watched ticking away, not skipped."""
    for t in (0.0, 0.25, 0.5, 0.75, 0.999):
        assert breathe.phase_count(4.0, 6.0, "in", 4.0 - t) == 0
    assert breathe.phase_count(4.0, 6.0, "out", 6.0 - 0.999) == 0


def test_count_never_exceeds_the_phase_length():
    for t in range(0, 600):
        left = 6.0 - t / 100.0
        assert 0 <= breathe.phase_count(4.0, 6.0, "out", left) <= 6


def test_hold_keeps_the_last_number_of_the_phase_it_follows():
    assert breathe.phase_count(4.0, 6.0, "hold-in", 0.2) == 4
    assert breathe.phase_count(4.0, 6.0, "hold-out", 0.2) == 6


def test_count_tops_out_at_the_ceiling_for_fractional_phases():
    assert breathe.phase_count(5.5, 6.0, "hold-in", 0.1) == 6
    assert breathe.phase_count(5.5, 6.0, "in", 0.01) == 5


def test_count_walks_the_whole_phase_without_skipping_a_number():
    seen = []
    for i in range(460):                       # 11.5s: a full 11s cycle + a bit
        _, phase, _, left = breathe.phase_at(i * 0.025, 4.0, 6.0, 0.5)
        n = breathe.phase_count(4.0, 6.0, phase, left)
        if not seen or seen[-1] != n:
            seen.append(n)
    assert seen == [0, 1, 2, 3, 4, 0, 1, 2, 3, 4, 5, 6, 0]


# ------------------------------------------------------------------ the sound

def test_the_tick_rings_rather_than_clicks():
    """The defect behind "it randomly misses ticks".

    The original tick stayed within 25dB of its own peak for 78ms at -24dBFS
    RMS - near the threshold of noticing, so whether you caught it depended on
    the room and your attention rather than on whether it played. Nothing about
    that is visible in a log: every tick was dispatched, mixed and drained
    correctly. It has to ring long enough to be unmissable.
    """
    import numpy
    x = breathe.make_tick(breathe.TICK_IN_HZ)
    peak = float(numpy.abs(x).max())
    above = numpy.where(numpy.abs(x) > peak * 10 ** (-25 / 20.0))[0]
    audible_ms = (above[-1] - above[0]) / breathe.SR * 1000
    assert audible_ms > 150, "only %.0fms of audible ring" % audible_ms

    rms = float(numpy.sqrt(numpy.mean(x.astype(numpy.float64) ** 2)))
    assert 20 * math.log10(rms) > -21, "too quiet at %.1f dBFS RMS" % (
        20 * math.log10(rms))


def test_a_tick_still_fits_between_two_ticks():
    """It may ring, but never over the top of the next one."""
    longest = len(breathe.make_tick(breathe.TICK_IN_HZ)) / breathe.SR
    tightest_gap = min(4.0, 6.0) / 2       # shortest half-breath worth pacing
    assert longest < tightest_gap


def test_tick_is_the_requested_length_and_volume():
    tick = breathe.make_tick(740.0, dur=0.09, volume=0.4)
    assert len(tick) == int(breathe.SR * 0.09)
    assert abs(tick).max() == pytest.approx(0.4, abs=1e-3)
    assert tick.dtype.name == "float32"


def test_tick_fades_in_and_out_so_it_cannot_click():
    tick = breathe.make_tick(740.0, volume=0.4)
    assert abs(tick[0]) < 1e-3
    assert abs(tick[-1]) < 1e-3


def test_tick_is_deterministic():
    assert (breathe.make_tick(494.0) == breathe.make_tick(494.0)).all()


def test_inhale_and_exhale_ticks_are_distinguishable():
    assert not (breathe.make_tick(breathe.TICK_IN_HZ)
                == breathe.make_tick(breathe.TICK_OUT_HZ)).all()


def test_both_ticks_clear_the_speaker_rolloff():
    """A laptop speaker rolls off steeply under ~600Hz. The old exhale tick at
    494Hz put 48% of its energy below 500Hz, so its fundamental was thrown
    away and it went inaudible on small speakers while the inhale tick was
    fine. Neither tick may sit on that cliff again.
    """
    import numpy
    for hz in (breathe.TICK_IN_HZ, breathe.TICK_OUT_HZ):
        x = breathe.make_tick(hz, volume=0.25).astype(numpy.float64)
        power = numpy.abs(numpy.fft.rfft(x)) ** 2
        freq = numpy.fft.rfftfreq(len(x), 1.0 / breathe.SR)
        below = power[freq < 500].sum() / power.sum()
        assert below < 0.05, "%.0fHz puts %.0f%% of its energy under 500Hz" % (
            hz, below * 100)
        assert hz > 600.0


def test_the_two_ticks_are_equally_loud():
    """The exhale tick used to be attenuated to 0.85 on top of being filtered
    out by the speaker."""
    a = breathe.make_tick(breathe.TICK_IN_HZ, volume=0.25)
    b = breathe.make_tick(breathe.TICK_OUT_HZ, volume=0.25)
    assert abs(float(abs(a).max()) - float(abs(b).max())) < 1e-6


class _Status:
    """Stands in for sounddevice's CallbackFlags."""

    def __init__(self, output_underflow=False):
        self.output_underflow = output_underflow


def _outdata(frames):
    import numpy
    return numpy.zeros((frames, 1), dtype=numpy.float32)


def test_callback_mixes_a_queued_tick_into_the_output():
    import numpy
    p = breathe.Player(silent=True)
    tick = breathe.make_tick(volume=0.5)
    p.voices.append((tick, 0))
    out = _outdata(256)
    p._cb(out, 256, None, _Status())
    assert numpy.allclose(out[:, 0], tick[:256])


def test_a_tick_outlasting_one_block_survives_to_the_next_callback():
    import numpy
    p = breathe.Player(silent=True)
    tick = breathe.make_tick(volume=0.5)
    assert len(tick) > 512, "this test needs a tick longer than two blocks"
    p.voices.append((tick, 0))
    p._cb(_outdata(256), 256, None, _Status())
    assert p.voices[0][1] == 256, "playback position did not advance"
    out = _outdata(256)
    p._cb(out, 256, None, _Status())
    assert numpy.allclose(out[:, 0], tick[256:512])


def test_two_overlapping_ticks_sum_rather_than_replace():
    import numpy
    p = breathe.Player(silent=True)
    tick = breathe.make_tick(volume=0.4)
    p.voices.extend([(tick, 0), (tick, 0)])
    out = _outdata(256)
    p._cb(out, 256, None, _Status())
    assert numpy.allclose(out[:, 0], tick[:256] * 2)


def test_a_finished_tick_is_dropped_from_the_mix():
    p = breathe.Player(silent=True)
    tick = breathe.make_tick(volume=0.5)
    p.voices.append((tick, 0))
    p._cb(_outdata(len(tick) + 64), len(tick) + 64, None, _Status())
    assert p.voices == []


def test_an_underrun_hitting_silence_is_reported_as_harmless():
    """Nothing was sounding, so the glitch cost nothing."""
    p = breathe.Player(silent=True)
    assert p.underruns == 0 and p.report() == ""
    for _ in range(3):
        p._cb(_outdata(256), 256, None, _Status(output_underflow=True))
    assert p.underruns == 3
    assert p.underruns_in_tick == 0
    assert "harmless" in p.report()


def test_an_underrun_during_a_tick_is_counted_as_a_lost_tick():
    """The one that really costs you the sound.

    By the time the callback is late the driver has already inserted a gap and
    moved on, so those samples play where nobody hears them. The queue drains
    cleanly afterwards and every other counter looks healthy, which is why this
    had to be measured separately rather than inferred.
    """
    p = breathe.Player(silent=True)
    p.voices.append((breathe.make_tick(), 0))        # a tick is sounding
    p._cb(_outdata(256), 256, None, _Status(output_underflow=True))
    assert p.underruns == 1
    assert p.underruns_in_tick == 1
    assert "clipped or lost" in p.report()
    assert "harmless" not in p.report()


def test_underruns_are_split_between_damaging_and_harmless():
    p = breathe.Player(silent=True)
    p.voices.append((breathe.make_tick(), 0))
    p._cb(_outdata(256), 256, None, _Status(output_underflow=True))
    p.voices.clear()
    for _ in range(4):
        p._cb(_outdata(256), 256, None, _Status(output_underflow=True))
    assert (p.underruns, p.underruns_in_tick) == (5, 1)
    assert "1 underrun(s) landed WHILE" in p.report()
    assert "4 underrun(s) hit silence" in p.report()


def test_a_clean_run_reports_nothing():
    p = breathe.Player(silent=True)
    p._cb(_outdata(256), 256, None, _Status())
    assert p.report() == ""


# --------------------------------------------- the stream that dies on you
# "No ticks for five minutes" is an output stream that stopped and was never
# noticed. These cover the recovery, since the real failure needs a Windows
# audio device to be yanked away and cannot be reproduced in a test.

class _FakeStream:
    def __init__(self, active=True):
        self._active = active
        self.started = False
        self.closed = False

    @property
    def active(self):
        return self._active

    def start(self):
        self.started = True

    def close(self, ignore_errors=False):
        self.closed = True


class _FakeSd:
    def __init__(self, refuse=()):
        self.opened = []
        self.refuse = refuse           # device ids that cannot be opened

    def OutputStream(self, **kw):
        self.opened.append(kw)
        if kw.get("device") in self.refuse:
            raise RuntimeError("device %r refused this rate" % kw.get("device"))
        return _FakeStream()

    def query_hostapis(self, index=None):
        apis = [{"name": "MME", "default_output_device": 0},
                {"name": "Windows WASAPI", "default_output_device": 4}]
        return apis if index is None else apis[index]


def _wired_player(sd=None):
    """A Player on the sounddevice path, with the device faked out."""
    p = breathe.Player(silent=True)
    p.mode = "sounddevice"
    p.sd = sd or _FakeSd()
    p.stream = _FakeStream()
    return p


# ------------------------------------------------- the no-callback backend
# Every failure so far lived inside PortAudio's callback path, including in
# --test where nothing else was running. winsound has no Python in the
# playback path at all, so there is nothing there to be late.

class _FakeWinsound:
    SND_FILENAME = 0x20000
    SND_ASYNC = 0x0001
    SND_NODEFAULT = 0x0002

    def __init__(self):
        self.played = []

    def PlaySound(self, path, flags):
        self.played.append((path, flags))


def test_winsound_is_preferred_on_windows(monkeypatch):
    monkeypatch.setattr(breathe.platform, "system", lambda: "Windows")
    monkeypatch.setitem(sys.modules, "winsound", _FakeWinsound())
    p = breathe.Player()
    assert p.mode == "winsound"


def test_winsound_is_not_used_off_windows(monkeypatch):
    monkeypatch.setattr(breathe.platform, "system", lambda: "Linux")
    monkeypatch.setitem(sys.modules, "winsound", _FakeWinsound())
    p = breathe.Player()
    assert p.mode != "winsound"


def test_the_backend_can_be_forced_past_winsound(monkeypatch):
    """--backend sounddevice must skip winsound even on Windows, so the two
    can be compared against each other."""
    monkeypatch.setattr(breathe.platform, "system", lambda: "Windows")
    monkeypatch.setitem(sys.modules, "winsound", _FakeWinsound())
    p = breathe.Player(backend="sounddevice")
    assert p.mode != "winsound"


def test_winsound_plays_asynchronously_and_never_the_default_beep(monkeypatch):
    fake = _FakeWinsound()
    monkeypatch.setattr(breathe.platform, "system", lambda: "Windows")
    monkeypatch.setitem(sys.modules, "winsound", fake)
    p = breathe.Player()
    p.play(breathe.make_tick(breathe.TICK_IN_HZ), "in")
    assert len(fake.played) == 1
    path, flags = fake.played[0]
    assert path.endswith("breathe_in.wav")
    assert flags & fake.SND_ASYNC, "a blocking play would stall the pacer"
    assert flags & fake.SND_NODEFAULT, "a failure must be silence, not a beep"


def test_the_wav_handed_to_windows_round_trips_intact():
    """winsound plays a file, so the file has to be right."""
    import numpy
    p = breathe.Player(silent=True)
    tick = breathe.make_tick(breathe.TICK_OUT_HZ, volume=0.5)
    path = p._wav(tick, "out")
    with wave.open(path, "rb") as w:
        assert w.getnchannels() == 1
        assert w.getsampwidth() == 2
        assert w.getframerate() == breathe.SR
        assert w.getnframes() == len(tick)
        pcm = numpy.frombuffer(w.readframes(w.getnframes()), dtype="<i2")
    assert numpy.allclose(pcm / 32767.0, tick, atol=1e-4)


def test_the_wav_is_written_once_and_reused():
    p = breathe.Player(silent=True)
    tick = breathe.make_tick()
    first = p._wav(tick, "in")
    mtime = os.path.getmtime(first)
    assert p._wav(tick, "in") == first
    assert os.path.getmtime(first) == mtime


def test_wasapi_is_preferred_over_mme_on_windows(monkeypatch):
    """PortAudio defaults to MME, which underruns far more readily."""
    monkeypatch.setattr(breathe.platform, "system", lambda: "Windows")
    p = _wired_player()
    assert p._pick_device() == 4          # the WASAPI default output


def test_the_host_api_is_left_to_portaudio_off_windows(monkeypatch):
    monkeypatch.setattr(breathe.platform, "system", lambda: "Linux")
    p = _wired_player()
    assert p._pick_device() is None


def test_the_default_device_is_the_fallback_when_wasapi_refuses():
    """WASAPI rejects rates the endpoint is not configured for; that must not
    leave the pacer silent."""
    p = _wired_player(sd=_FakeSd(refuse=(4,)))
    p._preferred = 4
    p.stream = None
    p._open_stream()
    assert [kw["device"] for kw in p.sd.opened] == [4, None]
    assert p.device is None
    assert p.stream is not None and p.stream.started


def test_a_stream_reporting_inactive_is_reopened_on_the_next_tick():
    p = _wired_player()
    p.stream._active = False
    p.play(breathe.make_tick(), "in")
    assert p.restarts == 1
    assert p.sd.opened, "no replacement stream was opened"
    assert p.stream.started


def test_a_wedged_stream_that_stopped_calling_back_is_reopened():
    """stream.active keeps saying True for a stream that has quietly died,
    so the callback counter is the ground truth."""
    p = _wired_player()
    p.cb_calls = 7
    p._cb_seen = 7                       # no callback since the last tick
    p.play(breathe.make_tick(), "in")
    assert p.restarts == 1


def test_a_healthy_stream_is_left_alone():
    p = _wired_player()
    p.cb_calls, p._cb_seen = 50, 10      # callbacks have been running
    first = p.stream
    p.play(breathe.make_tick(), "in")
    assert p.restarts == 0
    assert p.stream is first
    assert p.voices, "the tick was not queued"


def test_a_failed_reopen_is_counted_rather_than_raised():
    p = _wired_player()
    p.stream._active = False

    class _Boom:
        def OutputStream(self, **kw):
            raise RuntimeError("device gone")

    p.sd = _Boom()
    p.play(breathe.make_tick(), "in")    # must not raise
    assert p.failures == 1 and p.restarts == 0
    assert "reopen" in p.report()


def test_the_callback_never_lets_an_exception_reach_portaudio():
    """PortAudio aborts a stream for good if a callback raises, which is the
    silent-for-minutes failure. One bad buffer must not end the session."""
    p = breathe.Player(silent=True)
    p.voices.append(("not an array at all", 0))
    out = _outdata(256)
    p._cb(out, 256, None, _Status())      # must not raise
    assert p.cb_calls == 1, "liveness counter must move even on a bad frame"


def test_the_liveness_counter_moves_on_every_callback():
    p = breathe.Player(silent=True)
    for i in range(5):
        p._cb(_outdata(256), 256, None, _Status())
        assert p.cb_calls == i + 1


def test_silent_player_stays_quiet():
    player = breathe.Player(silent=True)
    assert player.mode == "silent"
    player.play(breathe.make_tick(), "in")      # must not raise
    player.close()


# ----------------------------------------------------------------- the render

@pytest.fixture(scope="module")
def glass():
    """A Glass with its layers built but no window — render() is pure."""
    from PIL import Image, ImageDraw, ImageFilter, ImageFont

    g = object.__new__(breathe.Glass)
    g.Image, g.ImageDraw = Image, ImageDraw
    g.inhale, g.exhale, g.paused = 4.0, 6.0, False
    g._build_layers(Image, ImageDraw, ImageFilter)
    g._build_sprites(Image, ImageDraw)
    g.font = g._load_font(ImageFont)
    return g


def orb_extent(frame):
    """Width of the drawn content, to check the orb really grows."""
    alpha = frame.getchannel("A")
    return alpha.getbbox()[2] - alpha.getbbox()[0]


def test_frame_is_a_window_sized_rgba_image(glass):
    frame = glass.render("in", 0.5, 2.0, 1.0)
    assert frame.mode == "RGBA"
    assert frame.size == (breathe.WIN_W, breathe.WIN_H)


def test_frame_stays_inside_the_window(glass):
    """Nothing is clipped: the halo tail has to fit at full inhale."""
    frame = glass.render("hold-in", 1.0, 0.5, 3.0)
    left, top, right, bottom = frame.getchannel("A").getbbox()
    assert left >= 0 and top >= 0
    assert right <= breathe.WIN_W and bottom <= breathe.WIN_H


def test_the_orb_grows_with_fullness(glass):
    small = orb_extent(glass.render("in", 0.0, 4.0, 0.0))
    big = orb_extent(glass.render("in", 1.0, 0.01, 4.0))
    assert big > small


def test_the_orb_reddens_as_it_fills(glass):
    cx, cy = breathe.ORB_C
    empty = glass.render("in", 0.0, 4.0, 0.0).getpixel((cx, cy))
    full = glass.render("hold-in", 1.0, 0.5, 4.0).getpixel((cx, cy))
    assert full[0] > empty[0]                    # more red
    assert full[1] < empty[1] and full[2] < empty[2]   # less green, less blue


def test_the_orb_never_freezes_late_in_the_inhale(glass):
    """The regression this test file exists for.

    ease() flattens hard at the turnaround, so over the last second of a 4s
    inhale the orb grows by well under a pixel per frame. Rounding to whole
    pixels there held it still for up to 14 frames and then jumped it one
    pixel — the stutter. Every frame must move, and only forwards.
    """
    masses = []
    for i in range(60):
        t = 3.0 + i / 60.0
        _, phase, progress, _ = breathe.phase_at(t, 4.0, 6.0, 0.5)
        dd = breathe.orb_radius(breathe.fullness_at(phase, progress)) * 2.0
        masses.append(sum(glass._core_tile(dd).tobytes()))
    assert len(set(masses)) == 60, "the orb froze on a repeated size"
    assert all(b > a for a, b in zip(masses, masses[1:])), "the orb went backwards"


def test_consecutive_frames_always_differ_through_the_turnaround(glass):
    """Whole frames, not just the orb: nothing may repeat, hold included."""
    prev = None
    for i in range(120):
        t = 3.0 + i / 60.0                     # last second of in, into hold
        _, phase, progress, left = breathe.phase_at(t, 4.0, 6.0, 0.5)
        frame = glass.render(phase, breathe.fullness_at(phase, progress),
                             left, t)
        assert frame.tobytes() != prev, "frame %d repeated" % i
        prev = frame.tobytes()


def test_the_orb_grows_smoothly_across_a_whole_integer_crossing(glass):
    """No sharpness step when the diameter passes a whole pixel."""
    masses = [sum(glass._core_tile(99.9 + k * 0.02).tobytes()) for k in range(11)]
    steps = [b - a for a, b in zip(masses, masses[1:])]
    assert all(s > 0 for s in steps)
    assert max(steps) < 4 * (sum(steps) / len(steps))


def test_sprite_caches_stay_bounded(glass):
    """Lazily built, but they must fill and then stop growing."""
    for i in range(240):
        t = i * 0.05
        _, phase, progress, left = breathe.phase_at(t, 4.0, 6.0, 0.5)
        glass.render(phase, breathe.fullness_at(phase, progress), left, t)
    assert len(glass._core_masters) <= int(breathe.R_MAX * 2) + 4
    assert len(glass._tabs) <= 8


def test_the_halo_drifts_so_two_moments_never_match(glass):
    a = glass.render("hold-in", 1.0, 0.5, 4.0)
    b = glass.render("hold-in", 1.0, 0.5, 7.3)
    assert a.tobytes() != b.tobytes()


def test_the_count_tab_is_opaque_and_untinted_by_the_halo(glass):
    frame = glass.render("hold-in", 1.0, 0.5, 4.0)
    r, g, b, a = frame.getpixel((breathe.TAB_C[0] + 12, breathe.TAB_C[1]))
    assert a == 255
    assert (r, g, b) == breathe.TAB


def test_pausing_greys_the_orb_and_kills_the_halo(glass):
    cx, cy = breathe.ORB_C
    live = glass.render("hold-in", 1.0, 0.5, 4.0)
    glass.paused = True
    try:
        held = glass.render("hold-in", 1.0, 0.5, 4.0)
    finally:
        glass.paused = False
    assert held.getpixel((cx, cy))[0] < live.getpixel((cx, cy))[0]
    assert orb_extent(held) < orb_extent(live)   # halo gone


def test_every_phase_renders(glass):
    for phase in ("in", "hold-in", "out", "hold-out"):
        fullness = breathe.fullness_at(phase, 0.5)
        assert glass.render(phase, fullness, 1.0, 2.0).size == (
            breathe.WIN_W, breathe.WIN_H)


# ------------------------------------------------------------- the arg surface

def test_inhale_and_exhale_must_be_positive(monkeypatch):
    monkeypatch.setattr("sys.argv", ["breathe.py", "--inhale", "0"])
    with pytest.raises(SystemExit):
        breathe.main()


def test_terminal_bar_fills_left_to_right():
    assert breathe.bar(0.0, 10).strip() == ""
    assert breathe.bar(1.0, 10) == "█" * 10
    assert len(breathe.bar(0.5, 10)) == 10


def test_clock_formats_as_minutes_and_seconds():
    assert breathe.fmt(0) == "0:00"
    assert breathe.fmt(65) == "1:05"
    assert breathe.fmt(600) == "10:00"
