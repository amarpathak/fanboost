# FanBoost 🌀

A tiny menu bar app that spins up your **Intel Mac's** fans *before* it gets hot.

When an Intel MacBook overheats, macOS throttles it, and you'll see `kernel_task` eating
100–300% CPU in Activity Monitor. That's macOS deliberately taking CPU time so other apps
slow down and the chip cools. macOS is also slow to ramp up the fans. FanBoost runs them at
full speed sooner, so the Mac rarely gets hot enough to throttle.

The menu bar shows CPU temperature and fan speed: `🌀 58° 1840` (🌪 while boosting).

## Modes

| Mode | What it does |
|---|---|
| **Smart** (default) | macOS controls the fans until the CPU stays at **65°C or above for 3 seconds**, then max fans until it drops below **58°C** |
| Auto | Plain macOS behaviour |
| Medium / High | Fixed 50% / 75% fan speed, but still goes to max under the same rule |
| Max | Fans at full speed |

Quitting FanBoost always hands the fans back to macOS. A reboot also resets them.

## Install

Requires an Intel Mac and the Xcode Command Line Tools (`xcode-select --install`).

```sh
git clone https://github.com/amarpathak/fanboost.git
cd fanboost
sudo ./install.sh
```

The installer:
- builds the app,
- installs `fanctl` to `/usr/local/bin` (owned by root),
- adds `/etc/sudoers.d/fanboost`, which lets **your user only** run `fanctl` as root without a password
  (changing fan speed needs root),
- copies `FanBoost.app` to `/Applications` and starts it at login.

Uninstall: `sudo ./uninstall.sh`

## Command line

```sh
fanctl status           # temperature and fans, no root needed
sudo fanctl max         # all fans to max
sudo fanctl set 60      # all fans to 60% of their range
sudo fanctl auto        # give control back to macOS
```

`fanctl` itself has no safety logic; `fanctl set 0` while the CPU is hot is your call.
The app's Medium and High modes always fall back to max when hot.

## Limitations

- **Intel Macs only.** Apple Silicon fan control uses different SMC keys and isn't supported.
- Fans can't go faster than their hardware maximum. If something is pegging your CPU,
  find it in Activity Monitor (sort by CPU). FanBoost cools, it doesn't fix runaway processes.
- Tested on a MacBookPro16,1 (16" 2019) running macOS 26. Other Intel models should work;
  if the temperature shows `--`, please open an issue with your model (`sysctl hw.model`).

## How it works

`smc.c` talks to the `AppleSMC` kernel driver through IOKit, reading `TCXC`/`TC0P` (CPU temp)
and `F<n>Ac/Mn/Mx` (fan actual/min/max), and writing `F<n>Md` (manual mode) and `F<n>Tg`
(target RPM). `FanBoost.swift` is a ~150-line AppKit menu bar app that polls `fanctl status`
every 3 seconds.

## Disclaimer

This software overrides your Mac's fan control. It only ever *raises* fan speed on its own,
but you use it at your own risk; see [LICENSE](LICENSE) (MIT, no warranty).
Not affiliated with or endorsed by Apple.
