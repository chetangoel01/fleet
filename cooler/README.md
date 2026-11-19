# Cooler

The fan controller Fleet carries. It runs as root in the background on an **Apple silicon Mac with fans, M1 through M6**, keeps a low airflow floor and raises the fans according to the hottest CPU, GPU or palm-rest reading. It picks the sensor and fan keys for the chip it runs on, and refuses to control the fans on a chip it has no sensor map for (an M7, an Intel Mac) or a Mac without fans, because writing fan speeds with the wrong keys can do harm.

It is Swift and IOKit, with no network access and nothing else to install. Fleet's menu and window are its only controls: the Fan Profile rows switch profiles and the window's curve editor shapes a custom one (see the main [README](../README.md)).

Cooler was its own project until November 18, 2026 ([chetangoel01/cooler](https://github.com/chetangoel01/cooler)), with a SwiftBar menu and an app of its own. The controller, its root scripts and its replay test moved here unchanged from that repository's commit `9c757b1`; the evidence files this page names (`artifacts/…`) and the tests that did not move stay there.

## What is where

| In this folder | What it is |
|---|---|
| `main.swift`, `Control.swift`, `Hardware.swift`, `SMC.swift` | The controller, built as `Fleet.app/Contents/Helpers/cooler` |
| `Cooler/` | What ships in `Fleet.app/Contents/Resources/Cooler`: the installer, the profile script, the uninstaller, the sudo rule, the launchd job, the default profile, `version` and the on-device check |
| `e2e.py`, `probes/` | The replay test and the saved probes of three Macs it maps |

Installed, the controller lives outside the app, so it keeps running whatever happens to Fleet:

- `/Library/Application Support/Cooler/`: `cooler`, `config.json` (the profile in force), `status.json`, `apply-profile`, `uninstall.sh`, `version`
- `/Library/LaunchDaemons/com.chetangoel.cooler.plist`, the job `system/com.chetangoel.cooler`
- `/etc/sudoers.d/cooler`
- `~/Library/Application Support/Cooler/custom.json`, the curve Fleet's editor last applied
- `/var/log/cooler.log`

## Install, update, remove

Installing needs an administrator password, and Fleet's cask never asks for one, so the cask installs no controller. Fleet offers it instead:

- **Install Fan Control…** among a Mac's actions, when Cooler is not installed and the controller's own read-only check (`cooler check`) says it can run this Mac's fans.
- **Update Fan Control…**, when the installed controller's `version` file differs from the one in the app. `Cooler/version` is raised by hand whenever anything under `cooler/` that gets installed changes.

Either row runs `sudo …/Fleet.app/Contents/Resources/Cooler/install.sh` in a Terminal window, over `ssh -t` for another Mac. Run by hand it is:

```sh
sudo /Applications/Fleet.app/Contents/Resources/Cooler/install.sh
```

Quit Macs Fan Control, Stats, TG Pro, smcFanControl and macfan first: the installer refuses while one runs, and the controller yields the fans while one is open. A first install briefly runs every fan at full speed to confirm that macOS lets Cooler control them, before it copies anything, then starts the default Cooler profile. An update keeps the profile in force, keeps Cooler off if Automatic was selected, and skips the full-speed check. It strips the download flag from what it copies, because launchd refuses a daemon file that carries one.

Remove it, returning every fan to macOS:

```sh
sudo '/Library/Application Support/Cooler/uninstall.sh'
```

That keeps `config.json`, `custom.json` and the log. `brew uninstall --cask fleet` does not remove the controller: it goes on running the fans without Fleet, so run the uninstaller first if that is not wanted.

Inspect it:

```sh
cat '/Library/Application Support/Cooler/status.json'
'/Library/Application Support/Cooler/cooler' probe
launchctl print system/com.chetangoel.cooler
tail /var/log/cooler.log
```

Status carries the PID that wrote it and updates every two seconds. The log records mode changes and failures, not continuous readings.

## Cooling policy

`Cooler/config.json` is the **Cooler** profile, and the default. A profile holds only comfort settings: the baseline, the fall rate and the two curves. Each time it starts, the controller picks the sensor and fan keys for the Mac it runs on. Profiles from earlier versions also name a Mac model and sensor keys; those fields are ignored.

On the M5 Pro:

| CPU or GPU temperature | Left fan | Right fan |
|---|---:|---:|
| 45°C or below | 2,000 RPM | 2,000 RPM |
| 55°C | 2,640 RPM | 2,707 RPM |
| 65°C | 3,920 RPM | 4,122 RPM |
| 75°C | 6,160 RPM | 6,597 RPM |
| 85°C or above | 8,400 RPM | 9,072 RPM |

Speeds are fractions of each fan's range above the floor: the higher of the profile's baseline (1,800 RPM) and the fan's hardware minimum (2,000 RPM on the M5 Pro, 1,000 RPM on the M6 Mac mini). The palm-rest curve independently requests 0% of that range at 30°C, 20% at 33°C, 50% at 36°C and 100% at 40°C; desktops have no palm-rest sensors, so only the CPU and GPU curve applies there. The highest request wins. Values between points are interpolated. The fans are read every two seconds; increases are immediate and decreases are limited to 40 RPM per second. A gap longer than ten seconds restores automatic mode and requires three healthy samples before resuming.

Fleet's profiles (`FleetMenu.swift` holds their points):

| Profile | Baseline | M5 Pro targets at 75°C, left / right | Full speed by |
|---|---:|---:|---:|
| Quiet | 1,200 RPM | 4,240 / 4,475 RPM | 90°C |
| Balanced | 1,500 RPM | 5,200 / 5,536 RPM | 90°C |
| Cooler | 1,800 RPM | 6,160 / 6,597 RPM | 85°C |

The baselines date from the M1 Max, whose fans could run at 1,200 RPM. The M5 Pro's fans never run below 2,000 RPM, so there all three idle at 2,000 RPM and differ only in their curves. **Max Cooling** asks for every fan's hardware maximum until another profile is chosen. **Automatic** stops and disables the controller, and macOS runs the fans; both choices survive a restart. A custom curve has 2 to 20 points per curve between 10 and 90°C, temperatures rising, demand never falling and the last point at full speed, and a baseline of 1,200 to 2,500 RPM.

The curve fractions were tuned on the M1 Max, whose fans ran 1,200–5,779 / 6,241 RPM. The M5 Pro's span 2,000–8,400 / 9,072 RPM, so the same temperature asks for more speed there. The Mac mini's single fan spans 1,000–4,900 RPM and Apple idles it at 1,000 RPM; Cooler's floor is the baseline, so it is louder at idle there too. Cooler follows the hottest CPU core rather than an average, so it reads higher than tools that average them. Noise and comfort on the M5 Pro and the Mac mini have not been judged.

### Switching profiles

Profile changes run through one root-owned script, `/Library/Application Support/Cooler/apply-profile` (`Cooler/apply-profile.sh`), which Fleet calls with `sudo -n`. The rule in `/etc/sudoers.d/cooler` (`Cooler/sudoers`) lets admin users run exactly `apply-profile automatic` and `apply-profile curve` without a password; the installer checks it with `visudo` before installing it, and the uninstaller removes it. `apply-profile curve` reads `baselineRPM`, `curve` and `palmCurve` on standard input and merges only those into the installed profile, so recovery settings cannot be changed through it. The tradeoff: any process running as an admin user can switch the fan profile silently. It cannot do anything else as root.

A change is validated by the installed controller before control is interrupted. Applying one stops Cooler, restores automatic control, installs the configuration atomically, then enables and starts the service. A failure after stopping restores the earlier configuration and leaves the fans on automatic with Cooler disabled.

## Supported chips and sensors

Cooler reads the chip generation from the CPU brand string (`Apple M1 Max` is an M1) and uses that generation's sensor keys, skipping any the Mac lacks. Each generation's lists join the keys of its base, Pro, Max and Ultra variants, so a Mac needs at least one CPU and one GPU key from them. The palm-rest keys `Ts0P`/`Ts1P` are used where they exist. The fan count comes from `FNum`, and the manual-mode key is `F0md` where it exists, otherwise `F0Md`. A Mac missing any fan's mode, target, minimum, maximum or speed key is refused. `cooler probe` prints the map chosen for the Mac it runs on; `cooler map BRAND PROBE.json` prints the map for a probe saved on another Mac.

| Chip | CPU keys | GPU keys | Evidence |
|---|---|---|---|
| M1 | Stats' 10 | Stats' 4 | The saved M1 Max probe maps to exactly the 10 CPU and 4 GPU keys Cooler used on that Mac, both palm keys, two fans and `F0Md` (checked by `e2e.py`). |
| M2, M3, M4 | Stats' lists | Stats' lists | None on real hardware. The M4 GPU list joins Stats' base-M4 and Pro/Max keys. |
| M5 | Stats' 18 per-core keys | Every `Tg` key | M5 Pro: load-tested and installed. The `Tg` rule is assumed to hold for the base M5 and M5 Max. |
| M6 | Every `Tp0` key | Every `Tg` key | M6 Mac mini: load-tested read-only, then installed November 18, 2026 with all 11 on-device checks passing. Assumed to hold for other M6 variants. |

Cooler first writes the mode key directly, which works on the M1 Max and the M5 Pro. On M3 and M4 Macs macOS's thermal manager holds the fans in its own mode (3) and the SMC refuses mode and target writes ([Stats #2924](https://github.com/exelban/stats/pull/2924), following the [macos-smc-fan research](https://github.com/agoodkind/macos-smc-fan/blob/main/docs/research.md)); M2 is unknown. When the direct write is refused and the Mac has the `Ftst` flag, Cooler does what Stats does: it sets `Ftst` to 1, which makes the thermal manager let go of the fans, and retries the mode write for up to 30 s while still reporting to its watchdog. Restoring automatic control sets each fan's mode back to 0 and then clears `Ftst`. Sleep resets `Ftst`, so after wake Cooler unlocks the fans again. **This fallback is untested on real hardware:** no Mac Cooler has run on has `Ftst`. If the unlock fails, the first install's full-speed check fails before anything is copied, and no controller is installed.

**M5 Pro (Mac17,13).** Every SMC key was listed with read-only requests, and the sensors identified by load: every temperature key sampled once a second while 18 busy processes loaded every core, and again while a Metal compute kernel loaded the GPU.

- CPU: the 18 per-core keys Stats lists for the M5. All rose 22–25°C under CPU load, more than any other key.
- GPU: all 42 `Tg` keys, each rising more under GPU load (19–29°C) than under CPU load. Stats' M5 GPU list was written for the base M5: one of its keys does not exist on the M5 Pro, and it leaves out the hottest GPU sensors here.
- Palm rest: `Ts0P`/`Ts1P`, flat under both loads. They do not measure the whole underside and have not been checked by touch.
- Fans: two, 2,000–8,400 RPM (left) and 2,000–9,072 RPM (right), mode keys `F0md`/`F1md`, no `Ftst`. Under Apple's control at idle macOS stops both fans, so an idle Mac is audibly louder with Cooler than without it.

**M6 Mac mini (Mac18,5).** `cooler probe` found 147 readable temperature and fan keys, none of them palm-rest keys, and every temperature key was sampled for four minutes over ssh through idle, CPU load and GPU load.

- GPU: all 18 `Tg` keys rose 24–29°C under GPU load.
- CPU: all 21 `Tp0` keys rose 12–19°C under CPU load, more than the whole chip did. The GPU load warmed them as much, so the split is approximate; both groups drive the same curve.
- Fan: one, 1,000–4,900 RPM, mode key `F0md`.

**M1 Max (MacBookPro18,4).** Its four `Tg` keys all read 9.2° on November 18, 2026, which cannot be a temperature; the CPU keys drive the curve there. Not looked into.

See [source attribution](THIRD_PARTY_NOTICES.md).

## Recovery and limits

Only each fan's mode key and target key can be written, plus `Ftst` on a Mac that refuses a direct mode write and has it. Hardware RPM limits are respected. No firmware changes, kernel extensions or changes to macOS thermal services are used.

Missing or invalid sensors, invalid fan limits, critical macOS thermal pressure and failed or partial writes trigger automatic control. Every fan must be restored successfully; otherwise the controller exits and its watchdog retries. Three healthy samples are needed before recovery. Startup also restores automatic mode before applying a curve. Restoration leaves a fan already in automatic (0) or system (3) mode alone, sets any other fan to 0 and verifies it, then clears `Ftst` if it is set; `cooler auto` does the same.

An independent watchdog watches a pipe from the controller. If the controller exits or stalls for ten awake seconds, the watchdog restores automatic control, killing a stalled controller first to prevent competing writes. launchd restarts failed processes. If the watchdog itself exits, the controller restores automatic mode and exits. Duplicate controllers are rejected by an exclusive lock.

launchd runs Cooler as an **Interactive** process. As a standard daemon it ran at utility priority with throttled I/O, and on the M1 Max on September 26, 2026, sustained heavy load (CPU 99–107°C) starved it past the ten-second limit nine times in two hours. Each time the fans returned to automatic control and launchd restarted Cooler. The fix was never confirmed under comparable heat.

**The lid.** Closing the lid hands the fans back to macOS, which stops them while the Mac sleeps; opening it resumes the curve after three healthy samples. A closed lid counts only when macOS reports that it will put the Mac to sleep (`AppleClamshellCausesSleep`). In clamshell mode, docked to a display, macOS reports that it will not, and the curve keeps running. A Mac with sleep switched off altogether (`pmset disablesleep`, shown as `SleepDisabled`) also keeps the curve: macOS goes on reporting that its closed lid will sleep it, but it stays awake. Amphetamine sets this for a closed-display session, which is how the M1 Max runs as a server with its lid shut. Before these rules Cooler either left the fans in manual mode through sleep or handed them to macOS for hours while the Mac stayed awake with its lid shut. Desktops have no lid. During a brief wake-up while macOS still reports that the closed lid will not sleep the Mac, the wake-up reads as a gap: Cooler hands the fans back, takes them again after three healthy samples, and can leave them in manual mode when the Mac sleeps again.

On the M1 Max a fan that has just been handed to macOS and told to stop can take ten seconds or more to restart: after each of several profile switches on November 18, 2026 one fan read 0 RPM at eight seconds and was back on its target within about fifteen. Not explained.

On a chip without a sensor map the controller exits at startup and launchd restarts it every few seconds, as happened when Migration Assistant moved the M1 Max installation to the M5 Pro; the fans stay under Apple's control. The installer's check prevents this, but a migrated installation skips it, so run the uninstaller there.

These are software recovery measures, not firmware guarantees. Killing both processes at once can leave the last manual setting until launchd restarts the service. A whole-system hang or an SMC failure cannot be recovered by this process.

## Verification

```sh
./build.sh && python3 cooler/e2e.py                                                  # from the repository root: 36 replay checks, no hardware touched
sudo /usr/bin/python3 /Applications/Fleet.app/Contents/Resources/Cooler/live.py     # 11 checks on the installed controller
```

`e2e.py` drives the built controller with simulated sensor and fan input, through the same decision and write code as the daemon. It covers CPU-only and GPU-only heat, warm palms, the baseline, immediate increases, gradual decreases, missing and invalid sensors, three-sample recovery, conflicts with other fan tools, partial writes, wake gaps, the lid closing, staying closed through a wake and reopening, invalid hardware limits and malformed configuration. It maps the saved probes of three Macs (M1 Max, M5 Pro, M6 Mac mini) with `cooler map`, and covers a listed key missing on one variant, a desktop without palm sensors, chips without a sensor map, a Mac without fans, a Mac missing a fan key Cooler writes, one-fan control and restoration, and profiles from earlier versions. Whether a closed lid is putting the Mac to sleep is decided in the lid read, which replay cannot reach.

`live.py` needs root and a curve in force, and interrupts the running service for about a minute. It checks that every fan is in manual mode on a bounded target and physically spinning, then normal termination, a forced crash, a stalled controller and the loss of the watchdog, each of which must restore automatic control and recover, then a stop, a restart and the installed files' permissions. A failure stops Cooler and tries to restore automatic control. Run it only when Cooler is the sole fan controller, and not with the lid shut on a Mac that the lid puts to sleep. Its report is `/var/log/cooler-live-report.json`.

Not moved from the Cooler repository: `lifecycle.py` (the watchdog under real signals, logging in place of fan writes), `profiles.py` (the profile script against simulated launchd, which covers `apply-profile.sh` as it is here, unchanged) and `cadence.py` (the installed service's timing under load). The installer here differs from the one those tests covered: it installs a `version` file and takes its files from the app.

### On real Macs

- **M5 Pro.** Installed from source on November 7, 2026 and again on November 10 with the clamshell rule, docked with the lid shut: all 11 on-device checks passed each time. A real lid close on November 7 handed both fans to macOS one second after the lid closed and resumed the curve four seconds after it opened.
- **M6 Mac mini.** First installed November 18, 2026: all 11 checks passed. The full-speed check took the fan to 5,018 RPM against a 4,900 maximum; under the curve it idles at 1,800 RPM.
- **M1 Max, lid shut with sleep disabled.** Installed November 18, 2026. The first run of the checks stopped at "every fan is physically spinning" because of the slow restart described above; run again later that evening with the curve already on, all 11 passed.
- Not verified on any Mac: sleep and wake with the fans handed over, a full reboot, the `Ftst` fallback, and everyday noise and comfort.
