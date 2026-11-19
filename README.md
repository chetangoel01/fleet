# Fleet

Two programs:

- **fleetd**, a small background program that answers one question about the Mac it runs on: how is this machine doing?
- **Fleet.app**, a menu bar item that asks fleetd and shows the answer.

The helper is inside the app (`Fleet.app/Contents/Helpers/fleetd`), so one Homebrew cask installs both on every Mac.

The app also carries **Cooler**, the fan controller its Fan Profile rows and curve editor drive, for Macs with fans. That one runs as root, so the cask does not install it; Fleet offers the install as a row. [cooler/README.md](cooler/README.md) has what it does and how it was checked.

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
- Fan control is a separate, one-time step with a password: **Install Fan Control…** among a Mac's actions, or `sudo /Applications/Fleet.app/Contents/Resources/Cooler/install.sh`. Upgrading Fleet never touches the installed controller; when the app carries a newer one the row reads **Update Fan Control…**. Uninstalling Fleet leaves the controller running the fans: `sudo '/Library/Application Support/Cooler/uninstall.sh'` removes it.
- On the Mac that should show the menu bar item, open Fleet once and choose **Open at Login** in its menu. The other Macs only need the helper.
- The app is signed with a Developer ID and notarized. It is built for Apple silicon and macOS 15 or later, and has only been run on macOS 27.
- `./check.sh` asks all three helpers and prints the release each runs and any reading it could not take.

The Macs it reads are named in `machines` in `FleetMenu.swift` (m1-server, mini and m5-macbook, by their Tailscale names), so on another set of Macs that list is the thing to change.

## Menu bar item

`Fleet.app` is built from `FleetMenu.swift` and `FleetWindow.swift`. A server-rack icon appears in the menu bar. **Open at Login** in its menu registers the app as a login item with macOS (`SMAppService`); the circle before the row is ticked while it is on.

The layout follows the mockup agreed on 2026-11-18:

- **Top of the menu:** anything needing attention, each with a red or orange dot: a container that is not running, Docker not answering, fewer than 15% of vnodes free, open files above 80% of the limit, a drive under 25 GB or 10% free (a Time Machine drive is left out, since it fills up by design), m1-server running on battery, an automatic Time Machine backup more than 2 days old, and this Mac's or m1-server's helper not answering. The count sits beside the menu bar icon in orange. A reading that is worth a glance but not a count is coloured orange where it already sits: CPU at 90° or above, memory running short (the kernel's memory level under 10%, whatever the percentage in use), a background job whose last exit was not 0. Everything else is plain. The limits are in `problems` and `details` in `FleetMenu.swift`.
- **Machines:** m1-server, mini and m5-macbook, each with a status dot and its battery and power. A Mac's flyout has battery, power, CPU (how busy, temperature, fans), memory, swap, network (down and up, with the connection and address in the tooltip), the busiest process, what keeps it awake, uptime, its drives and the last Time Machine backup. A reading the Mac does not have is left out. Under "Kept awake by", Fleet's own hold comes first with its end time; when nothing holds the Mac, "Sleeps when idle" shows its own setting instead, since "not kept awake" does not mean it will sleep (m1-server and mini are set never to).
- **A Mac that does not answer** is labelled from what this Mac's Tailscale says about it: "helper not answering" when it is online on the tailnet (the Mac is up, its helper is not), "offline" when it is not, and "not answering" when this Mac's own Tailscale is off or unreadable. Its flyout then offers Share Screen, Open Terminal and, when it is online, Restart Helper; for an offline m1-server it offers Reconnect Tailscale, which runs `tailscale up` there through `ssh m1-server-lan`, a name in `~/.ssh/config` that reaches it over its own network by way of the Raspberry Pi beside it (`lan` in `machines`). mini has no such route. mini being offline raises no warning and turns its dot grey (`sleeps` in `machines`); its helper not answering does warn. A Mac that is offline or not answering also gets **Wake** when Fleet can send it a wake packet; see *Waking a sleeping Mac*.
- **Connect Tailscale** appears at the top when Tailscale is off on this Mac, and runs `tailscale up` in a Terminal window.
- **Services:** every container, with a dot and its address. Clicking one opens `http://<mac>:<port>` in the browser; this applies to other Macs only. A stopped container adds a "Find Out Why … Stopped…" row.
- **Downloads:** shown while qBittorrent on m1-server has unfinished downloads, with percent and time left for each and the total speed on the row.
- **Scheduled jobs:** the jobs the Claude and Codex apps have switched on, grouped by app and Mac, then background (launchd) jobs whose last exit was not 0. Claude's jobs show when they last ran, with the schedule as the tooltip; Codex records no last run, so its jobs show the schedule. Each Mac's list is its own: the apps keep these files per Mac.
- **Fan Profile:** this Mac's fan profile, on the first screen because there is no other Mac it could mean. It is there when Cooler is installed on this Mac with its switching script, which all three Macs have since 2026-11-18. The row names the profile in force and its submenu switches among Automatic (Cooler's controller off, macOS runs the fans), Quiet, Balanced, Cooler, Max Cooling and, once the editor has saved a curve on that Mac, Custom. Edit Curve… under them opens the window on the curve editor. A switch runs Cooler's root script through `sudo -n '/Library/Application Support/Cooler/apply-profile'`, which Cooler's sudo rule allows an admin without a password; when the script refuses, an alert carries its reason. Another Mac with Cooler has the same row at the end of its flyout, and its fans are switched from here: the same script, run there over ssh (`ssh -o BatchMode=yes`), with the curve sent on standard input. A Mac whose Cooler has no switching script shows its profile among its readings. "This Mac" is the one whose computer name or local host name is in the list of Macs: m1-server's computer name reads `m1-server (2)`, which macOS made of it, and its local host name is `m1-server`.
- **Actions** carry an icon. A speech bubble opens a new Code session in the Claude app (`claude://code/new?q=…`) with a prompt typed in and not sent: Clean Up Disk…, Free Up Memory…, Sync Assistant Setup…, Find Out Why … Stopped…. Every prompt tells Claude to report first and change nothing until you pick. A terminal icon runs a command in a Terminal window through an interactive login shell, wrapped in `ssh -t` for another Mac (`onMac`), for the things worth watching or that may ask a question: Upgrade N Brew Packages runs `brew update && brew upgrade`, Open Terminal opens an ssh session, and the two Tailscale rows run `tailscale up`, which prints a sign-in link and waits when Tailscale wants one. The window is always on this Mac, so its first line says which Mac the command is running on ("On mini, over ssh from this Mac"). The short commands the app runs by itself, with no window (`Action.run`; for another Mac through `ssh -o BatchMode=yes`, which never asks for anything): Back Up Now (on a Mac with automatic Time Machine backups) runs `tmutil startbackup`, Start *name* (for a container that is not running) runs `docker start`, and the fan profile, Restart Helper and Wake work the same way. Install Fan Control… and Update Fan Control… (a fan icon, in a Terminal window because `sudo` asks for the password there) run the fan controller's installer from inside `Fleet.app` on that Mac; the row is there only while running it would change something. Nothing is said when one works, because the status asked for straight afterwards shows the change; when one fails, an alert shows what the command printed. Share Screen opens `vnc://<mac>` in Screen Sharing. A cup keeps a Mac awake and a filled cup lets it sleep again: Keep Awake (until told to stop), Keep Awake for 2 Hours and, while Fleet holds it, Stop Keeping Awake. These are the only rows that change a Mac at a click, by sending its helper the command under *What it does*; they are missing for a Mac whose helper is older than 0.2.0. A square with an arrow opens the browser. Sync Assistant Setup…, Open Fleet Window, Open at Login and Quit Fleet are the last rows of the main menu.

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
$B --dump samples/kept-awake-and-tailscale-off.json    # Fleet holding the Mac awake until a set time, and Tailscale off on this Mac
$B --open                                              # run a second copy with its menu open, for looking at it on screen
```

A saved status is one helper's `/status` document, so any state that is rare live can be checked by editing a copy.

## Window

**Open Fleet Window** in the menu opens a window on the same answers, with room for every reading. Built 2026-11-18 (`FleetWindow.swift`, SwiftUI inside the same app).

- **Overview:** anything needing attention, then a card per Mac with its picture, battery and power, CPU, memory and the drive closest to full (Time Machine drives aside), then every container side by side and, while there are any, the downloads. Clicking a card opens that Mac's page.
- **A page per Mac**, redesigned 2026-11-18 after "a lot is left to be desired". Nothing is folded any more. From the top:
  - picture, name, model, macOS version and uptime, and under them what is done to a Mac most, as icons named by their tooltips (`quick` in `details`): Share Screen, Open Terminal, Keep Awake and Back Up Now. Keep Awake is one cup that opens a menu of the two lengths; while Fleet holds the Mac the cup is filled and lit, and a click lets the Mac sleep again;
  - a labelled button for the rest: Start *name* for a container that is not running, Clean Up Disk…, Free Up Memory…, Upgrade N Brew Packages and the fan profile (a menu labelled with the profile in force, with Edit Curve… at its end);
  - **the fan curve editor**, a sheet over the page (`FleetCurves.swift`, taken from Cooler's own editor, which it replaces). It starts from the curve in the Mac's answer, or from the saved Custom curve or the Cooler profile when Max Cooling is on, since a flat curve has nothing to shape. Points are dragged, typed, added (the plus button, or a double-click on the graph) and removed; the editor holds temperatures increasing, demand never decreasing and the last point at full speed, which are the rules Cooler's controller checks. A Mac with palm rest sensors has a second curve for them. Start From loads the curve in force, the saved Custom curve or a profile. A dashed line marks the temperature in the Mac's last answer; nothing ticks, so Refresh moves it. Apply sends the curve to Cooler's script on that Mac and, once Cooler has taken it, keeps it there as `~/Library/Application Support/Cooler/custom.json`, which is what every Mac's Fleet then offers as Custom. A curve Cooler refuses changes nothing: the alert carries its reason and the editor stays open;
  - that Mac's own warnings;
  - a tile per live reading with one large figure: **Battery** (ring, with "plugged in" and the watts beside it), **CPU** (percent busy, one bar per core, temperature and fans; at 90° or above the temperature leads, in orange), **Memory** (percent in use, the figure Activity Monitor calls Memory Used, with a ring of the same, and swap), **Network** (down and up). A figure past its limit is orange, and so is its ring;
  - **Last 3 hours:** four graphs, a point a minute: CPU, memory in use, download and upload. A helper older than 0.2.1 sends no memory in use, and its Mac shows no Memory row, tile or graph until it is upgraded. Each has its own scale; the pointer over a graph shows the time and value under it. The line is broken where the helper has no points, because the Mac slept or the helper started later than the graph does. The graph ends at the helper's clock, not this Mac's;
  - **Storage:** a tile per drive with free space, a bar and, on the Time Machine drive, the last backup;
  - **Containers** side by side. Clicking a name opens that service in the browser, where it has an address (the tooltip shows it). The "…" at the end of each row, and a right-click, give Open in Browser, Restart (or Start) and Show Logs; Restart and Start run `docker` on that Mac with no window, Show Logs in a Terminal window;
  - **Scheduled jobs**;
  - **Network:** the connection (Wi-Fi or the adapter's name, and its interface), local address, Tailscale address, and how this Mac reaches that one over Tailscale (direct, or through which relay). This Mac's page lists the tailnet devices that are online;
  - **Details:** busiest process, what keeps it awake, open files, free vnodes.
- **The rings and bars show one moment**, drawn from the answer on screen. The graphs over time come from the helper's `history`, the one reading taken on a schedule (see *What it does*). Asked for on 2026-11-18 ("some history would be good"), which reversed the original no-timers rule for the helper; the app still has none.
- **Sidebar counts:** Services shows how many containers are stopped, Downloads how many are running, Scheduled jobs how many background jobs failed. No count means nothing to look at.
- **Services, Downloads, Scheduled jobs:** the same lists as the menu's flyouts (`Rows` draws the menu's own rows, so the two cannot disagree).
- **Pictures** are macOS's own. The helper reports the model code and, where the Mac records one, its case colour; `deviceType` asks macOS for the device type of `model@ECOLOR=colour` (the tag its own device pictures are keyed by) and falls back to the model alone, then to a generic Mac. Nothing is kept per model here.
- **No timers here either.** The helpers are asked when the window opens, when it comes to the front (unless they were asked in the last 5 seconds, since the helper would send the same snapshot) and on Refresh (Command-R). The title bar says "As of" a clock time, so a window left open shows how old its numbers are.
- A Mac asked again and not yet heard from is drawn at half strength, but only if it takes longer than half a second: a quick answer changes the numbers and nothing else. One that has not answered shows a generic picture and "not answering", and its page has a Wake button when the menu has the row.
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
- Answers `GET /status` with one JSON document. Any other request but the command below gets a 404, and so does a request whose `Host` header names anything but `127.0.0.1`, `localhost` or this Mac's own name (bare or under `.ts.net`), so a web page that points another name at the helper gets nothing.
- Reads nothing until asked, with one exception: a timer reads the processor and network counters every 20 seconds (two system calls, no tool started) and keeps a point a minute for three hours, in memory, for the window's graphs. A restarted helper starts with no history, and a Mac that slept has a gap.
- Takes one command, added in 0.2.0 at Chetan's request: keep this Mac awake, or stop. `POST /awake/on`, `POST /awake/on?minutes=N` (1 to 10080) and `POST /awake/off`, each with an `X-Fleet` header and no body. While on, the helper holds the same request `caffeinate -i` makes (no sleep while idle; the display may still sleep, and a laptop on battery still sleeps when its lid closes). The choice is written to `~/Library/Application Support/Fleet/awake-until`, so a restarted helper, which every upgrade causes, takes the hold again; a timed hold ends within 20 seconds of its time. A request without the header, or with an `Origin` header, gets a 404, and so does the `OPTIONS` question a browser asks before sending a header of its own, so a web page cannot switch it. `./check-awake.sh` runs all of that against `pmset -g assertions`.
- Nothing else can be run or changed through it. What it runs is fixed: `launchctl list`, `ps`, `tailscale status --json` and, where installed, `cooler probe` and `brew outdated`. On a Mac without Cooler it runs the app's own copy once per start, as `cooler check`, which reads the sensors and fans and writes nothing, to learn whether fan control could be installed there. On a Mac with a running `qbittorrent` container it also runs one fixed command inside that container per status (a `wget` of qBittorrent's own download list), because qBittorrent answers without a password only from inside its container.

It does not push changes or send notifications.

## Reaching the other Macs

Chosen 2026-11-18: Tailscale forwards a tailnet-only port to the helper on m1-server and mini, so the menu on m5-macbook reads them without ssh. Set up once on each of those two Macs (the setting survives restarts):

```sh
tailscale serve --bg --tcp 4791 tcp://127.0.0.1:4790     # m1-server: /Applications/Tailscale.app/Contents/MacOS/Tailscale
tailscale serve status                                   # what is forwarded
tailscale serve --tcp 4791 off                           # stop forwarding
```

- The forward is on 4791, not 4790: with Tailscale holding 4790 on the tailnet address the helper cannot open its own port ("Address already in use") and never starts.
- Every device on the tailnet can read `http://m1-server:4791/status` and `http://mini:4791/status`, not only the MacBook. The document holds each Mac's model, case colour and macOS version, its local network address, Tailscale address and connection name, the names of the tailnet devices that are online, the last three hours of its CPU, memory and network use, process, container and drive names, the names of scheduled Claude and Codex jobs, the names of unfinished downloads on m1-server, and the other readings below. Every such device can also switch keep-awake on or off on those two Macs: the forward hides who is asking, so the helper cannot tell them apart. That is the only thing they can change. The local network and the internet cannot reach it.
- m5-macbook has no forward, so nothing else can read it. A menu on another Mac would show it as not answering until it gets the same forward.

## Waking a sleeping Mac

A sleeping Mac wakes for a packet that carries its hardware address, sent to everyone on its own network, so only a Mac on that network can deliver it. Added in 0.3.0.

- **Wake** shows for a Mac that is offline or not answering when Fleet remembers its hardware address and a Mac that does answer is on the network it was last on (the same `subnet`). The row runs `fleetd --wake <address>` on that Mac, over `ssh -o BatchMode=yes` when it is another one, then asks every Mac again after 8, 20 and 40 seconds.
- `fleetd --wake` sends the packet (six `0xFF` bytes, then the address sixteen times) to UDP port 9 on the broadcast address of every `en` interface, three times a tenth of a second apart. It is a flag and not a command the listening helper takes, so nothing on the tailnet can make a Mac send one.
- **Remembering the address.** macOS shows a Mac's hardware address only to Apple's own tools: the helper reads `02:00:00:00:00:00`, and so does `ifconfig` when the helper starts it. So while another Mac answers, Fleet asks it over ssh (`ssh <mac> /sbin/ifconfig <interface>`), once, and again when that Mac's interface or address changes. The answer is kept in the app's preferences on the Mac running Fleet (`defaults read com.chetangoel.fleet links`), with the subnet. Nothing about it is in this repository.
- **Which Macs this reaches.** m1-server and m5-macbook share a network, so either can wake the other. mini is on a network of its own with no other Mac to send for it, so it gets no Wake row. A Mac is only remembered by a Fleet that has had an answer from it: m5-macbook forwards no port (see *Reaching the other Macs*), so the other Macs' menus never learn its address and cannot offer to wake it.
- Sent from the Mac running Fleet itself, macOS may first ask whether Fleet may find devices on the local network. Another Mac is tried first, where ssh needs no such leave.
- Two networks that number themselves alike (both `10.0.0.0/24`, say) look the same to this check. A MacBook asleep somewhere else on such a network gets a Wake row that does nothing.
- **Not known to work.** No Mac was put to sleep to try it, so a wake by this packet has never been seen, and the Wake row and button have never been on screen: every Mac was awake. Two reasons it may not: m5-macbook is on Wi-Fi under a private address, which is the one remembered, and whether a sleeping Wi-Fi chip answers to that or to its permanent address is unknown (a rotating private address would also go stale, since it is asked for again only when the interface or IP address changes); and m1-server's network connection is a USB adapter, which may not wake a sleeping Mac at all. m1-server also cannot sleep while Amphetamine's closed-display session runs, which is its normal state.

## Readings

| Key | What it holds | How it is read |
| --- | --- | --- |
| `disks` | Free and total GB for each local volume | Volume attributes, in-process, 3 s limit |
| `memory` | Memory in use as a percentage of what is installed (`used_pct`: installed memory less free pages and cached files, which is Activity Monitor's Memory Used), the kernel's memory level (`free_pct`: how far the Mac is from running short, which the warning follows; it is not the rest of `used_pct`), swap used and total | `host_statistics64` and `sysctl`, in-process |
| `files` | Open files across the whole Mac and the kernel's limit; free vnodes and their limit (the limit m1-server actually ran out of on 2026-11-18) | `sysctl`, in-process |
| `power` | Battery percentage and charging (laptops), adapter input in watts | IOKit registry, in-process |
| `containers` | Each container's name, state, status and published ports | Docker's Unix socket, in-process, 3 s limit |
| `downloads` | Unfinished qBittorrent downloads: name, percent, bytes per second, seconds left | One `wget` run inside the `qbittorrent` container through Docker's socket, 2 s limit per step; `none` without that container |
| `schedules` | Jobs the Claude and Codex apps have switched on: app, name, schedule as the app wrote it, Claude's last run, a one-off's time. No prompts, folders or session ids | Claude's `scheduled-tasks.json` (under `~/Library/Application Support/Claude/claude-code-sessions/`) and Codex's `~/.codex/automations/*/automation.toml`, in-process. Both are undocumented app files; one that cannot be read is skipped |
| `cpu` | How busy the processor is, overall and per core, and the seconds that covers | Kernel tick counts (`host_processor_info`), in-process: the change since the history timer's count from 8 to 32 seconds before. Just after a start or a sleep there is no such count, and two counts 0.1 s apart are taken instead |
| `network` | Bytes a second down and up over the same span, the connection the Mac's traffic leaves by (interface, its name such as "Wi-Fi", its address, and the network that address is on as `subnet`, such as `10.0.0.0/24`) and the Tailscale address | Interface byte counters (`getifaddrs`) and the system's network settings, in-process |
| `tailnet` | Whether Tailscale is connected (`running`), and the tailnet devices that are online: name, whether this Mac reaches each directly or through a relay (and which), whether it is in use | `tailscale status --json`, 3 s limit; `none` without Tailscale. Phones and tablets, which report no name, are left out |
| `history` | The last three hours, a point a minute: time, CPU percent, memory used percent, bytes a second down and up. Up to 180 points, about 6 KB | The same counters as `cpu` and `network`, read by a timer every 20 seconds and added up over each minute; `kern.memorystatus_level` at the minute's end. A count more than 45 s after the one before (the Mac slept) starts a new minute and leaves a gap |
| `hardware` | Model code, case colour number (absent on a Mac that records none, such as the mini) and macOS version | `hw.model`, `housing-color` under `IODeviceTree:/chosen`, and the process's own OS version, all in-process |
| `jobs` | Non-Apple launchd jobs whose last exit was not 0. The helper's own job is left out: it leaves with 1 after every upgrade | `launchctl list` |
| `busiest` | The process using the most CPU and the one using the most memory | `ps` |
| `awake` | Processes holding the Mac awake, with the reason each gave; whether Fleet is holding it and until when (`fleet`); the Mac's own idle-sleep setting in minutes, 0 for never (`sleep_after_min`) | IOKit power assertions and the power settings in the system's configuration store, in-process |
| `thermal` | CPU temperature and fan speeds, on Macs with Cooler installed, and the GPU's and palm rest's temperatures (`gpu_c`, `palm_c`), the hottest sensor of each as Cooler's controller takes them | Cooler's status file while its fan curve is running (fan speeds are then its targets), otherwise `cooler probe` |
| `cooling` | On a Mac with Cooler: whether its controller is running (off means macOS runs the fans), the curve it is set to (`baseline_rpm`, `curve`, `palm_curve`), the controller's own reason while it runs, whether Cooler's switching script is installed (`switchable`), the curve the editor last saved there (`custom`), each fan's slowest and fastest speed (`fan_limits`) and whether the Mac has palm rest sensors (`palm`). `install` is the path of the installer inside `Fleet.app` while running it would change something: Cooler is not installed and `cooler check` says it could run this Mac's fans (the state is then `none`), or the installed `version` file differs from the app's. The app names the profile from these. Read only: the helper switches nothing | Cooler's `config.json` and `status.json`, `launchctl print system/com.chetangoel.cooler`, the user's `~/Library/Application Support/Cooler/custom.json`, and one `cooler probe` per run of the helper for the fans' limits |
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
./check-awake.sh            # the keep-awake command against what macOS reports, on a scratch copy of the helper
python3 cooler/e2e.py       # the fan controller's 36 replay checks, on build/cooler; no hardware touched
```

- `project.yml` describes the three targets (the app, the helper and Cooler's controller, each built into the app); `xcodegen` makes `Fleet.xcodeproj` from it, which is not kept in git. Xcode is needed because the Developer ID certificate is Apple's cloud-managed one, which only `xcodebuild` can sign with.
- The version is `MARKETING_VERSION` in `project.yml`. To release: raise it, commit, run `./release.sh`, then `brew upgrade --cask fleet` on each Mac and `./check.sh`.
- `fleet.rb` is the cask. `release.sh` copies it into `chetangoel01/homebrew-tap` with the release's version and checksum filled in.
- `build` in the status output is that version, read from the helper's own binary, so `./check.sh` can show the three Macs run the same release.
- `fleetd --once` prints one status document and exits, without listening. `fleetd --wake aa:bb:cc:dd:ee:ff` sends that hardware address its wake packet and exits; see *Waking a sleeping Mac*.
- Started by launchd, the helper writes to `~/Library/Logs/fleetd.log` only when it cannot start.

What was checked on 2026-11-18, on m5-macbook unless a line names another Mac, with releases installed from the tap:

- **First install (0.1.0).** After the `launchctl bootstrap` line macOS showed its Open prompt, and the helper answered once it was clicked, with every reading in the same state as the script-installed copy before it. On mini the same install was done over ssh with the screen locked: the prompt went up behind the lock and the helper stayed held until Open was clicked there later that day; it then answered with every reading in the state it had before the move.
- **Upgrade from a release without the self-restart (0.1.0 to 0.1.1).** No prompt, the approval mark was on the new copy, and Homebrew reopened the menu bar app. The 0.1.0 helper kept running until `launchctl kickstart -k gui/$(id -u)/com.chetangoel.fleetd`; a Mac still on 0.1.0 needs that one command after upgrading.
- **Upgrade between two releases with it (0.1.1 to 0.1.2).** Nothing was run after `brew upgrade`: no prompt, the app reopened, and a new helper process answered as 0.1.2 16 seconds after Homebrew finished.
- **Unattended upgrades (0.1.2 to 0.2.0, then 0.2.1 on two Macs; 0.2.1 to 0.2.2 on all three, m1-server's first from the cask, where the new helper answered 10 seconds after Homebrew finished).** m5-macbook and mini, mini over ssh with its screen locked: a new helper answered as the new release within 20 seconds of Homebrew finishing, with no prompt. Mini came from 0.1.0 and needed the one `launchctl kickstart` first.
- **A keep-awake hold across an upgrade (0.2.0 to 0.2.1, on mini).** A two-hour hold was set before `brew upgrade`. Afterwards `pmset -g assertions` showed the new helper process holding it, with the same end time.
- **The keep-awake command from another Mac**, m5-macbook to mini and to m1-server through the tailnet port: on, off, and a request without the header refused, each compared with `pmset -g assertions` on the Mac itself. `./check-awake.sh` covers the rest on a scratch helper.
- **The keep-awake buttons in the window (0.2.1).** Keep Awake for 2 Hours and Stop Keeping Awake were pressed on the pages for mini and m5-macbook, and `pmset -g assertions` on each Mac showed the hold appear and go. The same rows in the menu bar flyouts were not pressed.
- **The fan profile switch (after 0.2.1, on m5-macbook).** From the window's Fan Profile menu: Quiet, Cooler, then Automatic. After each, Cooler's controller, its launchd setting and its `config.json` matched, and the helper's `cooling` reading and the menu named the same profile. Custom was not pressed.
- **Actions without a Terminal window (after 0.2.2).** From the window: the fan profile on m5-macbook (Quiet, Cooler, Automatic, each matching Cooler's own state afterwards, with no Terminal script written), a switch refused by Cooler's script because a process named Stats was running (the alert read "Quit the other fan controller before switching." and the profile stayed), and Back Up Now on m1-server over ssh (`tmutil status` there went from not running to running). Not pressed: Start for a container and Restart Helper, which had nothing to act on.
- **The fan profile on the menu's first screen (after 0.2.4, on m5-macbook).** From the menu bar menu itself: Fan Profile, then Quiet, Automatic, Cooler and Automatic again. After each, Cooler's controller (running at 1200 or 1800 rpm idle, or off) and the helper's `cooling` reading matched. The row is on the first screen only, not in m5-macbook's flyout; the window's page for m5-macbook has its Fan Profile menu.
- **The icons on a Mac's page (after 0.2.5).** On mini's page: the Keep Awake cup, then Keep Awake for 2 Hours in its menu, and mini's helper reported the hold with an end time and the cup turned lit; a click on the lit cup, and the hold was gone. Share Screen, Open Terminal and Back Up Now were read by name from the window and not pressed, since they open another app or start a backup, and the fan profile menu on m5-macbook's page was not pressed in this layout. The menu bar menu's actions were compared before and after: the same rows in the same order, with the filled cup on Stop Keeping Awake the one difference. All three pages were looked at at the usual width, m1-server's both held awake and not, and m1-server's at 640 points.
- **Cooler on mini and m1-server (2026-11-18, after 0.2.6).** Cooler was installed on both from one build (see the services note for which). On each Mac the commands its own Fan Profile rows run were run there over ssh: Quiet, then Cooler. After each, Cooler's controller was running with the new idle speed (1,200 then 1,800 rpm) and Fleet on that Mac named the profile. On m1-server this used a copy of the 0.2.7 build, the first that recognises that Mac as itself. There one fan read 0 rpm eight seconds after each switch and was back on its target within about 15 seconds; mini's single fan did not pause. The rows were not clicked in those Macs' menus.
- **Another Mac's fans and the curve editor (before 0.2.8, from m5-macbook).** From the window's page for mini: Quiet in its Fan Profile menu, and mini's controller idled at 1,200 rpm. Then mini's editor, Start From Balanced and Apply: mini ran the Balanced curve and held it in its `custom.json`. On a page for this Mac, the editor loaded the saved Custom curve, added a point, showed the palm rest curve, and Apply installed the curve and rewrote `custom.json`. The first try at that failed, because the curve reached only the first command of the script on this Mac; the alert carried Cooler's reason, the editor stayed open and nothing had changed. Dragging a point was not tried. Both Macs were put back on the Cooler profile, mini's test curve was removed and this Mac's saved curve was restored.
- **Carried fan control (0.3.0).** `python3 cooler/e2e.py` passed 36 of 36 on the build. On all three Macs the installed release's `cooler check` read the sensors and fans, `install.sh` refused to run without root, and each Mac's menu offered Update Fan Control…, since none has a `version` file yet. The installer itself has not been run from Fleet on any Mac: each still runs the controller installed from Cooler's repository, built from the same source. Cooler's own app, SwiftBar plugin and login job were moved to the Trash on m5-macbook and m1-server (`cooler-retired-2026-11-18`) with both controllers left running their curves; SwiftBar itself stays installed.
- **Wake (0.3.0).** `fleetd --wake`, run on m1-server over ssh with m5-macbook's address, was counted on the Raspberry Pi on the same network: 6 valid packets. Run on m5-macbook with m1-server's address, m1-server counted them too. Fleet on m5-macbook remembered both other Macs' addresses and subnets (`defaults read com.chetangoel.fleet links`); m1-server's came only after Fleet was reopened, because its helper was mid-upgrade at the first ask. Not checked: everything under *Not known to work* above, and a packet sent by Fleet from the Mac it runs on.
- **Every row and icon, on 0.3.0 from m5-macbook.** In the window: this Mac's Fan Profile menu to Quiet, to Custom (the installed curve then equalled `custom.json`, and the fans went to about 5,000 rpm) and back to Cooler; Share Screen on mini's and m1-server's pages, which opened Screen Sharing at its sign-in for that Mac; Open Terminal on mini's page, which opened a Terminal window in an ssh session there; Back Up Now on m1-server's page, after which `tmutil status` there read running; Start for a container, on a throwaway `alpine` container created stopped on m1-server for this and removed afterwards, which went from created to running. In the menu: Restart Helper for mini, with its helper suspended (`kill -STOP`) so that the row showed; a new helper answered and kept its keep-awake hold. Connect Tailscale was pressed in a window drawn from `samples/kept-awake-and-tailscale-off.json`, with Tailscale really on: the Terminal window ran `tailscale up` and printed "connected". Not pressed: Reconnect Tailscale, which shows only with m1-server off the tailnet (its route, `ssh m1-server-lan`, answered by hand); Wake; and any row in mini's or m1-server's own menus, since Fleet's menu is not open on either, pressing over ssh is refused by macOS's accessibility rules, and Screen Sharing asks for each Mac's password.
- **The helper's wait**, with a scratch copy under a temporary launchd job: replaced by a copy flagged as downloaded and not approved, it kept running for 50 seconds; with the flag removed it left and launchd started the new copy.
- **Uninstall (0.1.0, from a local copy of the cask).** No helper running 35 seconds later, past launchd's 30-second restart interval, and no launchd file.

Why the helper restarts itself: the cask's install steps run before Homebrew marks the new copy approved, so a helper the cask restarted came up unapproved and waited for the prompt on every upgrade. Not checked: an upgrade on a Mac whose copy was never approved, the login item starting the app at login, and an uninstall of a release later than 0.1.0.

m1-server was moved to the cask on 2026-11-18, from the install script this repository had before it: the cask was installed while the old helper kept answering, opening `Fleet.app` over ssh put the Open prompt on its screen, and once Open was clicked a `launchctl bootout` and `bootstrap` started the copy inside `Fleet.app` with no second prompt. Every reading kept its state. The old script's `uninstall.sh` was not run, because it deletes the launchd file the cask wrote and the folder that holds the keep-awake choice; the old files went to the Trash by hand.

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
