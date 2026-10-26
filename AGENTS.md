# AGENTS.md - notes for any coding agent working in this folder

## What this is
Slim Win10/Win11 IoT LTSC setup: PowerShell base, Komorebi + whkd,
Helium, VSCodium, stock taskbar. Dark mode on, everything else stock.
Unattended installer: `install-Win-Iot.ps1` (`-TweaksOnly` for
tweaks-only runs). Custom ISO recipe in `ISO/README-ISO.md`. Taste port
from the sibling linux project `..\XfceMlg` (VSCodium theme, Vesktop
quickcss, shell pack, battery manners).

## Rules learned the hard way
- Komorebi `border_colours` is British spelling. `boarder_*` was a real
  bug here once. Schema: `.../LGUG2Z/komorebi/v0.1.39/schema.json`.
- Never add `app_specific_configuration_path` without shipping the file.
  Komorebi hard-crashes on a missing path (os error 2). Float rules go
  inline as `floating_applications` instead.
- Native exes (DISM, powercfg, installers) don't throw in PowerShell.
  Always check `$LASTEXITCODE`. try/catch alone lies.
- `winget download` filenames embed the installer tech
  (`_<scope>_<arch>_<tech>_<lang>.<ext>`). Read the tech for silent flags,
  don't guess: `_burn_` = /install /quiet, `_exe_` legacy redists = /q,
  `_wix_` = .msi, `_inno_` = /VERYSILENT, `_nullsoft_` = /S.
- Unknown keys in vlcrc/qbittorrent.ini/OBS basic.ini are ignored, so
  best-effort keys are safe there. Unknown JSON keys in komorebi.json
  are tolerated too (observed on 0.1.41), but prefer schema-known keys.
- Vencord ignores unknown plugin names in settings.json. Still, only add
  plugin names verified against vencord.dev/plugins.
- Voice: comments and logs read like one tired human. Short, lowercase
  asides, no em-dashes, no buzzwords, no triplets. Never "improve" wording
  in a way that touches logic. Run the tests after every edit:
  `powershell -File tests\run-all.ps1` (syntax, json, static, module smoke,
  installer smoke; PSScriptAnalyzer reported when installed).
- New switches stay additive: `-DryRun`, `-Verify`, `-Only`, `-SkipApps`
  all default off and guard every write site. When adding a write, add a
  dry-run log line for it. `Complete-Phase` never marks done in dry-run;
  the log + report json still get written (that is the dry-run deliverable).
- Autounattend parity is a test now: `ISO/autounattend.xml` must match
  `ventoy/script/Win-Iot-unattended.xml` ignoring comments. Edit both.
- ThinkPad charge cap: lenovo-only, gated on the PWRMGRV key or the
  IBMPMDRV service, so non-lenovo machines just log a skip. The exe comes
  from lenovo's cdn, is sha256-pinned in `config/hashes.json` (refresh the
  pin when lenovo ships a new build) and signature-checked, never bundled.
  `-SkipBatteryCap` opts out. "already capped" only counts on a positive ON
  from the exe; anything unparsed gets the cap set. The ChargeStart/Stop reg
  fallback mirrors a known driver bug that makes a fresh threshold read back
  OFF, don't delete it.
- Vesktop quickcss upgrades only when the file is untouched (exact old
  placeholder, whitespace/BOM-insensitive) or empty. Anyone who added rules
  under the old marker keeps their file. `Test-QuickcssStale` owns the rule,
  in the installer and in the smoke test.
- Shell profile hooks (starship/zoxide/eza/fzf) are all `Get-Command`
  guarded, and fastfetch only fires on an interactive console with output
  not redirected. Drop that guard and installs + tests drown in fastfetch.
- VSCodium folder extensions need the `publisher.name-version` folder name
  matching package.json, or codium acts like the theme is not installed.
- PS 5.1 quirk: `@(ConvertFrom-Json ...)` nests the array. assign first,
  wrap after. bit the smoke test once.

## Layout
- Per-app folders hold a config + short README. Fresh-install only deploys
  (`Copy-Fresh`), never overwrite a lived-in config.
- `Setup.cmd` at the root: one-click, self-elevating wrapper. runs the
  installer with `-Unattended -IncludeStudy`, extra flags pass through.
- `OOSU/` holds the titus cfg. `OOSHUTUP10.exe` (85MB) is not committed to github. drop it in
  locally or the installer logs a skip and runs without O&O.
  Runs `/quiet` before our reg values so ours win overlaps.
- `ISO/`: FirstLogon.cmd, Get-Offline.ps1 (keep its ID list in sync with
  the installer's), Offline/ cache (gitignored), build/ working copy
  (gitignored), merged autounattend.xml (My Pc admin + FirstLogon).
  `ventoy/script/Win-Iot-unattended.xml` is a copy of it, change one,
  change both. `-BakeToWim` puts the same payload inside install.wim
  for ventoy (which skips $OEM$); rufus path stays live via $OEM$.
- `.gitignore` excludes `*.iso`, `ISO/build/`, `ISO/Offline/`. No secrets
  in the tree: blank passwords, empty API keys.

## Agent workflow
- Read the folder README before touching an app config. Most have a 2-minute note that matters.
- Small diffs. One concern per change. Don't reformat files you aren't editing.
- Before saying done: `/precheck`, then `powershell -File tests\run-all.ps1`. Report what actually ran.
- If the tests can't run here (not on Windows, missing module), say so. Don't claim they passed.
- Don't commit, push or delete unless asked. `/commit` drafts the message, the human runs it.
- Don't touch the pins in `config/hashes.json`, or anything under `ISO/Offline/` or `ISO/build/`.
- `Copy-Config` overwrites, `Copy-Fresh` keeps. pick on purpose. anything with a blank
  identity or a user's own edits is fresh-only (that is why `.gitconfig` is).
- A script-level call must sit below the function it calls. `tests/static-check.ps1` enforces it.
- WMI class names use underscores (`Win32_Battery`). the hyphen version threw and a catch hid it.
- Keep scripts ascii. PS 5.1 reads bom-less utf-8 as ANSI.
- When a rule here and a guess disagree, the rule wins. If the rule looks wrong, ask.
