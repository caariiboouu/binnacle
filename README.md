# Binnacle

A strip of live system instruments for the [Omarchy](https://omarchy.org) bar, with a
click-through detail panel.

![Binnacle](preview.png)

Binnacle does not ship a list of things it expects your machine to have. It looks, and
then builds instruments for whatever it finds — every GPU, every populated thermal
sensor, every mounted filesystem — and labels each one the way the kernel already names
it.

## What makes it different

**It discovers instead of assuming.** Labels come from `tempN_label` and `lspci`, never
from a table inside the plugin. Your package sensor is called `Package id 0 · coretemp`
because that is what your kernel calls it. A ThinkPad's EC sensors show up as
`CPU · thinkpad` and `GPU · thinkpad`; an NVMe drive as `Composite · nvme`.

**Presence is membership.** A machine with no discrete GPU emits no discrete-GPU entry —
it does not draw a graph pinned at zero and label it with a vendor you do not have. The
same holds for sensors, filesystems and integrated graphics.

**Per-sensor limits.** Each dial scales to its own critical point, read from sysfs. An
NVMe drive that crits at 87 °C is not drawn against a CPU's 100 °C ceiling, and a sensor
that publishes no critical point says so rather than inventing one.

**CPU accounting that survives process exit.** The leaderboard ranks what actually used
the CPU over the last window, using cgroup v2 counters. Sampling `/proc` per PID cannot
see a process that has already exited — measured on the development machine, 76 % of the
CPU burned in one window was unattributable to any surviving PID. Builds, scripts and
bursts are exactly the things that finish before you look at them, and they are exactly
what this catches.

**It stays out of the way.** One long-lived collector, not a process per sample. Steady
state is roughly 7 ms of CPU per second — about 0.7 % of one core — including the render
path. Panel contents are not instantiated while the panel is closed.

## Install

```bash
omarchy plugin add https://github.com/YOURNAME/binnacle --enable
```

Then pick a bar section when prompted, or place it later from **Setup → Plugins**.

## Remove

```bash
omarchy plugin remove com.cuthriell.binnacle
```

That deletes the plugin directory and drops it from your bar layout. Binnacle writes no
files outside its own directory, so nothing else needs cleaning up.

To disable it without uninstalling:

```bash
omarchy plugin disable com.cuthriell.binnacle
```

## Requirements

Required: Omarchy 4 (Quickshell shell), `bash`, `grep`, `df`. All present on a stock
install.

Optional, and absent gracefully:

| Tool | Used for | Without it |
|---|---|---|
| `lspci` | human-readable GPU names | falls back to `Intel integrated graphics` etc. |
| `nvidia-smi` | NVIDIA load, temperature, VRAM | no discrete-GPU instrument is created |
| cgroup v2 with the `cpu` controller | the CPU-by-program leaderboard | leaderboard section is omitted |
| `btop` | the **Open btop** button | button still shown; launch does nothing |

## Settings

Configurable from **Setup → Plugins**, or inline on the widget's `shell.json` entry.

Each instrument can be placed independently:

- **Bar + panel** — drawn in the bar strip and in the dropdown
- **Panel only** — kept out of the strip, still in the dropdown
- **Hidden** — not collected for display at all

Covering CPU, integrated GPU, discrete GPU, temperatures, memory, network and
filesystems. If every instrument is demoted the widget still renders a single glyph, so
the panel stays reachable.

Other settings: sample interval, history length per graph, graph width, icon size,
network graph floor, temperature dial floor and ceiling, and the leaderboard window.

## How it works

`binnacle-collect` runs once at startup to discover what the machine has, then streams
one JSON line per interval on stdout. The QML reads it with a `SplitParser`. Discovery
costs are paid once; a steady-state tick executes no external programs at all.

Expensive sources are handled by measurement rather than assumption: each thermal sensor
is timed at discovery and anything slow gets its own slower cadence — on the development
machine the NVMe composite sensor costs 7.3 ms per read against 0.4 ms for coretemp,
because it issues a SMART command to the drive.

To see what Binnacle found on your machine:

```bash
~/.config/omarchy/plugins/com.cuthriell.binnacle/binnacle-collect --discover
```

## Privileges

None. Binnacle requires no root, installs no sudoers policy, ships no compiled binaries,
makes no network connections, and writes no files outside its own directory.

## License

MIT — see [LICENSE](LICENSE).
