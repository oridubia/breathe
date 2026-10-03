# breathe

A soft-tick breathing pacer: a gentle tick at the start of each inhale and
exhale, shown either as a terminal bar or as a floating, transparent,
always-on-top window with an expanding orb.

Default pattern: 4 s in, 6 s out, with a half-second hold at each turnaround.

## Install

```sh
python3 -m venv .venv
. .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt
```

The GUI also needs Tk (bundled with the python.org installers; on Debian/Ubuntu,
`apt install python3-tk`).

## Usage

```sh
python3 breathe.py --gui                         # floating window
python3 breathe.py                               # terminal bar
python3 breathe.py --gui --inhale 5.5 --exhale 5.5
python3 breathe.py --interval 6                  # plain metronome
python3 breathe.py --test                        # check that audio works
python3 breathe.py --minutes 10                  # stop after 10 minutes
python3 breathe.py --help                        # all options
```

GUI keys: drag to move, space to pause, Esc to quit.

## Tests

```sh
pip install -r requirements-dev.txt
pytest
```

The design invariants (single clock, audio stream, rendering budget, Windows
transparency) are documented in the module docstring of `breathe.py`. Read
them before changing the timing or audio code.
