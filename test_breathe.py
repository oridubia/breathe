"""Tests for breathe.py — the clock, the tick synthesis, and the frame render.

The GUI needs a display, but Glass.render() is pure (no window, no clock), so
the whole drawing path is exercised here headlessly.
"""

import math

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
    assert not (breathe.make_tick(740.0) == breathe.make_tick(494.0)).all()


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
