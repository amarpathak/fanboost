# FanBoost 🌀

A tiny menu bar app that spins up your Mac's fans *before* it gets hot, tells you
**what** heated it up, and can cap battery charging to keep the battery healthy.

When an Intel MacBook overheats, macOS throttles it, and you'll see `kernel_task` eating
100–300% CPU in Activity Monitor. That's macOS deliberately taking CPU time so other apps
slow down and the chip cools. macOS is also slow to ramp up the fans. FanBoost runs them at
full speed sooner, so the Mac rarely gets hot enough to throttle.

The menu bar shows CPU temperature and fan speed: `🌀 58° 1800` (🌪 while boosting).
**Click** it for the dashboard; **right-click** for a quick menu.

## Dashboard

- CPU temperature and fan speed for the last 10 minutes, with boost periods shaded
- What's using the CPU right now (smoothed over ~10 seconds, grouped by app)
- Heat boosts: what caused each one and how long it lasted
- Battery charge, health, cycle count and temperature
- Fan mode and charge limit controls

FanBoost itself uses about 0.3% CPU: it reads the sensors in-process, and only measures
per-app CPU while the dashboard is open or the Mac is heating up.

## Modes

| Mode | What it does |
|---|---|
| **Smart** (default) | macOS controls the fans until the CPU stays at **65°C or above for 3 seconds**, then max fans until it drops below **58°C** |
| Auto | Plain macOS behaviour |
| Medium / High | Fixed 50% / 75% fan speed, but still goes to max under the same rule |
| Max | Fans at full speed |

Quitting FanBoost always hands the fans back to macOS. A reboot also resets them.

## Who's heating my Mac?

Every time FanBoost boosts, it notes the process using the most CPU at that moment
(ignoring `kernel_task`, which is the symptom, not the cause). The menu shows
`🔥 Boosted 4× today · mostly Google Chrome Helper (GPU)` and a **Recent boosts** list.
The log keeps 2 days of boosts; older entries are deleted automatically.

## Charge limit

Keeping a laptop at 100% on the charger wears the battery faster. Pick **80%** or **90%**
under *Charge limit* and FanBoost stops charging there.

- **Intel:** uses the Mac's built-in charge-limit setting (`BCLM`). The Mac holds the level
  you choose and runs off the charger. macOS resets it on reboot; FanBoost reapplies it at login.
  macOS's own battery menu may still say "charging" while the limit holds the level;
  FanBoost reads the actual charging current and shows *held by 80% limit*.
- **Apple Silicon (experimental):** there's no built-in limit, so FanBoost pauses charging
  at the limit and resumes 5 points below. Quitting FanBoost always turns charging back on.

## Install

Requires macOS 13 (Ventura) or later.

1. Download **FanBoost-x.y.z.pkg** from the [latest release](https://github.com/amarpathak/fanboost/releases/latest).
2. Double-click it. The first time, macOS says *"Apple could not verify…"* because the
   package isn't signed with a paid Apple Developer ID. Open **System Settings → Privacy &
   Security**, scroll down, click **Open Anyway**, then open the package again.
3. Click through the installer and enter your password. FanBoost appears in the menu bar.

Uninstall: `sudo fanboost-uninstall` in Terminal.

### From source

Requires macOS 13 or later and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/amarpathak/fanboost.git
cd fanboost
sudo ./install.sh      # or ./package.sh to build dist/FanBoost-<version>.pkg
```

Either way, the installer:
- builds the app,
- installs `fanctl` to `/usr/local/bin` (owned by root),
- adds `/etc/sudoers.d/fanboost`, which lets **your user only** run `fanctl` as root without a password
  (changing fan speed needs root),
- copies `FanBoost.app` to `/Applications` and starts it at login.

## Command line

```sh
fanctl status           # temperature and fans, no root needed
sudo fanctl max         # all fans to max
sudo fanctl set 60      # all fans to 60% of their range
sudo fanctl auto        # give control back to macOS
sudo fanctl limit 80    # Intel: hardware charge limit (100 = off)
sudo fanctl charging off|on   # Apple Silicon: pause/resume charging
```

`fanctl` itself has no safety logic; `fanctl set 0` while the CPU is hot is your call.
The app's Medium and High modes always fall back to max when hot.

## Limitations

- **Apple Silicon support is experimental and untested.** It's built from community
  documentation of the M1–M4 SMC keys (`Tp*/Te*` temperatures, the `Ftst` fan unlock,
  `CHTE`/`CH0B` charge control). If something doesn't work on your M-series Mac, please open
  an issue with your model and the output of `fanctl status`.
- Fans can't go faster than their hardware maximum. If something is pegging your CPU,
  find it in Activity Monitor (sort by CPU). FanBoost cools, it doesn't fix runaway processes.
- Tested on a MacBookPro16,1 (16" 2019) running macOS 26. Other Intel models should work;
  if the temperature shows `--`, please open an issue with your model (`sysctl hw.model`).

## How it works

`smc.c` talks to the `AppleSMC` kernel driver through IOKit, and `sensors.c` reads CPU
temperature (`TCXC`/`TC0P` on Intel, the hottest `Tp*`/`Te*`/`Tf*` sensor on Apple Silicon),
fan speeds (`F<n>Ac/Mn/Mx`) and battery state. The app links that C code directly for reads;
`fanctl` (run via `sudo`) does the writes: `F<n>Md` (manual mode), `F<n>Tg` (target RPM),
`BCLM` (charge limit). The app is AppKit + SwiftUI/Swift Charts, built as universal binaries.

## Disclaimer

This software overrides your Mac's fan control. It only ever *raises* fan speed on its own,
but you use it at your own risk; see [LICENSE](LICENSE) (MIT, no warranty).
Not affiliated with or endorsed by Apple.
