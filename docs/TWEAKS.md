# what the tweaks do

titus-style, native registry. `-NoTweaks` skips them. `-TweaksOnly` runs just these (plus O&O) on a live machine.
run `-DryRun` first, then `-Verify` after. test in a VM before a real box.

## order
1. restore point
2. O&O ShutUp10++ with the titus cfg
3. our registry values, so ours win any overlap

## privacy and telemetry
- telemetry 0 (Enterprise honors it)
- DiagTrack and dmwappushservice disabled
- location off
- off: Bing, Cortana, consumer apps, GameDVR, taskbar feeds (Win10 Widgets stand-in), store suggestions, error reporting, USB autorun
- background apps off
- inking and typing AI leftovers off
- toasts and notification center off
- Win11 only: Copilot and Recall off

## services
- 10 services to Manual (maps, xbox, retail, wallet, insider, CDP)
- autostart delay off
- svchost split matched to RAM

## updates and storage
- notify before download, no auto-reboot, no driver pushes
  (Win10 is cumulative so a security-only split is impossible. LTSC plus notify is the sane equivalent)
- Delivery Optimization off
- reserved storage off
- storage sense off
- temp files and disk cleanup
- OneDrive gone

## security and network
- silent BitLocker auto-encryption blocked
- WPBT execution off
- smb1, llmnr, netbios off
- remote assistance off
- lsass protected
- wdigest off
- guest off
- firewall and defender on
- defender exclusions for `C:\Setup` and `%ProgramFiles%\MATLAB`, only if they exist (note: `C:\Setup` is where the ISO stages this repo and the offline installers)
- teredo off
- IPv4 preferred (a full IPv6 kill breaks things, so it is skipped)
- DNS from `-Dns` on live adapters, Cloudflare by default

## explorer and ui
- extensions shown, This PC as default, folder-type auto-discovery off, long paths on
- dark mode on (taskbar and apps)
- world formats en-001
- verbose bluescreens, verbose boot, numlock on, fast key repeat
- classic mixer and alt-tab, no shake, fast menus
- Win11 only: classic right-click menu, widgets and chat buttons off

## taskbar
small icons, never-combine labels, seconds clock, tray all out, junk buttons gone, stock colors.

## performance and power
- best-performance base, with ClearType, shadows and content dragging kept. animations and peek off
- hibernate off
- laptops keep the balanced plan. desktops get ultimate or high performance (system type first, battery count as fallback)
- battery manners ported from the linux box: screen off at 3 and 10 min, sleep after 30 min on battery, never on AC, lid suspends on battery only
- ThinkPad charge cap 80/75 through Lenovo's own `chargethreshold.exe` (signature-checked, Lenovo hardware only, `-SkipBatteryCap` to skip)
- RTC in UTC
- `-GamingTweaks`: HAGS (Win10 with a WDDM 2.7 driver, reboot to take) and priority separation pinned to the desktop default

## on demand
- `-Fixes` repairs the dns, winsock and update stack

## runtimes (installed first, via winget)
- full VC++ stack 2005 to 2022, x86 and x64 (old vendor tools need the ancient ones)
- .NET 8 Desktop Runtime
- .NET Framework 3.5 and DirectPlay features enabled
- .NET 4.8 is already in-box on both LTSC builds

## not done
- right-click End Task and start-menu layout: no native lever
- true blur styling, middle-click actions, scroll-volume: need a hooking engine, out of scope
