# Fleet

Two programs:

- **fleetd**, a small background program that answers one question about the Mac it runs on: how is this machine doing?
- **Fleet.app**, a menu bar item that asks fleetd and shows the answer.

The helper is inside the app (`Fleet.app/Contents/Helpers/fleetd`), so one Homebrew cask installs both on every Mac.

## Install and update

```sh
brew install --cask chetangoel01/tap/fleet
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.chetangoel.fleetd.plist    # first install only: start the helper now
brew upgrade --cask fleet                                                              # later: update, on each Mac
```

- The cask puts `Fleet.app` in `/Applications` and writes `~/Library/LaunchAgents/com.chetangoel.fleetd.plist`, a per-user launchd job that runs the helper at login and restarts it if it crashes. Nothing asks for a password.
- Homebrew's install steps run in a sandbox that cannot talk to launchd, so the first install cannot start the helper: the `launchctl bootstrap` line does, and so does logging out and in.
- The first time the helper starts on a Mac, macOS asks on that Mac's screen whether to open Fleet, because it was downloaded, and holds the helper until someone clicks Open. On a Mac with nobody at it, do that click over Screen Sharing. While its screen is locked the prompt waits behind the lock and the helper does not answer.
- An upgrade needs neither step. Homebrew marks the new copy as approved when the old one was and both are signed by the same developer. The running helper checks every 20 seconds whether its file has been replaced, waits until that mark is on the new copy, and leaves; launchd then starts the new one. `brew reinstall`, and an uninstall followed by an install, count as first installs, so the prompt comes back.
- `brew uninstall --cask fleet` sends the helper an interrupt, which it answers by leaving with 0 so that launchd does not start it again, and removes the launchd file.
- On the Mac that should show the menu bar item, open Fleet once and choose **Open at Login** in its menu. The other Macs only need the helper.
- The app is signed with a Developer ID and notarized. It is built for Apple silicon and macOS 15 or later, and has only been run on macOS 27.
- `./check.sh` asks all three helpers and prints the release each runs and any reading it could not take.

The Macs it reads are named in `machines` in `FleetMenu.swift` (m1-server, mini and m5-macbook, by their Tailscale names), so on another set of Macs that list is the thing to change.

## Menu bar item

`Fleet.app` is built from `FleetMenu.swift` and `FleetWindow.swift`. A server-rack icon appears in the menu bar. **Open at Login** in its menu registers the app as a login item with macOS (`SMAppService`); the circle before the row is ticked while it is on.

The layout follows the mockup agreed on 2026-11-18:

- **Top of the menu:** anything needing attention, each with a red or orange dot: a container that is not running, Docker not answering, fewer than 15% of vnodes free, open files above 80% of the limit, a drive under 25 GB or 10% free (a Time Machine drive is left out, since it fills up by design), m1-server running on battery, an automatic Time Machine backup more than 2 days old, and this Mac's or m1-server's helper not answering. The count sits beside the menu bar icon in orange. A reading that is worth a glance but not a count is coloured orange where it already sits: CPU at 90° or above, memory under 10% free, a background job whose last exit was not 0. Everything else is plain. The limits are in `problems` and `details` in `FleetMenu.swift`.
- **Machines:** m1-server, mini and m5-macbook, each with a status dot and its battery and power. A Mac's flyout has battery, power, CPU (how busy, temperature, fans), memory, swap, network (down and up, with the connection and address in the tooltip), the busiest process, what keeps it awake, uptime, its drives and the last Time Machine backup. A reading the Mac does not have is left out. mini is often asleep, so when it does not answer its dot goes grey and nothing else changes (`sleeps` in `machines`).
- **Services:** every container, with a dot and its address. Clicking one opens `http://<mac>:<port>` in the browser; this applies to other Macs only. A stopped container adds a "Find Out Why … Stopped…" row.
- **Downloads:** shown while qBittorrent on m1-server has unfinished downloads, with percent and time left for each and the total speed on the row.
- **Scheduled jobs:** the jobs the Claude and Codex apps have switched on, grouped by app and Mac, then background (launchd) jobs whose last exit was not 0. Claude's jobs show when they last ran, with the schedule as the tooltip; Codex records no last run, so its jobs show the schedule. Each Mac's list is its own: the apps keep these files per Mac.
- **Actions** carry an icon. A speech bubble opens a new Code session in the Claude app (`claude://code/new?q=…`) with a prompt typed in and not sent: Clean Up Disk…, Free Up Memory…, Sync Assistant Setup…, Find Out Why … Stopped…. Every prompt tells Claude to report first and change nothing until you pick. A terminal icon runs a command in a Terminal window through an interactive login shell, wrapped in `ssh -t` for another Mac (`onMac`): Upgrade N Brew Packages runs `brew update && brew upgrade`, Back Up Now (on a Mac with automatic Time Machine backups) runs `tmutil startbackup`, Start *name* (for a container that is not running) runs `docker start`, and Open Terminal opens an ssh session. The Terminal window is always on this Mac, so its first line says which Mac the command is running on ("On mini, over ssh from this Mac"). Share Screen opens `vnc://<mac>` in Screen Sharing. A square with an arrow opens the browser. Sync Assistant Setup…, Open Fleet Window, Open at Login and Quit Fleet are the last rows of the main menu.

How it behaves:

- The menu opens at once, on the last readings. Opening it asks every helper again; until a Mac answers, its values are dimmed, and each answer updates the open menu in place, so a flyout you have open stays open while its numbers change. When a row is added or removed above it (a warning appearing, say), AppKit closes the flyout. A Mac that does not answer shows "not answering" after 6 seconds.
- The count beside the menu bar icon is how many things needed attention the last time the menu was opened. Nothing runs between opens, so it does not change by itself.
- It has no timers. It fetches when it starts and each time the menu opens, so the icon reflects the last time you opened it, not the present.
- Every menu is the same width (`textWidth` in `FleetMenu.swift`, about 300 points on screen). A name or value that does not fit is cut with "…" and shown whole in the tooltip; a value gets at least half the row and whatever the name leaves.
- A row's dot or icon is set in the row's own text (`inText`), not as the menu item's image. With an image on any row, AppKit keeps an image column for every row of that menu, which left readings indented under nothing, or the menu 22 points wider. A row without a dot or icon starts at the menu's edge; values still end in one column. Icons go in as symbols, so they take the text's colour (white on the highlighted row, checked on screen 2026-11-18).
- In the mockup and not built: the Raspberry Pi row, the VPN row, files-differ counts under Assistant setup, next-run times, and "Updated … ago" (the menu reads fresh on every open). Notifications are not built either.

Check what the menu would show without opening it:

```sh
B=/Applications/Fleet.app/Contents/MacOS/Fleet
$B --dump                                              # the menu as text from a live fetch: dots, icons, what each action does, the widest menu in points and how long the menus took to build
$B --dump samples/downloads-and-low-vnodes.json        # the menu a saved status gives: three downloads and a vnode warning
$B --dump samples/server-on-battery.json               # on battery, a 4-day-old backup, a stopped container, a hot CPU and low memory
$B --open                                              # run a second copy with its menu open, for looking at it on screen
```

A saved status is one helper's `/status` document, so any state that is rare live can be checked by editing a copy.

## Window

**Open Fleet Window** in the menu opens a window on the same answers, with room for every reading. Built 2026-11-18 (`FleetWindow.swift`, SwiftUI inside the same app).

- **Overview:** anything needing attention, then a card per Mac with its picture, battery and power, CPU, memory and the drive closest to full (Time Machine drives aside), then every container side by side and, while there are any, the downloads. Clicking a card opens that Mac's page.
- **A page per Mac**, redesigned 2026-11-18 after "a lot is left to be desired". Nothing is folded any more. From the top:
  - picture, name, model, macOS version and uptime;
  - a button for everything that can be done to that Mac, each with an icon: Start *name* for a container that is not running, Share Screen, Open Terminal, Back Up Now, Clean Up Disk…, Free Up Memory…, Upgrade N Brew Packages;
  - that Mac's own warnings;
  - a tile per live reading with one large figure: **Battery** (ring, with "plugged in" and the watts beside it), **CPU** (percent busy, one bar per core, temperature and fans; at 90° or above the temperature leads, in orange), **Memory** (ring of what is in use, swap), **Network** (down and up). A figure past its limit is orange, and so is its ring;
  - **Last 3 hours:** four graphs, a point a minute: CPU, memory free, download and upload. Each has its own scale; the pointer over a graph shows the time and value under it. The line is broken where the helper has no points, because the Mac slept or the helper started later than the graph does. The graph ends at the helper's clock, not this Mac's;
  - **Storage:** a tile per drive with free space, a bar and, on the Time Machine drive, the last backup;
  - **Containers** side by side. Clicking a name opens that service in the browser, where it has an address (the tooltip shows it). The "…" at the end of each row, and a right-click, give Open in Browser, Restart (or Start) and Show Logs; the last two run `docker` on that Mac in a Terminal window;
  - **Scheduled jobs**;
  - **Network:** the connection (Wi-Fi or the adapter's name, and its interface), local address, Tailscale address, and how this Mac reaches that one over Tailscale (direct, or through which relay). This Mac's page lists the tailnet devices that are online;
  - **Details:** busiest process, what keeps it awake, open files, free vnodes.
- **The rings and bars show one moment**, drawn from the answer on screen. The graphs over time come from the helper's `history`, the one reading taken on a schedule (see *What it does*). Asked for on 2026-11-18 ("some history would be good"), which reversed the original no-timers rule for the helper; the app still has none.
- **Sidebar counts:** Services shows how many containers are stopped, Downloads how many are running, Scheduled jobs how many background jobs failed. No count means nothing to look at.
- **Services, Downloads, Scheduled jobs:** the same lists as the menu's flyouts (`Rows` draws the menu's own rows, so the two cannot disagree).
- **Pictures** are macOS's own. The helper reports the model code and, where the Mac records one, its case colour; `deviceType` asks macOS for the device type of `model@ECOLOR=colour` (the tag its own device pictures are keyed by) and falls back to the model alone, then to a generic Mac. Nothing is kept per model here.
- **No timers here either.** The helpers are asked when the window opens, when it comes to the front (unless they were asked in the last 5 seconds, since the helper would send the same snapshot) and on Refresh (Command-R). The title bar says "As of" a clock time, so a window left open shows how old its numbers are.
- A Mac asked again and not yet heard from is drawn at half strength, but only if it takes longer than half a second: a quick answer changes the numbers and nothing else. One that has not answered shows a generic picture and "not answering".
- **Motion** is limited to what explains a change: a number that changed rolls to its new value, a ring, a drive's bar and the core bars move to theirs, the cards move down for a warning that arrives, and the Refresh arrow turns once when pressed. Cards and rows that open something tint under the pointer and give slightly when pressed; with Reduce Motion on they only tint. Changing page animates nothing.
- The app has no Dock icon, so the window is not in Command-Tab. Command-W closes it; the menu row brings it back, and so does opening Fleet again from Spotlight or Finder (`open -a Fleet`).
- With the window open and idle the app uses no CPU (no CPU time added over 30 seconds, once the first 15 seconds after opening have passed; 2026-11-18) and about 130 MB of memory; the menu bar item alone is about 94 MB (measured again on the final build of the redesign).

Check it without clicking anything:

```sh
B=build/Fleet.app/Contents/MacOS/Fleet
$B --window overview > /tmp/n & sleep 3            # pages: overview, services, downloads, scheduled, or a Mac's name
screencapture -x -o -l "$(head -1 /tmp/n)" overview.png; kill %1
$B --status samples/server-on-battery.json --window "saved status"    # the window drawn from a saved status in place of the three Macs
$B --window m1-server --height 1100 > /tmp/n &     # a window that tall, to capture a long page whole; its size is not remembered
```

`--window` prints the window's number, which `screencapture -l` uses to capture that window alone. The two captures in `screenshots/` are the page and the overview a saved status with warnings gives (`samples/server-on-battery.json`, whose history has a 35-minute gap and whose backup drive is nearly full, to show the broken line and that the drive raises no warning). The samples are real statuses with the private names replaced. The time and value shown under the pointer have not been seen on screen: the one attempt, with the window behind others, showed nothing, and the check cannot bring the window to the front without taking over the Mac. A window narrowed to 640 points was checked too, with the graphs in it: the tiles go two across, the buttons wrap and the graphs stack one to a row with their scales intact. Opening, closing and reopening was checked three times in a row with `open build/Fleet.app` and the window's close button.

# fleetd

It is an ordinary program, not an AI agent. It uses no model and no tokens.

Its source is `fleetd/main.swift`.

## What it does

- Listens on `127.0.0.1:4790` only, and needs no firewall exception and no sudo. By itself nothing off the Mac can reach it.
- Answers `GET /status` with one JSON document. Any other request gets a 404, and so does a request whose `Host` header names anything but `127.0.0.1`, `localhost` or this Mac's own name (bare or under `.ts.net`), so a web page that points another name at the helper gets nothing.
- Reads nothing until asked, with one exception: a timer reads the processor and network counters every 20 seconds (two system calls, no tool started) and keeps a point a minute for three hours, in memory, for the window's graphs. A restarted helper starts with no history, and a Mac that slept has a gap.
- Takes no commands. There is nothing to run or change through it. What it runs is fixed: `launchctl list`, `ps`, `tailscale status --json` and, where installed, `cooler probe` and `brew outdated`. On a Mac with a running `qbittorrent` container it also runs one fixed command inside that container per status (a `wget` of qBittorrent's own download list), because qBittorrent answers without a password only from inside its container.

It does not push changes or send notifications.

## Reaching the other Macs

Chosen 2026-11-18: Tailscale forwards a tailnet-only port to the helper on m1-server and mini, so the menu on m5-macbook reads them without ssh. Set up once on each of those two Macs (the setting survives restarts):

```sh
tailscale serve --bg --tcp 4791 tcp://127.0.0.1:4790     # m1-server: /Applications/Tailscale.app/Contents/MacOS/Tailscale
tailscale serve status                                   # what is forwarded
tailscale serve --tcp 4791 off                           # stop forwarding
```

- The forward is on 4791, not 4790: with Tailscale holding 4790 on the tailnet address the helper cannot open its own port ("Address already in use") and never starts.
- Every device on the tailnet can read `http://m1-server:4791/status` and `http://mini:4791/status`, not only the MacBook. The document holds each Mac's model, case colour and macOS version, its local network address, Tailscale address and connection name, the names of the tailnet devices that are online, the last three hours of its CPU, memory and network use, process, container and drive names, the names of scheduled Claude and Codex jobs, the names of unfinished downloads on m1-server, and the other readings below; it takes no commands. The local network and the internet cannot reach it.
- m5-macbook has no forward, so nothing else can read it. A menu on another Mac would show it as not answering until it gets the same forward.

## Readings

| Key | What it holds | How it is read |
| --- | --- | --- |
| `disks` | Free and total GB for each local volume | Volume attributes, in-process, 3 s limit |
| `memory` | Free memory percentage, swap used and total | `sysctl`, in-process |
| `files` | Open files across the whole Mac and the kernel's limit; free vnodes and their limit (the limit m1-server actually ran out of on 2026-11-18) | `sysctl`, in-process |
| `power` | Battery percentage and charging (laptops), adapter input in watts | IOKit registry, in-process |
| `containers` | Each container's name, state, status and published ports | Docker's Unix socket, in-process, 3 s limit |
| `downloads` | Unfinished qBittorrent downloads: name, percent, bytes per second, seconds left | One `wget` run inside the `qbittorrent` container through Docker's socket, 2 s limit per step; `none` without that container |
| `schedules` | Jobs the Claude and Codex apps have switched on: app, name, schedule as the app wrote it, Claude's last run, a one-off's time. No prompts, folders or session ids | Claude's `scheduled-tasks.json` (under `~/Library/Application Support/Claude/claude-code-sessions/`) and Codex's `~/.codex/automations/*/automation.toml`, in-process. Both are undocumented app files; one that cannot be read is skipped |
| `cpu` | How busy the processor is, overall and per core, and the seconds that covers | Kernel tick counts (`host_processor_info`), in-process: the change since the history timer's count from 8 to 32 seconds before. Just after a start or a sleep there is no such count, and two counts 0.1 s apart are taken instead |
| `network` | Bytes a second down and up over the same span, the connection the Mac's traffic leaves by (interface, its name such as "Wi-Fi", its address) and the Tailscale address | Interface byte counters (`getifaddrs`) and the system's network settings, in-process |
| `tailnet` | The tailnet devices that are online: name, whether this Mac reaches each directly or through a relay (and which), whether it is in use | `tailscale status --json`, 3 s limit; `none` without Tailscale. Phones and tablets, which report no name, are left out |
| `history` | The last three hours, a point a minute: time, CPU percent, memory free percent, bytes a second down and up. Up to 180 points, about 6 KB | The same counters as `cpu` and `network`, read by a timer every 20 seconds and added up over each minute; `kern.memorystatus_level` at the minute's end. A count more than 45 s after the one before (the Mac slept) starts a new minute and leaves a gap |
| `hardware` | Model code, case colour number (absent on a Mac that records none, such as the mini) and macOS version | `hw.model`, `housing-color` under `IODeviceTree:/chosen`, and the process's own OS version, all in-process |
| `jobs` | Non-Apple launchd jobs whose last exit was not 0 | `launchctl list` |
| `busiest` | The process using the most CPU and the one using the most memory | `ps` |
| `awake` | Processes holding the Mac awake, with the reason each gave | IOKit power assertions, in-process |
| `thermal` | CPU temperature and fan speeds, on Macs with Cooler installed | Cooler's status file while its fan curve is running (fan speeds are then its targets), otherwise `cooler probe` |
| `time_machine` | Time of the latest completed backup, whether automatic backups are on, destination names | Time Machine's preferences, read in-process through the preferences system (`tmutil latestbackup` and the file itself need Full Disk Access, which a launchd job lacks) |
| `brew` | Outdated Homebrew packages, from brew's last fetched data | `brew outdated`, refreshed every 6 hours, and at the next request after Homebrew changes (`brewChanged`: the newest change time among `/opt/homebrew/opt`, each cask's folder and brew's fetched data). Until that read finishes the reading is `pending`, so an upgrade never leaves the old count showing. Checked 2026-11-18 on m5-macbook: one re-read after the fetched data changed, none after. |
| `helper` | Requests served, tools started, CPU seconds used by the helper and by its tools, the helper's own open files | In-process |
| `slow_ms` | Any reading that took 100 ms or more, so a slow status names its cause | In-process |

Every reading has a `state`:

- `ok`: the values are current.
- `none`: this Mac does not have the thing (no Docker, no Time Machine destination, no battery, no Cooler).
- `unknown`: the read failed or ran out of time, with the reason in `error`. A failed read is never reported as zero or as down.
- `pending`: the one slow reading (`brew`) has not finished its first refresh. A request never waits for it.

`watts_in` is adapter input, so on a charging laptop it includes charging.

`thermal` on m1-server depends on Cooler's fan curve running: its Cooler build is older and its `cooler probe` output lacks the sensor list this helper reads, so if the curve stops the reading becomes `unknown` until Cooler is updated there.

`time_machine` matched `tmutil latestbackup` on m1-server on 2026-11-18. Whether a helper that has been running for days picks up a new backup without a restart has not been observed yet.

Requests less than 5 seconds apart share one snapshot. `cpu` and `network` are rates, so they describe the time since the previous status (`over_s` says how long): the first status after a quiet spell covers a tenth of a second (the status waits for it, so it is short, and its per-core figures move in steps of about 10), a Refresh covers the time since the window opened.

## Why every read has a deadline

On 2026-11-18 Docker's virtual machine on m1-server stopped while its processes stayed alive. `docker ps` then hung instead of failing. So the container read connects, sends and receives against one 3-second deadline, and reports `unknown` when Docker accepts the connection and never answers.

That case is checked with a socket that accepts and stays silent:

```sh
python3 -c 'import socket,sys,time; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.listen(5); c,_=s.accept(); time.sleep(8)' "$TMPDIR/hung.sock" &
build/fleetd --once --docker-socket "$TMPDIR/hung.sock"   # containers: unknown, "no answer within 3 s"
```

The tools the helper starts (`launchctl`, `ps`, `cooler probe`, `brew`, `tailscale status`) have deadlines too. A tool that runs past its deadline is stopped, killed two seconds later if it ignores that, and its reading is reported `unknown`.

## Priority

The launchd job is marked `ProcessType Interactive`. It was first marked `ProcessType Background`, which keeps a job on the efficiency cores with throttled disk access. That starved it exactly when a status matters most: during m1-server's 04:00 Immich backup on 2026-11-18 (load average about 55) a status took 10 to 17 seconds and `ps` ran past its deadline every time. The same build at normal priority answered in 150 to 180 ms under the same load. The helper does almost nothing between requests, so a higher priority costs nothing while idle.

Normal priority lasted until the afternoon of 2026-11-18, when the helper began taking a timed sample. `ProcessType Interactive` is the launchd setting for a job a person is waiting on. Without it launchd lets the job's timers run late: the 0.1 s wait between the two processor counts took 0.25 s on m1-server, and a status there 0.54 s. With it the wait takes 0.1 s and a status that has to take the sample builds in about 0.2 s on m5-macbook and mini and 0.36 s on m1-server; one asked again within 30 seconds takes about 0.09 s and 0.21 s. Since build `fdaa40d1790e` that wait only happens just after a start or a sleep, and the same setting keeps the history timer on time.

That night also found a crash: the first time a tool ran past its deadline, the helper closed the tool's output while another thread was still reading it, and died (launchd restarted it). The reading thread now owns that output and closes it itself.

## Build and release

```sh
./build.sh                  # build/Fleet.app and build/fleetd, signed for this Mac only
./release.sh                # sign with Developer ID, notarize, publish the release, update the cask
./release.sh --no-publish   # stop after the notarized disk image
./check.sh                  # every Mac's release and any reading it could not take
```

- `project.yml` describes the two targets; `xcodegen` makes `Fleet.xcodeproj` from it, which is not kept in git. Xcode is needed because the Developer ID certificate is Apple's cloud-managed one, which only `xcodebuild` can sign with.
- The version is `MARKETING_VERSION` in `project.yml`. To release: raise it, commit, run `./release.sh`, then `brew upgrade --cask fleet` on each Mac and `./check.sh`.
- `fleet.rb` is the cask. `release.sh` copies it into `chetangoel01/homebrew-tap` with the release's version and checksum filled in.
- `build` in the status output is that version, read from the helper's own binary, so `./check.sh` can show the three Macs run the same release.
- `fleetd --once` prints one status document and exits, without listening.
- Started by launchd, the helper writes to `~/Library/Logs/fleetd.log` only when it cannot start.

What the cask was checked for on m5-macbook on 2026-11-18, with the notarized 0.1.0 image installed from a local copy of the cask: after the install and the `launchctl bootstrap` line the helper answered with every reading in the same state as the script-installed copy before it; a reinstall (the path an upgrade takes) left a new helper process answering and quit the menu bar app; an uninstall left no helper running 35 seconds later, past launchd's 30-second restart interval, and no launchd file.

## What it costs

`./measure.sh` samples the launchd-started copy on each Mac in two states, nobody asking and one request a minute, and saves the result under `measurements/`. Rerun it after any change.

Measured on 2026-11-18 on build `fdaa40d1790e`, the last before the cask and the first with the history timer; not measured again on 0.1.0, whose helper differs only in its version, its log and the interrupt it answers (`measurements/20261118-151456.txt`; the highest memory seen is from the overnight run of an earlier build, in `soak/results/`):

| | m5-macbook | m1-server | mini |
| --- | --- | --- | --- |
| CPU with nobody asking (the timer alone) | 0.01 s in 5 min | 0.02 s in 5 min | 0.01 s in 5 min |
| CPU per status, helper + the tools it starts | 0.024 + 0.11 s | 0.046 + 0.11 s | 0.024 + 0.06 s |
| Share of one core at one status a minute | 0.22% | 0.26% | 0.14% |
| Memory, quiet | 8 to 10 MB | 6 MB | 5 MB |
| Memory, highest seen (after thousands of requests in bursts) | 15 MB | 9.3 MB | 9.4 MB |
| Time to build a status, median | 198 ms on battery, 83 to 97 ms plugged in | 210 ms | 91 ms |
| Open files | 13 | 13 | 13 |

The timer costs 0.003% to 0.007% of one core. A second reading over twelve minutes with nothing asking (`measurements/idle-20261118-150009.txt`) gave 0.04 s on mini and 0.08 s on m1-server; m5-macbook slept for six of those minutes, which is also where the gap in its first graph came from. Before the timer the helper used 0.00 s in 5 minutes.

Most of a status's CPU cost is the tools (`ps` for the busiest process, `launchctl list`, `tailscale status`). The timer made a status quicker: the helper no longer waits 0.1 s between two processor counts, because the timer's last count is always recent. On build `b0021c57c935` a status nobody had asked for in 30 seconds took 218, 357 and 203 ms (`measurements/20261118-142920.txt`). Requests less than 5 seconds apart share a snapshot: the tools run once and each further request costs the helper about 1 ms. Memory that rose under bursts fell back on its own; `leaks` reports none (not rerun on this build).

## Overnight test

`soak/` holds a longer test, run from m5-macbook. Its scripts and samples go in `~/Library/Application Support/Fleet` on each Mac while it runs, and the edge tests start their throwaway copies from `/Applications/Fleet.app/Contents/Helpers/fleetd`. None of it has been run since the helper moved into the app:

```sh
soak/soak-start.sh "2026-11-18 10:00"   # a sampler on each Mac asks for a status once a minute until then
soak/soak-summary.sh                    # CPU, memory, open files and status times per Mac so far
soak/soak-summary.sh alerts 60          # only what needs a look in the last 60 samples
soak/edge-run.sh mini flood kill        # run edge tests on one Mac; results go to soak/edge-log.txt
nohup soak/night.sh "2026-11-18 09:30" &   # two random edge tests on a random Mac every 20 to 40 minutes
soak/soak-start.sh clean                # stop, copy each Mac's samples to soak/results/, remove the test files
```

The run of 2026-11-18 lasted 5.4 hours: 322 samples per Mac with no failed request. The only readings that could not be taken were three `ps` calls on m1-server that ran past their 3-second deadline while its Immich backup was running; each was reported `unknown` and the status took 3.2 s.

Edge tests that night (`soak/edge-log.txt`): 70 passed and 1 failed on the build installed that night, and 32 passed on the build before it, which differs only in the Time Machine reading. The failure was the test's own: on m1-server one of 150 connections opened at the same instant was refused, because the kernel queues 128 for a listener that is busy, and the test did not allow for that. It now counts refusals; the helper kept answering throughout. With every core busy a status took up to 5.3 s on m5-macbook.

`stuck-tool` passes on the build that crashed too, so it does not guard that fix. The evidence for the fix is the 29 consecutive tool timeouts under m1-server's backup load with no crash.

The edge tests (`soak/edge.sh`) are: `burst` (300 requests in a row), `flood` (200 requests, 50 at a time), `silent` (150 connections that send nothing), `garbage` (malformed and hostile requests), `freeze` (helper suspended, then resumed), `kill` (killed outright), `cold` (restarted and asked at once), `conflict` (a second copy on the same port), `hung-docker` (a Docker socket that never answers), `stuck-tool` (the helper's tools frozen past their deadline), `fd-limit` (a copy allowed 20 open files, then flooded) and `cpu-load` (every core busy). The last four use a throwaway copy on another port or add load, so they are not run on m1-server. On build `b0021c57c935` (new readings, a shorter sample, `ProcessType Interactive`) five of them were run, on m5-macbook only, on 2026-11-18: `burst`, `flood`, `garbage`, `kill` and `cold` all passed (the last entries in `soak/edge-log.txt`). On build `fdaa40d1790e` (the history timer) `kill`, `cold` and `burst` passed on m5-macbook the same day. The other tests, and every test on mini and m1-server, have not been rerun on either build.
