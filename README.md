# Win10/Win11 IoT (Enterprise) LTSC setup (slim)

an unattended, rerunnable setup for Windows 10/11 IoT Enterprise LTSC: a quiet system, a tiling
window manager, a small app set and your configs. native PowerShell 5.1, no extra frameworks.
built for a tiny10-style box with no store and often no network on first boot.

> this changes system settings and removes some built-in components. test in a VM first and run
> `-DryRun` before a real run. everything it touches is listed in [docs/TWEAKS.md](docs/TWEAKS.md).
> read [SECURITY.md](SECURITY.md) once: the ISO creates an admin account with a blank password.

## quick start

```powershell
# one click: double-click Setup.cmd (self-elevates, base + study pack, window stays open)

# or by hand
powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1 -DryRun   # read the plan first
powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1           # real run
powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1 -Verify   # read back the key tweaks
```

`Setup.cmd` runs `-Unattended -IncludeStudy`. extra flags pass through: `Setup.cmd -TweaksOnly`,
`Setup.cmd -SkipApps MiKTeX`.

## what you get

| area | choice |
|---|---|
| shell | stock PowerShell 5.1 plus a shell pack in the profile: starship, zoxide, fzf, bat, eza, fastfetch. native binaries, every hook guarded |
| window manager | Komorebi + whkd |
| browser | Helium (`ImputNet.Helium`) instead of Edge |
| editor | VSCodium with the darkmatter theme |
| apps | Vesktop, Telegram, qBittorrent, VLC, OBS Studio |
| automation-student basics | Git, Node.js LTS, Python 3.12, 7-Zip, Wireshark |
| AI assistant | `opencode` CLI (`SST.opencode`), sidebar in VSCodium. tuned for token cost, see [docs/OPENCODE.md](docs/OPENCODE.md) |
| panel | stock Windows taskbar, tuned with native settings |
| runtimes (first) | VC++ 2005 to 2022, .NET 8 Desktop Runtime, .NET Framework 3.5 and DirectPlay features |
| study pack, `-IncludeStudy` | Zotero, SumatraPDF, MiKTeX, Typst, Windows Terminal, plus their configs |
| optional, `-IncludeOptional` | Obsidian, Spotify |
| debloat | IE11, Edge, Windows Media Player, PowerShell ISE, WordPad, OneDrive removed after install. `-NoDebloat` to skip |

Telnet client is kept on purpose (old bench gear and scripts may still call it). Helium, VLC and
VSCodium replace the removed pieces. already-gone parts just log and continue.

**how apps get installed.** engines per app, first hit wins: staged `-OfflineDir` files, winget,
Chocolatey, GitHub releases. a tiny10 image has no AppX, so winget can be dead on arrival, which is
why the other engines exist.

## options

| flag | what it does |
|---|---|
| `-DryRun` | walk the whole install and log `[dry-run] would ...` for every write, download and cleanup, then stop. log and report json are still written |
| `-Verify` | read back key tweaks and print ok/MISS per item. exit code 1 if anything is missing. read-only |
| `-Unattended` | no prompts |
| `-TweaksOnly` | just the Titus-style tweaks (plus O&O) on any live machine. no apps, configs or debloat. what the minimal ISO uses |
| `-ConfigsOnly` | re-copy user configs to their real locations, nothing else. overwrites fresh-only configs too |
| `-Fixes` | repair dns, winsock and the update stack |
| `-IncludeStudy`, `-IncludeOptional` | add the study pack, add Obsidian and Spotify |
| `-NoTweaks`, `-NoDebloat` | skip the tweaks, skip the removals |
| `-Only <substr>`, `-SkipApps <substr>` | filter the app list by id, both take arrays. filtering runtimes logs a warning. an `-Only` run skips the bulk upgrade |
| `-OfflineDir <path>` | install from pre-seeded folders. works with no winget at all |
| `-DriverDir <inf-folder>` | install drivers from a folder (USB-serial, ST-Link and similar) |
| `-Dns <name>`, `-AdGuard`, `-NextDNS` | DNS on live adapters. auto-picked by default |
| `-GamingTweaks` | HAGS and priority separation |
| `-SkipBatteryCap` | skip the ThinkPad charge cap |
| `-SkipOOSU` | skip O&O ShutUp10++ |
| `-KeepFastStartup` | leave fast startup on |
| `-NoBackup` | skip the restore point and registry backup |
| `-NoWingetBootstrap`, `-NoChocoBootstrap` | don't bootstrap those engines when missing |
| `-SkipHashVerify` | skip sha256 checks on downloads |
| `-Idempotent` | re-run and only retry what failed |
| `-Force` | overwrite fresh-only configs |
| `-Reboot` | reboot at the end (60 s warning) |
| `-LogDir`, `-StateDir` | where the log, report and per-app state go |
| `-BuildConfig`, `-ExtraPrivacy` | declared but not used by the installer today |

## how it behaves
- **retries.** downloads retry 3x (BITS takes over for files of 20 MB or more and verifies size). each failed app gets one free retry pass. failures keep the apps phase open so an `-Idempotent` re-run only retries what failed. per-app state lives in `<StateDir>\apps.json`
- **report.** every run writes `report-<stamp>.json` next to the log (mode, OS, phases with seconds, installed, failed, warning count). the log's last lines are the one-line summary
- **log location.** `C:\Windows\Logs\Win-Iot-Setup`. a non-admin run falls back to `%TEMP%`
- **runtimes first,** then apps

## configs
what the installer copies, and what happens on a re-run.

| file | on re-run | notes |
|---|---|---|
| `PowerShell/Microsoft.PowerShell_profile.ps1` | overwritten | UTF-8 and history-search arrows, eza aliases, starship and zoxide init, fastfetch on interactive shells, ctrl+r/t fzf chords once PSFzf is present. guarded, PS 5.1 safe |
| `Komorebi/komorebi.json`, `Komorebi/whkdrc` | overwritten | `border_style` fixed, 10 workspaces, stock borders |
| `VSCodium/settings.json`, `keybindings.json` | overwritten | ctrl+alt+t terminal, ctrl+alt+b sidebar. edit `extensions.txt` to change extensions |
| `Git/.gitconfig` | kept | main branch, autocrlf, codium editor, prune, aliases. identity left blank for you |
| `Vesktop/settings.json`, `qBittorrent/`, `VLC/`, `OBS/` | kept | fresh-install only. each folder has a 2-minute README |
| `Vesktop/quickcss.css` | kept if edited | ships the system24 darkmatter theme. an untouched placeholder is upgraded on re-run, one you edited is kept |
| `config/opencode.json`, `config/AGENTS.global.md`, `config/opencode-skills/` | kept | agents, commands, gated context7 and playwright MCP, global rules, 4 skills. an old `opencode.json` is not replaced, see docs/OPENCODE.md |
| `SumatraPDF/`, `WindowsTerminal/` | kept | with `-IncludeStudy` |
| `Helium/master_preferences` | kept | copied only if Helium has no profile data yet |

`-ConfigsOnly` or `-Force` overwrite the "kept" ones too. back up anything you edited in the
"overwritten" rows before re-running.

## O&O ShutUp10++
the installer runs `OOSU\OOSHUTUP10.exe /quiet` with `OOSU/ooshutup10.cfg`, **before** our registry
values so ours win overlaps. the exe is not in this repo: if it is missing the installer logs
`O&O skipped (exe/cfg missing from OOSU/)` and carries on. drop the exe into `OOSU/` first if you
want that step, or pass `-SkipOOSU` to say it is on purpose.

## offline and ISO
run `ISO/Get-Offline.ps1` to pre-seed per-ID subfolders, then `-OfflineDir <path> -Unattended`.
the installer waits up to 4 minutes for DHCP on first boot before it declares offline.
`ISO/README-ISO.md` has the full recipe (tiny10 base, `Build-Iso.ps1`, Ventoy).
the answer files create an admin account named `My Pc` with a blank password and log it in once.

## after the install
- fonts: JetBrainsMono Nerd and Monocraft go into `Fonts/`
- Helium: confirm it as the default browser
- opencode: double-click `Win-Iot-Finish.cmd` on the Public Desktop once (`opencode auth login`)
- drivers: universal image, so add them per device (vendor NIC/wifi packs after first connect, or Windows Update once online)
- automation lab: MATLAB through the campus license, USB-serial drivers (CH340, CP210x, ST-Link) with `-DriverDir` or by hand, vendor tools (CODESYS, TIA, Studio 5000) from their own installers
- check: `komorebic state`, `whkd --version`

## keybinds (sway port, WIN = sway Mod4)

| keys | action |
|---|---|
| `Win+Return` | PowerShell |
| `Win+T` | files |
| `Win+Z` | Helium |
| `Win+A` | opencode |
| `Win+H/J/K/L` and arrows | focus |
| `Win+Shift+...` | move |
| `Win+1..0`, `Win+Shift+1..0` | workspaces |
| `Win+Space` | float |
| `Win+F` | monocle |
| `Win+M` | maximize |
| `Win+Alt+H/J/K/L` | resize |
| `Win+Shift+C` | reload |
| `Win+Shift+E` | stop WM |

native and left alone: `Win` Start, `Win+V` clipboard, `Win+Shift+S` snip, `Win+X` power menu, `Win+L` lock (can't be captured).
gaps mirror sway: inner 5, outer 0. Komorebi can't auto-assign apps to workspaces like sway `assign`,
so park apps once per session with `Win+Shift+Num`.

float rules go inline in `komorebi.json` as `floating_applications`, for example
`{"kind":"Exe","id":"notepad.exe","matching_strategy":"Equals"}`. no `applications.json` is needed:
the old `app_specific_configuration_path` key hard-crashed Komorebi when the file was missing, so it was removed.

## repo layout

| path | what |
|---|---|
| `Setup.cmd`, `install-Win-Iot.ps1` | entry points |
| `lib/` | installer modules |
| `config/` | defaults, tweak matrix, sha256 pins, deployed opencode config |
| `templates/` | answer-file and build templates |
| `ISO/`, `ventoy/` | unattended media, offline seeding, Ventoy copy of the answer file |
| `OOSU/` | O&O ShutUp10++ settings |
| app folders | config plus a short README each |
| `tests/` | `run-all.ps1` and the suites |
| `docs/` | tweaks reference, OpenCode setup |

## testing and contributing
`powershell -File tests\run-all.ps1` runs syntax, json, static, module smoke and installer smoke.
CI runs the same on every push. rules for changes: [CONTRIBUTING.md](CONTRIBUTING.md) and `AGENTS.md`.
third-party software: [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). history: [CHANGELOG.md](CHANGELOG.md).

## license
not chosen yet. until there is a LICENSE file, others have no permission to reuse this.
