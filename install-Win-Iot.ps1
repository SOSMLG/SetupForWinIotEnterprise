<#
.SYNOPSIS
  My Win10/Win11 IoT (Enterprise) LTSC setup. Unattended, rerunnable.
.DESCRIPTION
  Built for a tiny10 box with no store and usually no network
  on first boot. PS 5.1, Komorebi + whkd, Helium, VSCodium, stock taskbar.
  No terminal, no extra shells. Stock colors everywhere.
  Engines per app, first hit wins: staged -OfflineDir files, winget,
  choco, github releases. Log lands in C:\Windows\Logs\Win-Iot-Setup either way.
.EXAMPLE
  powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1
  powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1 -Unattended -OfflineDir D:\Offline
  powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1 -Unattended -DriverDir D:\Drivers -Reboot
  powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1 -IncludeOptional -Unattended
  powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1 -IncludeStudy -Unattended
  (study pack: zotero, sumatra, miktex, typst, windows terminal + their configs.)
  powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1 -TweaksOnly
  (tweaks-only: just the tweaks on any live machine. no apps, no configs, no debloat.)
  powershell -ExecutionPolicy Bypass -File install-Win-Iot.ps1 -ConfigsOnly
  (configs-only: re-copy user configs to their real locations, nothing else.)
#>
[CmdletBinding()]
param(
  [switch]$AdGuard,
  [switch]$NextDNS,
  [switch]$DNSAuto = $true,
  [switch]$SkipHashVerify,
  [switch]$SkipTemplateGen,
  [switch]$Idempotent,
  [switch]$Force,
  [string]$StateDir = 'C:\Windows\Logs\Win-Iot-Setup\state',
  [string]$BuildConfig = '',
  [string]$Arch = '',
  [switch]$DetectHardware,
  [switch]$IncludeOptional,
  [switch]$IncludeStudy,
  [switch]$Unattended,
  [switch]$NoWingetBootstrap,
  [switch]$NoChocoBootstrap,
  [string]$OfflineDir = '',
  [string]$LogDir = 'C:\Windows\Logs\Win-Iot-Setup',
  [string]$DriverDir = '',
  [string]$Dns = 'Auto',
  [switch]$NoTweaks,
  [switch]$NoDebloat,
  [switch]$TweaksOnly,
  [switch]$ConfigsOnly,
  [switch]$Reboot,
  [switch]$Fixes,
  [switch]$GamingTweaks,
  [switch]$SkipBatteryCap,
  [switch]$ExtraPrivacy,
  [switch]$KeepFastStartup,
  [switch]$DnsOffByDefault,
  [switch]$NoBackup,
  [switch]$SkipOOSU,
  [switch]$DryRun,
  [switch]$Verify,
  [string[]]$Only = @(),
  [string[]]$SkipApps = @()
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 2
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo = Split-Path $MyInvocation.MyCommand.Path -Parent
# -ConfigsOnly re-deploys user configs (VSCodium, Vesktop, qBittorrent, opencode,
# komorebi, ...) and nothing else. tweaks are forced off; install phases are gated below.
if ($ConfigsOnly) { $NoTweaks = $true }
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
# C:\Windows\Logs needs admin. non-admin runs fall back to TEMP instead of dying.
try { New-Item -ItemType Directory -Force -Path $LogDir -EA Stop | Out-Null }
catch { $LogDir = Join-Path $env:TEMP 'Win-Iot-Setup'; New-Item -ItemType Directory -Force -Path $LogDir -EA SilentlyContinue | Out-Null }
# non-admin runs land in TEMP, so the state dir follows the log dir there.
if ($StateDir -eq 'C:\Windows\Logs\Win-Iot-Setup\state' -and $LogDir -ne 'C:\Windows\Logs\Win-Iot-Setup') { $StateDir = Join-Path $LogDir 'state' }
$LogFile = Join-Path $LogDir "install-$Stamp.log"
$transcriptOn = $false
try { Start-Transcript -Path $LogFile -Force -EA Stop | Out-Null; $transcriptOn = $true } catch {}
# warn count lands in the run report. it is the number a tired human reads first.
$script:warnCount = 0
function Log($m) {
  if ("$m" -like '*WARN*') { $script:warnCount++ }
  Write-Host ("[{0:HH:mm:ss}] {1}" -f (Get-Date), $m)
}
# phase timers: seconds per phase, straight into the report. cheap and honest.
$script:phaseTimes = [ordered]@{}
$script:phaseName = $null
$script:phaseStart = $null
function Start-Phase($name) { $script:phaseName = $name; $script:phaseStart = Get-Date }
function Stop-Phase {
  if ($script:phaseName) {
    $elapsed = (Get-Date) - $script:phaseStart
    $script:phaseTimes[$script:phaseName] = [int][math]::Round($elapsed.TotalSeconds, 0)
    $script:phaseName = $null
  }
}
function Refresh-Path {
  # fresh installs don't land on PATH in this session. re-read it or python/codium are "missing".
  try { $env:Path = [System.Environment]::GetEnvironmentVariable('Path','Machine') + ';' + [System.Environment]::GetEnvironmentVariable('Path','User') } catch {}
}

# ---------- phase 0. helpers: module load, state, OS + hw detect, templates ----------
# dot-source our lib modules if present. they carry the new universal-upgrade
# plumbing, but every call below still guards on a missing module, so a bare
# repo (lib/ absent) keeps working exactly as before.
$LibDir = Join-Path $Repo 'lib'
$loadedModules = @()
if (Test-Path $LibDir) {
  foreach ($m in @('Logging','Utils','Registry','OSInfo','Network','Security','Template','Config','TweakMatrix')) {
    $mp = Join-Path $LibDir "$m.psm1"
    if (Test-Path $mp) {
      try { Import-Module $mp -Force -ErrorAction Stop -DisableNameChecking; $loadedModules += $m }
      catch { Log "WARN module $m`: $($_.Exception.Message)" }
    }
  }
  if ($loadedModules.Count) { Log ('  lib modules: ' + ($loadedModules -join ', ')) }
}
# idempotency: one small json per phase under StateDir. a completed phase is
# skipped on re-run unless -Force. a missing state file is never fatal.
function Get-PhaseState {
  if (-not (Test-Path $StateDir)) { return @{} }
  $sf = Join-Path $StateDir 'phases.json'
  if (-not (Test-Path $sf)) { return @{} }
  try { return (Get-Content $sf -Raw | ConvertFrom-Json) } catch { return @{} }
}
function Set-PhaseDone($name) {
  try {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir -EA Stop | Out-Null }
    $sf = Join-Path $StateDir 'phases.json'
    $data = @{}
    if (Test-Path $sf) {
      try { $obj = Get-Content $sf -Raw | ConvertFrom-Json; foreach ($p in $obj.PSObject.Properties) { $data[$p.Name] = $p.Value } } catch {}
    }
    $data[$name] = (Get-Date).ToString('o')
    ($data | ConvertTo-Json) | Set-Content -Path $sf -Encoding UTF8 -EA Stop
  } catch { Log "  WARN state write $name`: $_" }
}
function Test-PhaseDone($name) {
  if ($Force) { return $false }
  $st = Get-PhaseState
  if ($st -and ($st.PSObject.Properties.Name -contains $name)) { return $true }
  return $false
}
# idempotency is opt-in (-Idempotent). without it every phase runs like before.
function Should-Run($phase) {
  if (-not $Idempotent) { return $true }
  if (Test-PhaseDone $phase) { Log "  skip (done): $phase"; return $false }
  return $true
}
function Complete-Phase($phase) {
  # dry-run changed nothing, so nothing is done.
  if ($Idempotent -and -not $DryRun) { Set-PhaseDone $phase }
}

# optional sha256 check for downloaded installers. config/hashes.json maps an
# asset name (or glob) to a hex sha256. empty/missing config = nothing checked,
# downloads proceed as before. a mismatch tosses the file so retry re-downloads.
function Get-ExpectedHash($name) {
  if (-not $name) { return $null }
  $hf = Join-Path $Repo 'config\hashes.json'
  if (-not (Test-Path $hf)) { return $null }
  try {
    $map = Get-Content $hf -Raw | ConvertFrom-Json
    foreach ($p in $map.PSObject.Properties) {
      if ($name -like $p.Name) { return [string]$p.Value }
    }
  } catch {}
  return $null
}
function Test-DownloadHash($file) {
  if ($SkipHashVerify) { return $true }
  $exp = Get-ExpectedHash (Split-Path $file.FullName -Leaf)
  if (-not $exp) { return $true }
  try {
    $actual = (Get-FileHash -Algorithm SHA256 -Path $file.FullName -EA Stop).Hash
    if ($actual.ToUpper() -eq $exp.ToUpper()) { Log "  hash ok: $($file.Name)"; return $true }
    Log "  WARN hash MISMATCH $($file.Name): got $actual want $exp - tossing."
    Remove-Item $file.FullName -Force -EA SilentlyContinue
    return $false
  } catch { Log "  WARN hash check $($file.Name): $_"; return $true }
}
# native exes don't throw, and Start-Process never sets $LASTEXITCODE at all
# (verified: stale code survives it). everything native goes through here.
# returns the real exit code, -1 if it never even launched.
function Invoke-Native {
  param(
    [scriptblock]$cmd,
    [object[]]$ArgList
  )
  $LASTEXITCODE = 0
  $oldEA = $ErrorActionPreference; $ErrorActionPreference = 'Stop'
  try {
    if ($PSBoundParameters.ContainsKey('ArgList') -and $null -ne $ArgList) { & $cmd @ArgList 2>&1 | Out-Null }
    else { & $cmd 2>&1 | Out-Null }
    return $LASTEXITCODE
  }
  catch { return -1 }
  finally { $ErrorActionPreference = $oldEA }
}
# one download helper for every call site. three tries, a pause between them,
# and BITS takes over for big files when the service is alive (it retries on
# its own and survives rough links). $MinBytes guards the "0 byte success".
function Test-DownloadComplete($file, $minBytes, $expectedBytes) {
  if (-not (Test-Path $file)) { return $false }
  try {
    $len = (Get-Item $file).Length
    if ($minBytes -gt 0 -and $len -lt $minBytes) { return $false }
    if ($expectedBytes -gt 0 -and $len -ne $expectedBytes) { return $false }
    return $true
  } catch { return $false }
}
function Invoke-Download {
  param(
    [string]$Url,
    [string]$OutFile,
    [int]$TimeoutSec = 600,
    [long]$MinBytes = 1MB,
    [long]$ExpectedBytes = 0,
    [switch]$Force
  )
  if (-not $Url -or -not $OutFile) { return $false }
  if (-not $Force -and (Test-DownloadComplete $OutFile $MinBytes $ExpectedBytes)) { return $true }
  $oldProg = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try {
    for ($i = 1; $i -le 3; $i++) {
      Write-Progress -Activity 'downloading' -Status "$(Split-Path $OutFile -Leaf) (attempt $i/3)" -PercentComplete -1 -EA SilentlyContinue
      # a partial from a killed run confuses everything, toss it first
      try { if (Test-Path $OutFile) { Remove-Item $OutFile -Force -EA SilentlyContinue } } catch {}
      try {
        $bitsSvc = Get-Service BITS -EA SilentlyContinue
        if (($MinBytes -ge 20MB -or $ExpectedBytes -ge 20MB) -and $bitsSvc -and $bitsSvc.StartType -ne 'Disabled') {
          try { Start-BitsTransfer -Source $Url -Destination $OutFile -TransferType Download -EA Stop }
          catch {
            # bits breaks on some boxes (policies, dead queues). plain http does not care.
            Log "  BITS failed ($($_.Exception.Message)), plain download instead."
            Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec -EA Stop
          }
        } else {
          Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec -EA Stop
        }
      } catch {
        Log "  WARN download attempt $i failed: $($_.Exception.Message)"
        if ($i -lt 3) { Start-Sleep -Seconds (2 * $i) }
        continue
      }
      if (Test-DownloadComplete $OutFile $MinBytes $ExpectedBytes) { return $true }
      Log "  WARN download attempt $i left a bad file, retrying."
      if ($i -lt 3) { Start-Sleep -Seconds (2 * $i) }
    }
    return $false
  } finally {
    Write-Progress -Activity 'downloading' -Completed -EA SilentlyContinue
    $ProgressPreference = $oldProg
  }
}
function Test-Admin {
  ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
# charge cap decision, pure so the smoke test can poke it. skip / keep / set.
# only a positive ON counts as already-limited; anything unparsed gets the cap set.
function Resolve-ChargeCapAction($Manufacturer, $DriverFound, $StatusText, $ExistingStart) {
  if ("$Manufacturer" -notmatch '(?i)LENOVO') { return @{ action='skip'; why='not a lenovo machine' } }
  if (-not $DriverFound) { return @{ action='skip'; why='lenovo PM driver missing (windows update usually brings it)' } }
  if ("$StatusText" -match '(?i)\bON\b') { return @{ action='keep' } }
  $start = 75
  if ($ExistingStart -and [int]$ExistingStart -gt 0 -and [int]$ExistingStart -lt $start) { $start = [int]$ExistingStart }
  return @{ action='set'; start=$start }
}
# the quickcss the first installs shipped. untouched (or empty) upgrades to the
# real theme; anything else counts as someone's edits and is kept.
function Test-QuickcssStale($Text) {
  $bare = (("$Text" -replace '\uFEFF', '') -replace '\s', '')
  if (-not $bare) { return $true }
  return ($bare -eq '/*QuickCSSplaceholder.StockVesktoplook.Addyourownrulesbelowifyouwantthem.*/')
}
$isAdmin = Test-Admin

# -Verify: read back the key tweaks and stop. no writes, safe any time,
# including after a reboot, to see what actually stuck.
if ($Verify) {
  Log 'Verify: reading back key tweaks (no changes)...'
  $checks = @(
    @{ n='telemetry policy';           p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection';                    k='AllowTelemetry';           w=0 }
    @{ n='long paths';                 p='HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem';                            k='LongPathsEnabled';         w=1 }
    @{ n='rtc in utc';                 p='HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation';                   k='RealTimeIsUniversal';      w=1 }
    @{ n='lsass protected';            p='HKLM:\SYSTEM\CurrentControlSet\Control\Lsa';                                   k='RunAsPPL';                 w=1 }
    @{ n='wdigest off';                p='HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest';            k='UseLogonCredential';       w=0 }
    @{ n='wpbt off';                   p='HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager';                       k='DisableWpbtExecution';     w=1 }
    @{ n='bitlocker auto-encrypt off'; p='HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker';                           k='PreventDeviceEncryption';  w=1 }
    @{ n='updates: notify first';      p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU';                 k='AUOptions';                w=2 }
    @{ n='delivery optimization off';  p='HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization';             k='DODownloadMode';           w=0 }
    @{ n='llmnr off';                  p='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient';                      k='EnableMulticast';          w=0 }
    @{ n='anonymous sam enum off';     p='HKLM:\SYSTEM\CurrentControlSet\Control\Lsa';                                   k='RestrictAnonymous';        w=1 }
    @{ n='ipv4 preferred';             p='HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters';                    k='DisabledComponents';       w=32 }
    @{ n='autorun off';                p='HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer';           k='NoDriveTypeAutoRun';       w=255 }
    @{ n='taskbar small icons';        p='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';           k='TaskbarSmallIcons';        w=1 }
    @{ n='clock seconds';              p='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced';           k='ShowSecondsInSystemClock'; w=1 }
    @{ n='dark mode (apps)';           p='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize';          k='AppsUseLightTheme';        w=0 }
    @{ n='toasts off';                 p='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications';           k='ToastEnabled';             w=0 }
    @{ n='background apps off';        p='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'; k='GlobalUserDisabled';       w=1 }
    @{ n='startup delay off';          p='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize';            k='StartupDelayInMSec';      w=0 }
    @{ n='idle wait off';              p='HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize';            k='WaitForIdleState';        w=0 }
  )
  $miss = 0
  foreach ($c in $checks) {
    $got = $null
    try {
      $item = Get-ItemProperty -Path $c.p -Name $c.k -EA Stop
      if ($item -and ($item.PSObject.Properties.Name -contains $c.k)) { $got = $item.$($c.k) }
    } catch {}
    if ("$got" -eq "$($c.w)") { Log "  ok: $($c.n)" }
    else { Log "  MISS: $($c.n) (have $(if ($null -eq $got) { 'unset' } else { $got }) want $($c.w))"; $miss++ }
  }
  # ported taste bit: the vscodium theme only exists after a configs run.
  try {
    $vsSet = Join-Path $env:APPDATA 'VSCodium\User\settings.json'
    if (Test-Path $vsSet) {
      $vsJson = Get-Content $vsSet -Raw | ConvertFrom-Json -EA Stop
      $ctProp = $vsJson.PSObject.Properties['workbench.colorTheme']
      if ($ctProp -and $ctProp.Value -eq 'Darkmatter') { Log '  ok: vscodium darkmatter theme' }
      else { Log '  MISS: vscodium darkmatter theme (re-run with -ConfigsOnly)'; $miss++ }
    } else { Log '  skip: vscodium theme (no settings.json yet, run -ConfigsOnly after vscodium first run)' }
  } catch { Log "  skip: vscodium theme check ($_)" }
  # win11 extras only land there, so only read them there. empty string is the
  # whole point for the context menu mask, so the plain compare above cannot do it.
  $vb = 0
  try { $vb = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name CurrentBuildNumber -EA Stop).CurrentBuildNumber } catch {}
  if ($vb -ge 22000) {
    $cmOk = $false
    try {
      $cm = Get-ItemProperty 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' -Name '(Default)' -EA Stop
      $cmOk = ($cm.PSObject.Properties.Name -contains '(Default)') -and ("$($cm.'(Default)')" -eq '')
    } catch {}
    if ($cmOk) { Log '  ok: classic context menu' } else { Log '  MISS: classic context menu (needs empty InprocServer32 default)'; $miss++ }
  }
  foreach ($svc in @('DiagTrack','dmwappushservice')) {
    $s = Get-Service $svc -EA SilentlyContinue
    if (-not $s) { Log "  ok: $svc absent" }
    elseif ($s.Status -eq 'Stopped' -and $s.StartType -eq 'Disabled') { Log "  ok: $svc disabled" }
    else { Log "  MISS: $svc still $($s.StartType)/$($s.Status)"; $miss++ }
  }
  try {
    $fwOff = @(Get-NetFirewallProfile -EA Stop | Where-Object { "$($_.Enabled)" -ne 'True' })
    if ($fwOff.Count -eq 0) { Log '  ok: firewall on (all profiles)' }
    else { Log ('  MISS: firewall off on ' + (($fwOff | ForEach-Object { $_.Name }) -join ', ')); $miss++ }
  } catch { Log "  skip: firewall check ($_)" }
  if ($miss) { Log "Verify: $miss thing(s) missing. re-run the installer to reapply." } else { Log 'Verify: all good.' }
  if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch {} }
  exit $(if ($miss) { 1 } else { 0 })
}

# one-shot task from FirstBoot already fired. remove it so it never refires.
if ($DryRun) { Log '  [dry-run] would remove the one-shot Win-Iot-Setup scheduled task.' }
else { try { Unregister-ScheduledTask -TaskName 'Win-Iot-Setup' -Confirm:$false -EA Stop } catch {} }
if (-not $isAdmin) { Log 'WARN: not admin. fonts and autostart will probably fail.' }

# os + hardware. keeps edition/ltsc/arch detect + optional hw gate.
# declared out here so the run report can read it even if the probe throws.
$osInfo = $null
try {
  $b = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild
  Log "OS build: $b"
  if (Get-Command Get-OSInfo -EA SilentlyContinue) { $osInfo = Get-OSInfo }
  if ($osInfo) {
    Log ("OS: {0} {1} ({2}) arch={3}" -f $osInfo.ProductName, $osInfo.Version, $osInfo.Build, $osInfo.Architecture)
    $family = if ($osInfo.IsWin11) { 'Win11' } else { 'Win10' }
    # name the ltsc family plainly so a 10 box and an 11 box both read right.
    if ($osInfo.IsWin10LTSC -or $osInfo.IsWin11LTSC) { Log "  $family LTSC/IoT detected ($($osInfo.Build))." }
    elseif ($osInfo.IsLTSC -or $osInfo.IsIoT) { Log "  LTSC/IoT edition detected ($family $($osInfo.Build))." }
    else { Log "  WARN: not an LTSC/IoT edition ($family $($osInfo.Build)). going ahead anyway." }
    # tweaks are one set for both 10 and 11 ltsc. a few win11 extras (classic
    # context menu, widgets/chat buttons, copilot/recall off) ride the tweaks
    # phase on 11 only, and the log says which way it went.
  }
  # known ltsc builds: 17763 = win10 iot ltsc 2019, 19044 = win10 iot ltsc 2021,
  # 26100 = win11 (iot) enterprise ltsc 2024. anything else, warn + keep going.
  $knownLtsc = @('17763', '19044', '26100')
  if ($osInfo -and ($osInfo.IsLTSC -or $osInfo.IsIoT) -and ($knownLtsc -notcontains [string]$b)) { Log "WARN: LTSC build $b not in known list. going ahead anyway, watch the log." }
} catch { Log "WARN: OS check failed: $_" }
# gate for the win11-only tweaks. osInfo can be absent (lib/ missing), in which
# case read the raw build number so the gate still makes the right call.
$isWin11 = $false
if ($osInfo) { $isWin11 = [bool]$osInfo.IsWin11 }
else {
  try { $isWin11 = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuild -ge 22000 } catch {}
}

# arch gate: this repo assumes x64. warn loudly if someone runs it on arm32.
if ($env:PROCESSOR_ARCHITECTURE -and $env:PROCESSOR_ARCHITECTURE -ne 'AMD64') {
  Log "WARN: PROCESSOR_ARCHITECTURE=$env:PROCESSOR_ARCHITECTURE, repo is x64-only. downloads may not match."
}
if ($Arch -and $Arch -ne 'x64' -and $Arch -ne 'amd64') { Log "WARN: -Arch $Arch given, x64 is the only tested target." }

# optional hardware sanity. never blocks, just reports so you know before a 20 min run.
if ($DetectHardware -and (Get-Command Test-HardwareMin -EA SilentlyContinue)) {
  $hw = Test-HardwareMin
  if ($hw.OK) { Log ("Hardware: {0} / {1} GB RAM" -f $hw.CPU, $hw.MemoryGB) }
  else { Log 'WARN: hardware detection failed (wmi gutted?).' }
}

# ---------- phase 0b. template-generated answer file (build-time parity) ----------
# templates/autounattend.xml.tpl is the source of truth now. if it exists and
# -SkipTemplateGen was not passed, render ISO/autounattend.xml from it so the
# repo copy can never drift from the template. ventoy copy stays a manual mirror.
if ((-not $SkipTemplateGen) -and (-not $TweaksOnly) -and (-not $ConfigsOnly) -and (-not $Unattended) -and (-not $DryRun)) {
  $tpl = Join-Path $Repo 'templates\autounattend.xml.tpl'
  if (Test-Path $tpl) {
    try {
      $cfg = $null
      $cfgPath = Join-Path $Repo 'templates\build-config.json'
      if (Test-Path $cfgPath) { $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json }
      $userName = if ($cfg -and $cfg.username) { $cfg.username } else { 'My Pc' }
      $arch = if ($Arch) { $Arch } elseif ($cfg -and $cfg.arch) { $cfg.arch } else { 'amd64' }
      $inLoc = if ($cfg -and $cfg.locales.input) { $cfg.locales.input } else { '0409:00000409' }
      $sysLoc = if ($cfg -and $cfg.locales.system) { $cfg.locales.system } else { 'en-US' }
      $uiLoc = if ($cfg -and $cfg.locales.ui) { $cfg.locales.ui } else { 'en-US' }
      $userLoc = if ($cfg -and $cfg.locales.user) { $cfg.locales.user } else { 'en-001' }
      $body = [string](Get-Content $tpl -Raw)
      $body = $body.Replace('{{ARCH}}', $arch).Replace('{{USERNAME}}', $userName).Replace('{{INPUT_LOCALE}}', $inLoc).Replace('{{SYSTEM_LOCALE}}', $sysLoc).Replace('{{UILANGUAGE}}', $uiLoc).Replace('{{USERLOCALE}}', $userLoc)
      $outXml = Join-Path $Repo 'ISO\autounattend.xml'
      # [string] cast: Get-Content -Raw gives $null on an empty file, and $null.TrimEnd() throws.
      $existing = if (Test-Path $outXml) { [string](Get-Content $outXml -Raw) } else { '' }
      # compare trimmed: a trailing newline is no reason to rewrite every run.
      if ($body.TrimEnd() -ne $existing.TrimEnd()) {
        # writealltext: no bom, no added newline, so the next run compares equal.
        if (Test-Path (Split-Path $outXml)) { [System.IO.File]::WriteAllText($outXml, $body); Log '  autounattend.xml regenerated from template.' }
      } else { Log '  autounattend.xml already matches template.' }
    } catch { Log "  WARN template gen: $_" }
  }
}

if ((-not $Unattended) -and (-not $DryRun)) {
  try { Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Force -EA SilentlyContinue } catch {}
}

# no net + no OfflineDir means nothing to install. say so now, not 20 min in.
# probe ip is just a beacon, works even when dns is broken.
$netProbe = '1.1.1.1'
$online = $false
try { $online = Test-Connection -ComputerName $netProbe -Count 1 -Quiet -EA Stop } catch {}
if (-not $online -and -not $OfflineDir) {
  Log 'WARN: no network detected and no -OfflineDir given.'
  Log '  plug phone in for usb tethering, or seed ISO/Offline via Get-Offline.ps1 on an online PC'
  Log "  and re-run with: -OfflineDir '<path-to-Offline>' -Unattended"
}
if (-not $online) { Log 'OFFLINE mode: online engines skipped; pre-seeded files still apply.' }

# fresh boot almost never has DHCP yet. usb tethering takes a few min to enable,
# so wait up to 10 min or winget dies for no reason.
# tweaks need no net, so tweaks-only skips the wait entirely.
# dry-run installs nothing, so it skips the wait too.
if ((-not $online) -and (-not $TweaksOnly) -and (-not $ConfigsOnly) -and (-not $DryRun)) {
  $waited = 0
  while (-not $online -and $waited -lt 600) {
    Start-Sleep -Seconds 15; $waited += 15
    try { $online = Test-Connection -ComputerName $netProbe -Count 1 -Quiet -EA Stop } catch {}
  }
  if ($online) { Log "network up after ${waited}s." }
  else { Log 'WARN: still offline after 10 min - continuing with pre-seeded files only.' }
}

# preflight: cheap checks now beat a 20 min run dying at download #7.
try {
  $sysDrive = Get-PSDrive ($env:SystemDrive -replace ':','') -EA Stop
  $freeGB = [math]::Round($sysDrive.Free / 1GB, 1)
  if ($freeGB -lt 1.5) { Log "WARN: only $freeGB GB free on $env:SystemDrive. installs will likely fail." }
  elseif ($freeGB -lt 4) { Log "WARN: $freeGB GB free on $env:SystemDrive. tight for downloads + installs." }
  else { Log "disk: $freeGB GB free on $env:SystemDrive." }
} catch { Log "WARN: disk check: $_" }
if ($OfflineDir) {
  if (-not (Test-Path $OfflineDir)) { Log "WARN: -OfflineDir not found: $OfflineDir" }
  else {
    $staged = @(Get-ChildItem $OfflineDir -Recurse -File -EA SilentlyContinue)
    if ($staged.Count -eq 0) { Log "WARN: -OfflineDir is empty: $OfflineDir" }
    else { Log "offline: $($staged.Count) staged files in $OfflineDir." }
  }
}

# ---------- 0. repairs. opt-in only (-Fixes), runs before everything. ----------
if ($Fixes) {
  Log 'Repairs...'
  Start-Phase 'repairs'
  if ($DryRun) {
    Log '  [dry-run] would flush dns, restart Dnscache/NlaSvc, reset winsock, park the update caches.'
  } else {
    $exit = Invoke-Native { ipconfig /flushdns }
    if ($exit -eq 0) { Log '  dns cache flushed.' } else { Log "  WARN flushdns exit=$exit" }
    try {
      foreach ($svc in @('Dnscache','NlaSvc')) {
        if (Get-Service $svc -EA SilentlyContinue) { Restart-Service $svc -Force -EA Stop; Log "  svc restarted: $svc" }
      }
    } catch { Log "  WARN net services: $_" }
    $exit = Invoke-Native { netsh winsock reset }
    if ($exit -eq 0) { Log '  winsock reset (needs the reboot at the end).' } else { Log "  WARN winsock exit=$exit" }
    if ($isAdmin) {
      # update stack reset. stops services, parks the caches aside, starts over.
      try {
        foreach ($svc in @('wuauserv','bits','cryptsvc')) { Stop-Service $svc -Force -EA SilentlyContinue }
        foreach ($d in @('C:\Windows\SoftwareDistribution','C:\Windows\System32\catroot2')) {
          if ((Test-Path $d) -and -not (Test-Path "$d.bak")) { Rename-Item $d "$d.bak" -Force -EA Stop; Log "  parked: $d" }
        }
        foreach ($svc in @('cryptsvc','bits','wuauserv')) { Start-Service $svc -EA SilentlyContinue }
        Log '  update stack reset.'
      } catch { Log "  WARN update reset: $_" }
    } else { Log '  update reset needs admin. skipped.' }
  }
  Stop-Phase
  Complete-Phase 'repairs'
}

# ---------- 1. sane defaults first. hardening lands before gigabytes of downloads. ----------
# win10 updates come as one blob, no security-only split exists.
# LTSC + "tell me first" + no surprise reboots + no driver pushes. good enough.
function Set-Reg($path, $name, $value, $type = 'DWord') {
  if ($DryRun) { Log "  [dry-run] would set ${path}\${name} = $value"; return }
  try {
    # HKU: drive never exists by default. mount it once or the .DEFAULT key dies.
    if ($path -like 'HKU:*' -and -not (Get-PSDrive HKU -EA SilentlyContinue)) {
      New-PSDrive -Name HKU -PSProvider Registry -Root HKEY_USERS -EA Stop | Out-Null
    }
    if (-not (Test-Path $path)) { New-Item -Path $path -Force -EA Stop | Out-Null }
    New-ItemProperty -Path $path -Name $name -Value $value -PropertyType $type -Force -EA Stop | Out-Null
  } catch { Log "  WARN reg ${path}\${name}: $_" }
}
# dns providers. dhcp hands the address, -Dns picks who answers. Auto/DHCP = leave it alone.
# AdGuard + NextDNS are the filtering resolvers, opt-in via -AdGuard / -NextDNS.
$dnsMap = @{
  'Cloudflare' = @('1.1.1.1','1.0.0.1')
  'Google' = @('8.8.8.8','8.8.4.4')
  'Quad9' = @('9.9.9.9','149.112.112.112')
  'AdGuard' = @('94.140.14.14','94.140.15.15')
  'AdGuardFamily' = @('94.140.14.15','94.140.15.16')
  'NextDNS' = @('45.90.28.0','45.90.30.0')
  'Auto' = @()
  'DHCP' = @()
}
# explicit adblock switches win over -Dns, since they name a specific resolver.
if ($AdGuard) { $Dns = 'AdGuard' }
if ($NextDNS) { $Dns = 'NextDNS' }
if ($DNSAuto -and -not $AdGuard -and -not $NextDNS -and -not $PSBoundParameters.ContainsKey('Dns')) { $Dns = 'Auto' }
if ((-not $NoTweaks) -and (Should-Run 'tweaks')) {
  Log 'Sane defaults...'
  Start-Phase 'tweaks'
  if ($isAdmin -and -not $NoBackup) {
    if ($DryRun) {
      Log '  [dry-run] would export policy + lsa keys to a reg-backup folder.'
    } else {
      $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
      $regbak = Join-Path $LogDir "RegBackups-$stamp"
      try {
        New-Item -ItemType Directory -Force -Path $regbak -EA Stop | Out-Null
        $exports = @(
          'HKLM\SOFTWARE\Policies',
          'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies',
          'HKLM\SYSTEM\CurrentControlSet\Control\Lsa'
        )
        foreach ($r in $exports) {
          $out = Join-Path $regbak ($r -replace '\\','_').Replace(':','').ToLower() + '.reg'
          $null = Invoke-Native { param($root,$f); reg export $root $f /y } -ArgList $r,$out
        }
        $hkcuOut = Join-Path $regbak 'hkcu_software_policies.reg'
        $null = Invoke-Native { param($f); reg export 'HKCU\SOFTWARE\Policies' $f /y } -ArgList $hkcuOut
        Log "Reg-backup: $regbak"
      } catch {
        Log "WARN reg-backup failed: $_"
      }
    }
  } elseif ($isAdmin -and $NoBackup) {
    Log 'Reg-backup skipped (-NoBackup).'
  }
  if ($isAdmin) {
    # restore point first. tiny10 usually ripped system restore out, so don't hold your breath.
    if (-not $NoBackup) {
      if ($DryRun) { Log '  [dry-run] would create a restore point.' }
      else {
        try { Checkpoint-Computer -Description 'Win-Iot-Setup pre-tweaks' -RestorePointType MODIFY_SETTINGS -EA Stop; Log '  restore point created.' }
        catch { Log '  WARN restore point: unavailable (common on tiny10) - continuing.' }
      }
    } else {
      Log '  restore point skipped (-NoBackup).'
    }
    # O&O ShutUp10++ next, our reg values after, so ours win any overlap.
    if (-not $SkipOOSU) {
      if ($DryRun) { Log '  [dry-run] would run O&O ShutUp10++ with the titus cfg.' }
      else {
        try {
          $oosu = Join-Path $Repo 'OOSU\OOSHUTUP10.exe'
          $oocfg = Join-Path $Repo 'OOSU\ooshutup10.cfg'
          if ((Test-Path $oosu) -and (Test-Path $oocfg)) {
            Log '  O&O ShutUp10++ applying cfg...'
            $proc = Start-Process -FilePath $oosu -ArgumentList '/quiet','/cfg',$oocfg -Wait -PassThru
            if ($proc.ExitCode -eq 0) { Log '  O&O applied.' } else { Log "  WARN O&O exit=$($proc.ExitCode)" }
          } else { Log '  O&O skipped (exe/cfg missing from OOSU/).' }
        } catch { Log "  WARN O&O: $_" }
      }
    } else {
      Log '  O&O ShutUp10++ skipped (-SkipOOSU).'
    }
    # 0 means security-level. only enterprise SKUs honor it, and this is one.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' 'AllowTelemetry' 0
    foreach ($svc in @('DiagTrack','dmwappushservice')) {
      if ($DryRun) { Log "  [dry-run] would disable: $svc"; continue }
      try { Stop-Service $svc -Force -EA SilentlyContinue; Set-Service $svc -StartupType Disabled -EA Stop; Log "  svc disabled: $svc" }
      catch { Log "  WARN svc ${svc}: $_" }
    }
    # titus sets these to manual. only touching ones that exist and don't matter.
    foreach ($svc in @('MapsBroker','lfsvc','XblAuthManager','XblGameSave','XboxGipSvc','XboxNetApiSvc','RetailDemo','WalletService','wisvc','CDPSvc')) {
      if ($DryRun) { Log "  [dry-run] would set to manual if present: $svc"; continue }
      try {
        if (Get-Service $svc -EA SilentlyContinue) { Set-Service $svc -StartupType Manual -EA Stop; Log "  svc manual: $svc" }
      } catch { Log "  WARN svc ${svc}: $_" }
    }
    # bluescreens say what actually broke. two keys, zero cost.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'DisplayParameters' 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl' 'DisableEmoticon' 1
    # svchost split matched to ram. fewer idle processes hanging around.
    if ($DryRun) { Log '  [dry-run] would match the svchost split threshold to ram.' }
    else {
      try {
        $memKB = (Get-CimInstance Win32_PhysicalMemory -EA Stop | Measure-Object Capacity -Sum).Sum / 1KB
        Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control' -Name 'SvcHostSplitThresholdInKB' -Value ([uint32]$memKB) -EA Stop
        Log '  svchost split matched to ram.'
      } catch { Log "  WARN svchost split: $_" }
    }
    # tell-me-first updates, no reboot while logged in, and windows keeps its hands off my drivers.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'AUOptions' 2
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'ExcludeWUDriversInQualityUpdate' 1
    # machine-side privacy.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'EnableActivityFeed' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'PublishUserActivities' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' 'UploadUserActivities' 0
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    # recently-added group gone from start. the a-z list stays, the noise goes.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'HideRecentlyAddedApps' 1
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'AllowCortana' 0
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting' 'Disabled' 1
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' 'LongPathsEnabled' 1
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'NoDriveTypeAutoRun' 255
    # verbose boot messages + numlock on at login. admin-only keys, live with the rest up here.
    Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'VerboseStatus' 1
    Set-Reg 'HKU:\.DEFAULT\Control Panel\Keyboard' 'InitialKeyboardIndicators' '2' 'String'
    # no peer-to-peer update uploads on lab and metered nets.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization' 'DODownloadMode' 0
    # block silent auto-encryption. the service itself stays, untouched.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker' 'PreventDeviceEncryption' 1
    # location tracking off
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors' 'DisableLocation' 1
    # news+interests dies at policy level too, not just the taskbar toggle below.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' 0
    # no lock screen swipe. straight to logon, faster unlocks.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 1
    # usb selective suspend off. stops ch340/cp210x serial drops on the bench.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\USB' 'DisableSelectiveSuspend' 1
    # WPBT lets vendor blobs run at boot. off.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' 'DisableWpbtExecution' 1
    # teredo off. xbox tunneling only, pure attack surface otherwise.
    if ($DryRun) { Log '  [dry-run] would turn teredo off.' }
    else {
      $exit = Invoke-Native { netsh interface teredo set state disabled }
      if ($exit -eq 0) { Log '  teredo off.' } else { Log "  WARN teredo exit=$exit" }
    }
    # clock reads RTC as UTC. dual-boot friendly, linux does the same.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\TimeZoneInformation' 'RealTimeIsUniversal' 1
    # clock may be off after the rtc flip. sync once when online, warn and move on.
    if ($online) {
      if ($DryRun) { Log '  [dry-run] would resync the clock.' }
      else {
        $exit = Invoke-Native { w32tm /resync }
        if ($exit -eq 0) { Log '  clock synced.' } else { Log "  WARN clock sync exit=$exit (syncs on its own later)" }
      }
    }
    # plan: laptop -> balanced, desktop -> ultimate if the sku carries it, high perf
    # otherwise. a desk with a ups also reports a battery, so trust the system type
    # first and only fall back to the battery count.
    $isLaptop = $false
    try {
      $sysType = (Get-CimInstance Win32_ComputerSystem -EA Stop).PCSystemType
      if ($sysType) { $isLaptop = ([int]$sysType -eq 2) }
      else { $isLaptop = @(Get-CimInstance Win32_Battery -EA Stop).Count -gt 0 }
    } catch { try { $isLaptop = @(Get-CimInstance Win32_Battery -EA Stop).Count -gt 0 } catch {} }
    if ($isLaptop) {
      if ($DryRun) { Log '  [dry-run] would keep the balanced power plan (laptop here).' }
      else {
        $exit = Invoke-Native { powercfg /setactive 381b4222-f694-41f0-9685-ff5bb260df2e }
        if ($exit -eq 0) { Log '  power: balanced (laptop found, that one is on purpose).' } else { Log "  WARN power plan exit=$exit" }
      }
    }
    elseif ($DryRun) { Log '  [dry-run] would switch to the ultimate/high performance power plan.' }
    else {
      $exit = Invoke-Native { powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 }
      if ($exit -eq 0) { $exit = Invoke-Native { powercfg /setactive e9a42b02-d5df-448d-aa00-03f14749eb61 } }
      if ($exit -eq 0) { Log '  power: ultimate performance.' }
      else {
        $exit = Invoke-Native { powercfg /setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c }
        if ($exit -eq 0) { Log '  power: high performance.' } else { Log "  WARN power plan exit=$exit" }
      }
    }
    # battery manners, straight off the linux box: screen dies fast on cells,
    # sleep after half an hour on battery, never while plugged in.
    if ($DryRun) { Log '  [dry-run] would set screen/sleep timeouts (screen 3/10 min, sleep 30 min on battery, never on ac).' }
    else {
      $ok = $true
      $exit = Invoke-Native { powercfg /change monitor-timeout-dc 3 };   if ($exit -ne 0) { $ok = $false; Log "  WARN monitor-timeout-dc exit=$exit" }
      $exit = Invoke-Native { powercfg /change monitor-timeout-ac 10 };  if ($exit -ne 0) { $ok = $false; Log "  WARN monitor-timeout-ac exit=$exit" }
      $exit = Invoke-Native { powercfg /change standby-timeout-dc 30 };  if ($exit -ne 0) { $ok = $false; Log "  WARN standby-timeout-dc exit=$exit" }
      $exit = Invoke-Native { powercfg /change standby-timeout-ac 0 };   if ($exit -ne 0) { $ok = $false; Log "  WARN standby-timeout-ac exit=$exit" }
      if ($ok) { Log '  power: screen 3/10 min, sleep 30 min on battery, never on ac.' }
    }
    if ($isLaptop) {
      # lid: suspend on battery, do nothing while docked. guids are the standard button-action pair.
      if ($DryRun) { Log '  [dry-run] would set lid action: suspend on battery, nothing on ac.' }
      else {
        $lidSub = '4f971e89-eebd-4455-a8de-9e59040e7347'
        $lidVal = '5ca83367-6e45-459f-a27b-476b1d01c936'
        $exit = Invoke-Native { powercfg /setdcvalueindex SCHEME_CURRENT $lidSub $lidVal 1 }
        if ($exit -eq 0) { $exit = Invoke-Native { powercfg /setacvalueindex SCHEME_CURRENT $lidSub $lidVal 0 } }
        if ($exit -eq 0) { $exit = Invoke-Native { powercfg /setactive SCHEME_CURRENT } }
        if ($exit -eq 0) { Log '  lid: suspend on battery, stay awake on ac.' } else { Log "  WARN lid action exit=$exit" }
      }
    }
    # thinkpad charge cap, 80/75 like tlp on the linux box. lenovo only, and only
    # when the power driver shows up. lenovo's own little chargethreshold.exe does
    # it, no vantage install. firmware-level, so it survives reboots and dual boot.
    if (-not $SkipBatteryCap) {
      $manufacturer = ''
      try { $manufacturer = "$((Get-CimInstance Win32_ComputerSystem -EA Stop).Manufacturer)" } catch {}
      $pmDriver = $false
      try { $pmDriver = (Test-Path 'HKLM:\SOFTWARE\WOW6432Node\Lenovo\PWRMGRV') -or [bool](Get-Service IBMPMDRV -EA SilentlyContinue) } catch {}
      $cap = Resolve-ChargeCapAction -Manufacturer $manufacturer -DriverFound $pmDriver -StatusText '' -ExistingStart $null
      if ($cap.action -eq 'skip') { Log "  charge cap: $($cap.why), skipped." }
      elseif ($DryRun) { Log '  [dry-run] would set the lenovo charge cap to 80/75 (already-limited state kept).' }
      else {
        $ctExe = Join-Path $env:TEMP 'ChargeThreshold.exe'
        $ctUrl = 'https://download.lenovo.com/pccbbs/thinkvantage_en/metroapps/Vantage/ChargeThreshold/ChargeThreshold.exe'
        # sha256 pinned in config/hashes.json, lenovo signature on top of that.
        $got = Invoke-Download -Url $ctUrl -OutFile $ctExe -MinBytes 50KB -TimeoutSec 120
        if ($got) {
          $ctItem = Get-Item $ctExe -EA SilentlyContinue
          if ($ctItem -and (-not (Test-DownloadHash $ctItem))) {
            # mismatch tossed the file. one clean retry, then give up.
            $got = Invoke-Download -Url $ctUrl -OutFile $ctExe -MinBytes 50KB -TimeoutSec 120 -Force
            if ($got) {
              $ctItem = Get-Item $ctExe -EA SilentlyContinue
              $got = [bool]($ctItem -and (Test-DownloadHash $ctItem))
            }
          }
        }
        if (-not $got) {
          Log '  WARN charge cap: download failed or hash mismatch, skipped.'
        } else {
          $sig = $null
          try { $sig = Get-AuthenticodeSignature $ctExe -EA Stop } catch {}
          if (-not $sig -or $sig.Status -ne 'Valid' -or "$($sig.SignerCertificate.Subject)" -notmatch 'Lenovo') {
            Log '  WARN charge cap: exe failed the lenovo signature check, skipped.'
          } else {
            # lower start percentages were a deliberate choice on boxes that had
            # one (60 instead of 75). keep them, same rule as the linux script.
            $ckBase = 'HKLM:\SOFTWARE\WOW6432Node\Lenovo\PWRMGRV\ConfKeys\Data'
            $existing = $null
            foreach ($sub in @(Get-ChildItem $ckBase -EA SilentlyContinue)) {
              $cur = $null
              try { $cur = (Get-ItemProperty -Path $sub.PSPath -Name 'ChargeStartPercentage' -EA SilentlyContinue).ChargeStartPercentage } catch {}
              if ($cur -and (-not $existing -or [int]$cur -lt [int]$existing)) { $existing = [int]$cur }
            }
            $statusText = (& $ctExe status 2>&1 | Out-String)
            $cap = Resolve-ChargeCapAction -Manufacturer $manufacturer -DriverFound $true -StatusText $statusText -ExistingStart $existing
            if ($cap.action -eq 'keep') {
              $capLine = (($statusText -split "`r?`n" | Where-Object { $_.Trim() }) -join ' | ')
              Log "  charge cap: already limited, left as-is ($capLine)"
            } else {
              & $ctExe on 80 $cap.start | Out-Null
              $onExit = $LASTEXITCODE
              if ($onExit -ne 0) { Log "  WARN charge cap: set exit=$onExit" }
              $after = (& $ctExe status 2>&1 | Out-String)
              if ($after -match '(?i)\bOFF\b') {
                # known lenovo driver bug: the pwr mgrv reg values are missing so
                # the write reads back off. fill them in and ask once more.
                try {
                  foreach ($sub in @(Get-ChildItem $ckBase -EA Stop)) {
                    New-ItemProperty -Path $sub.PSPath -Name 'ChargeStartControl' -Value 1 -PropertyType DWord -Force -EA Stop | Out-Null
                    New-ItemProperty -Path $sub.PSPath -Name 'ChargeStartPercentage' -Value $cap.start -PropertyType DWord -Force -EA Stop | Out-Null
                    New-ItemProperty -Path $sub.PSPath -Name 'ChargeStopControl' -Value 1 -PropertyType DWord -Force -EA Stop | Out-Null
                    New-ItemProperty -Path $sub.PSPath -Name 'ChargeStopPercentage' -Value 80 -PropertyType DWord -Force -EA Stop | Out-Null
                  }
                  & $ctExe on 80 $cap.start | Out-Null
                  $onExit = $LASTEXITCODE
                  $after = (& $ctExe status 2>&1 | Out-String)
                } catch { Log "  WARN charge cap reg fill: $_" }
              }
              # only a positive ON counts as a win. the exe can print nothing useful
              # and the driver loves a silent OFF.
              if ($after -match '(?i)\bON\b') {
                $capLine = (($after -split "`r?`n" | Where-Object { $_.Trim() }) -join ' | ')
                Log "  charge cap: lenovo set to 80/$($cap.start) ($capLine)"
              } elseif ($after -match '(?i)\bOFF\b') {
                Log '  WARN charge cap: hardware still reports OFF. set it by hand: ChargeThreshold.exe on 80 75'
              } else {
                Log "  WARN charge cap: could not confirm (exit=$onExit). read it yourself: ChargeThreshold.exe status"
              }
            }
          }
        }
      }
    } else { Log '  charge cap skipped (-SkipBatteryCap).' }
    # reserved storage off. small disks need those gigs back.
    if ($DryRun) { Log '  [dry-run] would turn reserved storage off.' }
    else {
      try { Set-WindowsReservedStorageState -State Disabled -EA Stop; Log '  reserved storage off.' }
      catch { Log "  WARN reserved storage: $_" }
    }
    # IPv4 preferred, IPv6 stays alive. full disable breaks things, this doesn't.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' 'DisabledComponents' 32
    # resolver from -Dns on every live adapter. Auto/DHCP resets to dhcp-supplied.
    try {
      if ($DryRun) {
        Log "  [dry-run] would set DNS ($Dns) on live adapters."
      } elseif ($DnsOffByDefault -and -not $PSBoundParameters.ContainsKey('Dns')) {
        Log '  DNS not changed (-DnsOffByDefault and no -Dns specified).'
      } else {
        $servers = $null
        # Auto probes resolvers and picks the fastest reachable one. offline or
        # module absent falls through to a plain DHCP reset just below.
        if ($Dns -eq 'Auto' -and (Get-Command Resolve-DnsBest -EA SilentlyContinue)) {
          $resolved = Resolve-DnsBest
          if ($resolved) {
            $Dns = $resolved.Provider
            $servers = $resolved.Servers
            Log ("  DNS auto: $($resolved.Provider) ($($resolved.LatencyMs)ms)")
          }
        }
        if (-not $servers -and $dnsMap.ContainsKey($Dns)) { $servers = $dnsMap[$Dns] }
        if ($Dns -eq 'Auto' -or $Dns -eq 'DHCP' -or -not $servers -or $servers.Count -eq 0) {
          $adapters = Get-NetAdapter -Physical -EA Stop | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Virtual*' }
          foreach ($a in $adapters) { Set-DnsClientServerAddress -InterfaceIndex $a.InterfaceIndex -ResetServerAddresses -EA SilentlyContinue }
          Log "  DNS: reset to automatic (DHCP)."
        } else {
          Get-NetAdapter -Physical -EA Stop | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notlike '*Virtual*' } | ForEach-Object {
            Set-DnsClientServerAddress -InterfaceIndex $_.InterfaceIndex -ServerAddresses $servers -EA Stop
          }
          Log "  DNS: $Dns on live adapters."
        }
      }
    } catch { Log "  WARN DNS: $_" }
    # notification center gone (toasts die per-user below).
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableNotificationCenter' 1
    # hardening. lan-spoofing + credential hygiene. lab-safe: bench gear talks
    # tcp/serial directly, none of it needs smb1, llmnr, netbios or wpad.
    # smb1 off. 90s protocol, ransomware's favorite door.
    try {
      if ($DryRun) { Log '  [dry-run] would remove SMB1 when present.' }
      else {
        $smb = Get-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -EA Stop
        if ($smb -and $smb.State -ne 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -NoRestart -EA Stop | Out-Null; Log '  SMB1 removed.' }
        else { Log '  SMB1 already gone.' }
      }
    } catch { Log "  WARN SMB1: $_" }
    # llmnr off. poisoned answers on lab lans start here.
    Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' 'EnableMulticast' 0
    # netbios off per live adapter. same reason, older protocol.
    try {
      if ($DryRun) { Log '  [dry-run] would turn netbios off on live adapters.' }
      else {
        Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled='TRUE'" -EA Stop | ForEach-Object {
          $r = Invoke-CimMethod -InputObject $_ -MethodName SetTcpipNetbios -Arguments @{ TcpipNetbiosOptions = [uint32]2 } -EA Stop
          if ($r.ReturnValue -in @(0,1)) { Log "  netbios off: $($_.Description)" }
          else { Log "  WARN netbios $($_.Description): ret=$($r.ReturnValue)" }
        }
      }
    } catch { Log "  WARN netbios: $_" }
    # anonymous sam enumeration off. default on win10, stated plainly.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RestrictAnonymous' 1
    # remote assistance off. nobody helps this box remotely.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' 'fAllowToGetHelp' 0
    # lsass runs protected. mimikatz-class tools bounce off.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'RunAsPPL' 1
    # wdigest cleartext creds off. normal logons don't need it.
    Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\WDigest' 'UseLogonCredential' 0
    # guest account stays off.
    try {
      if ($DryRun) { Log '  [dry-run] would disable the guest account.' }
      else {
        $g = Get-LocalUser -Name 'Guest' -EA Stop
        if ($g.Enabled) { Disable-LocalUser -Name 'Guest' -EA Stop; Log '  guest disabled.' }
        else { Log '  guest already off.' }
      }
    } catch { Log "  WARN guest: $_" }
    # firewall on, all profiles. we never punch holes, so nothing breaks.
    try {
      if ($DryRun) { Log '  [dry-run] would turn the firewall on (all profiles).' }
      else { Set-NetFirewallProfile -Profile Domain,Public,Private -Enabled True -EA Stop; Log '  firewall on (all profiles).' }
    }
    catch { Log "  WARN firewall: $_" }
    # defender realtime on if the trim kept it. enabling only, never disabling.
    try {
      if ($DryRun) { Log '  [dry-run] would make sure defender realtime is on.' }
      elseif (Get-Command Get-MpComputerStatus -EA SilentlyContinue) {
        Set-MpPreference -DisableRealtimeMonitoring $false -EA Stop; Log '  defender realtime on.'
      } else { Log '  defender absent on this trim. skipped.' }
    } catch { Log "  WARN defender: $_" }
    # defender skips the lab folders that exist. less rescanning big toolchains.
    # more later by hand: Add-MpPreference -ExclusionPath <dir>.
    try {
      if ($DryRun) { Log '  [dry-run] would add defender exclusions for lab folders.' }
      elseif (Get-Command Add-MpPreference -EA SilentlyContinue) {
        foreach ($ex in @('C:\Setup', "$env:ProgramFiles\MATLAB")) {
          if (Test-Path $ex) { Add-MpPreference -ExclusionPath $ex -EA Stop; Log "  defender exclusion: $ex" }
        }
      }
    } catch { Log "  WARN defender exclusions: $_" }
    if ($GamingTweaks) {
      Set-Reg 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'SystemResponsiveness' 0
      # hardware gpu scheduling. win10 2004+ with a wddm 2.7 driver, default on newer win11. reboot to take.
      Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2
      # pin the desktop scheduler shape (short quanta, 3:1 foreground). same as stock, immune to sku drift.
      Set-Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl' 'Win32PrioritySeparation' 38
      Log '  GamingTweaks applied (safe).'
    }
    if ($KeepFastStartup) {
      Log '  KeepFastStartup requested (no forced hibernate changes).'
    }
  } else { Log '  machine tweaks need admin. skipped.' }
  # per-user stuff, no admin needed.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 0
  # occasional start suggestions off. the win10 name for the same toggle.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'BingSearchEnabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'CortanaConsent' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'LaunchTo' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSyncProviderNotifications' 0
  Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
  if ($GamingTweaks) {
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AllowAutoGameMode' 1 -Type 'DWord'
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\GameBar' 'AutoGameModeEnabled' 1 -Type 'DWord'
    Set-Reg 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0 -Type 'DWord'
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 -Type 'DWord'
  }
  # feeds = win10's widgets. off.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Feeds' 'ShellFeedsTaskbarViewMode' 2
  # autostart apps normally sit and wait for an idle desktop. skip the wait.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'StartupDelayInMSec' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Serialize' 'WaitForIdleState' 0
  # win11 extras. inert-or-absent keys on 10, so they live in the gate. log says which way.
  if ($isWin11) {
    # widgets + chat buttons. nobody asked for either.
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarDa' 0
    Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 0
    # classic right-click menu: mask the win11 shell handler with an empty COM path.
    Set-Reg 'HKCU:\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '(Default)' '' 'String'
    # copilot and recall off. policies only, nothing uninstalled.
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    Set-Reg 'HKCU:\Software\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1
    # the recall policy documents device scope too. belt and braces when we can.
    if ($isAdmin) { Set-Reg 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' 'DisableAIDataAnalysis' 1 }
    Log '  win11 extras: classic context menu, widgets/chat buttons, copilot/recall off.'
  } else { Log '  win11 extras skipped (not win11).' }
  # store suggestions. does nothing on tiny10, costs nothing. leave it.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'DisableSearchBoxSuggestions' 1
  # stop explorer from re-guessing every folder's view type. your settings stay put.
  Set-Reg 'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags\AllFolders\Shell' 'FolderType' 'NotSpecified' 'String'
  # full path in explorer title bars. you always know where you are.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\CabinetState' 'FullPath' 1
  # win7 feel, native: This PC on the desktop, labelled My PC. needs logon to show.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\HideDesktopIcons\NewStartPanel' '{20D04FE0-3AEA-1069-A2D8-08002B30309D}' 0
  try {
    if ($DryRun) { Log '  [dry-run] would label the desktop icon My PC.' }
    else {
      $pcKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\CLSID\{20D04FE0-3AEA-1069-A2D8-08002B30309D}'
      if (-not (Test-Path $pcKey)) { New-Item -Path $pcKey -Value 'My PC' -Force -EA Stop | Out-Null }
      else { Set-ItemProperty -Path $pcKey -Name '(Default)' -Value 'My PC' -EA Stop }
      Log '  desktop icon: My PC.'
    }
  } catch { Log "  WARN desktop rename: $_" }
  # taskbar tuning with plain settings, no hooks: small icons, never combine so titles
  # show like sway workspaces, seconds in the clock, tray icons all out, junk
  # buttons gone, classic volume mixer and alt-tab, no aero shake.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarSmallIcons' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarGlomLevel' 2
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowSecondsInSystemClock' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'EnableAutoTray' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowCortanaButton' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ShowTaskViewButton' 0
  # search box off the taskbar. win key still searches, the box just wastes space.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Search' 'SearchboxTaskbarMode' 0
  # aero peek off. no more desktop flash when you park the mouse in the corner.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'DisablePreviewDesktop' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced\People' 'PeopleBand' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'HideSCAMeetNow' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\MTCUVC' 'EnableMtcUvc' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer' 'AltTabSettings' 1
  Set-Reg 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisallowShaking' 1
  # shiftx5 popup dies. you live on win+shift with a tiling wm.
  Set-Reg 'HKCU:\Control Panel\Accessibility\StickyKeys' 'Flags' '506' 'String'
  # alt-key underlines always on. keyboard-first box, no hunting.
  Set-Reg 'HKCU:\Control Panel\Accessibility\Keyboard Preference' 'On' '1' 'String'
  # taskbar locked. no accidental drags, still unlockable by right-click.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarSizeMove' 0
  # start tiles: one reset per profile. clears app-spam back to the default layout
  # (blank on iso installs). marker keeps re-runs and lived-in menus untouched.
  if ($Unattended -and -not (Get-ItemProperty 'HKCU:\Software\Win-Iot' -Name StartTilesDone -EA SilentlyContinue)) {
    if ($DryRun) { Log '  [dry-run] would reset the start tiles once.' }
    else {
      try {
        Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\CloudStore\Store\Cache\DefaultAccount' -Recurse -Force -EA Stop
        if (-not (Test-Path 'HKCU:\Software\Win-Iot')) { New-Item -Path 'HKCU:\Software\Win-Iot' -Force -EA Stop | Out-Null }
        New-ItemProperty -Path 'HKCU:\Software\Win-Iot' -Name StartTilesDone -Value 1 -PropertyType DWord -Force -EA Stop | Out-Null
        Log '  start tiles reset (applies on explorer restart below).'
      } catch { Log "  WARN tile reset: $_" }
    }
  }
  # stock colors stay. snappier menus below, nothing else visual.
  Set-Reg 'HKCU:\Control Panel\Desktop' 'MenuShowDelay' '100' 'String'
  # background apps: none. stuff runs when opened, not before.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' 'GlobalUserDisabled' 1
  # quiet box: toast popups off. (notification center itself dies machine-side above.)
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
  # dark mode, easier on the eyes. taskbar + apps go dark.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'SystemUsesLightTheme' 0
  # world formats, not us. dates and numbers stay unambiguous on shared docs.
  if ($DryRun) { Log '  [dry-run] would set formats to en-001.' }
  else {
    try { Set-Culture 'en-001' -EA Stop; Log '  formats: en-001 (world).' }
    catch { Log "  WARN formats: $_" }
  }
  # looks fast: best-performance preset, but keep ClearType or fonts turn to mush.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' 'VisualFXSetting' 2
  Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothing' '2' 'String'
  Set-Reg 'HKCU:\Control Panel\Desktop' 'FontSmoothingType' 2
  # balance, not scorched earth: kill animations + peek, keep shadows + content
  # dragging so it still looks right. (winutil goes further; readability loses.)
  Set-Reg 'HKCU:\Control Panel\Desktop\WindowMetrics' 'MinAnimate' '0' 'String'
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarAnimations' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'ListviewAlphaSelect' 0
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\DWM' 'EnableAeroPeek' 0
  # fastest key repeat. keyboard-first box, pays off daily.
  Set-Reg 'HKCU:\Control Panel\Keyboard' 'KeyboardDelay' 0
  # storage sense off. this box is managed by hand.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01' 0
  # no AI leftovers: inking + typing personalization off. copilot and recall
  # don't exist on win10 ltsc. opencode isn't windows, it stays.
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 1
  Set-Reg 'HKCU:\SOFTWARE\Microsoft\InputPersonalization' 'AllowInputPersonalization' 0
  Log '  NOTE: End-Task-with-right-click and Start-menu-layout are Win11-only - skipped on Win10.'
  # tweak matrix: optional config/tweak-matrix.json lists named tweaks + enabled.
  # it is advisory here (the real values already applied above), but it lets a
  # machine report which named bundles it considers on. missing file = no-op.
  $tmPath = Join-Path $Repo 'config\tweak-matrix.json'
  if (Test-Path $tmPath) {
    try {
      $tm = Get-Content $tmPath -Raw | ConvertFrom-Json
      if ($tm -and $tm.tweaks) {
        $on = @($tm.tweaks | Where-Object { $_.enabled } | ForEach-Object { $_.name })
        if ($on.Count) { Log ('  tweak matrix on: ' + ($on -join ', ')) }
      }
    } catch { Log "  WARN tweak matrix: $_" }
  }
  Log '  tweaks done.'
  Stop-Phase
  # taskbar reads most of that at logon. nudge explorer so it applies now, reboot covers the rest.
  if ($DryRun) { Log '  [dry-run] would restart explorer.' }
  else {
    try { Stop-Process -Name explorer -Force -EA Stop; Log '  explorer restarted.' }
    catch { Log '  explorer restart skipped (reboot applies everything).' }
  }
  Complete-Phase 'tweaks'
} elseif ($ConfigsOnly) { Log 'Tweaks skipped (configs-only).' } else { Log 'Tweaks skipped (-NoTweaks).' }

# strict-mode safe: Get-Command returns $null when missing, and
# $null.Source throws under Set-StrictMode. use this everywhere.
function Get-CmdPath($name) {
  $c = Get-Command $name -EA SilentlyContinue
  if ($c) { return $c.Source } else { return $null }
}
# ---------- 2. winget. tiny10 has no store so this is always missing at first. ----------
function Test-WingetRuns {
  # staged on disk != runnable. gutted appx leaves a dead exe behind.
  if (-not (Get-Command winget -EA SilentlyContinue)) { return $false }
  return ((Invoke-Native { winget --version }) -eq 0)
}
function Ensure-Winget {
  if (Test-WingetRuns) { Log 'winget: found.'; return $true }
  # store-licensed package already staged but exe not on PATH yet. happens after a half-done bootstrap.
  try {
    if (Get-AppxPackage -Name 'Microsoft.DesktopAppInstaller' -EA SilentlyContinue) {
      $env:Path += ';' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
      if (Test-WingetRuns) { Log 'winget: found (staged package, PATH fixed).'; return $true }
    }
  } catch {}
  if ($NoWingetBootstrap) { Log 'winget: missing, bootstrap skipped (-NoWingetBootstrap).'; return $false }
  if (-not $online) { Log 'winget: offline, bootstrap skipped. connect or stage -OfflineDir.'; return $false }
  Log 'winget: missing (normal here). Bootstrapping...'
  $tmp = Join-Path $env:TEMP 'winget-bootstrap'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  # appxsvc/clipsvc gutted or disabled on tiny10 = Add-AppxPackage hangs forever. try to wake them.
  # stripped AppX on purpose = winget impossible. bail fast, OfflineDir path below covers apps.
  if (-not (Get-Service AppXSvc -EA SilentlyContinue)) {
    Log 'winget: impossible here (AppXSvc stripped). use -NoWingetBootstrap -OfflineDir <path>.'
    return $false
  }
  foreach ($svc in @('AppXSvc','ClipSVC')) {
    try {
      $s = Get-Service $svc -EA SilentlyContinue
      if ($s -and $s.Status -ne 'Running') { Set-Service $svc -StartupType Manual -EA SilentlyContinue; Start-Service $svc -EA SilentlyContinue }
    } catch {}
  }
  # PS 5.1 renders a progress bar per byte on Invoke-WebRequest. 10x slower + looks stuck. off during bootstrap.
  $oldProg = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try {
    # skip what is already staged. reinstalling a newer-present appx is what hangs
    # on "Deployment operation progress ... Processing" for minutes.
    $deps = @(
      @{ name='VCLibs.x64.14.00.Desktop.appx'; url='https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx'; pkg='Microsoft.VCLibs.140.00.UWPDesktop' },
      @{ name='XAML.x64.appx'; url='https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx'; pkg='Microsoft.UI.Xaml.2.8' }
    )
    foreach ($d in $deps) {
      try {
        if (Get-AppxPackage -Name $d.pkg -EA SilentlyContinue) { Log "dep already present, skip: $($d.pkg)"; continue }
      } catch {}
      $p = Join-Path $tmp $d.name
      # last hung run leaves a 12MB partial. a corrupt appx just hangs Add-AppxPackage again, so toss small files.
      try { if ((Test-Path $p) -and ((Get-Item $p).Length -lt 1MB)) { Remove-Item $p -Force -EA SilentlyContinue; Log "  tossed partial: $($d.name)" } } catch {}
      $off = if ($OfflineDir) { Join-Path $OfflineDir $d.name } else { '' }
      if ($off -and (Test-Path $off)) { Copy-Item $off $p -Force; Log "dep (offline): $($d.name)" }
      elseif (-not (Test-Path $p)) {
        # one dead download must not nuke the whole bootstrap
        Log "downloading $($d.name) (slow link, wait)..."
        if (Invoke-Download -Url $d.url -OutFile $p -TimeoutSec 300) { Log "  got $($d.name) ($([math]::Round((Get-Item $p).Length/1MB,1)) MB)" }
        else { Log "WARN download $($d.name) failed after 3 tries"; continue }
      } else { Log "dep cached, using: $($d.name) ($([math]::Round((Get-Item $p).Length/1MB,1)) MB)" }
      try { Log "installing $($d.name) (1-3 min on hdd, wait)..."; Add-AppxPackage -Path $p -EA Stop; Log "installed: $($d.name)" }
      catch {
        # 0x80073D06 = newer version already in the image. that's fine, move on.
        if ("$_" -match '0x80073D06|higher version|already installed') { Log "dep already newer, ok: $($d.name)" }
        else { Log "WARN dep $($d.name): $_" }
      }
    }
    # winget 1.24+ needs WindowsAppRuntime 1.x or the msixbundle dies with 0x80073CF3.
    try {
      $warDone = $null -ne (Get-AppxPackage -Name 'Microsoft.WindowsAppRuntime.1.8' -EA SilentlyContinue)
      if (-not $warDone) {
        $warOff = $null
        if ($OfflineDir -and (Test-Path $OfflineDir)) {
          $warOff = Get-ChildItem $OfflineDir -Recurse -Include '*AppRuntime*','*appruntime*' -EA SilentlyContinue |
            Where-Object { $_.Extension -in @('.msix','.appx','.exe') } | Select-Object -First 1
        }
        if ($warOff -and $warOff.Extension -ne '.exe') {
          Add-AppxPackage -Path $warOff.FullName -EA Stop; Log "installed (offline): $($warOff.Name)"
        } elseif ($warOff) {
          $proc = Start-Process $warOff.FullName -ArgumentList '--quiet' -Wait -PassThru -EA Stop
          if ($proc.ExitCode -eq 0) { Log "installed (offline): $($warOff.Name)" }
          else { Log "WARN WindowsAppRuntime offline exit=$($proc.ExitCode)" }
        } else {
          $warExe = Join-Path $tmp 'windowsappruntimeinstall-x64.exe'
          try { if ((Test-Path $warExe) -and ((Get-Item $warExe).Length -lt 1MB)) { Remove-Item $warExe -Force -EA SilentlyContinue } } catch {}
          if (-not (Test-Path $warExe)) {
            Log 'downloading WindowsAppRuntime 1.8 (~80MB, slow link, wait)...'
            if (-not (Invoke-Download -Url 'https://aka.ms/windowsappsdk/1.8/latest/windowsappruntimeinstall-x64.exe' -OutFile $warExe)) { throw 'WindowsAppRuntime download failed after 3 tries' }
            Log "  got WindowsAppRuntime ($([math]::Round((Get-Item $warExe).Length/1MB,1)) MB)"
          } else { Log 'WindowsAppRuntime installer cached, using it.' }
          $proc = Start-Process $warExe -ArgumentList '--quiet' -Wait -PassThru -EA Stop
          if ($proc.ExitCode -eq 0) { Log 'installed: WindowsAppRuntime 1.8' }
          else { Log "WARN WindowsAppRuntime exit=$($proc.ExitCode) (winget may still fail with 0x80073CF3)" }
        }
      } else { Log 'dep already present, ok: WindowsAppRuntime 1.8' }
    } catch {
      if ("$_" -match '0x80073D06|already installed') { Log 'dep already newer, ok: WindowsAppRuntime' }
      else { Log "WARN WindowsAppRuntime: $_" }
    }
    $msix = Join-Path $tmp 'Microsoft.DesktopAppInstaller.msixbundle'
    $offMsix = if ($OfflineDir) { Get-ChildItem $OfflineDir -Recurse -Filter '*.msixbundle' -EA SilentlyContinue | Select-Object -First 1 } else { $null }
    if ($offMsix) { Copy-Item $offMsix.FullName $msix -Force; Log "winget (offline): $($offMsix.Name)" }
    else {
      Log 'resolving latest winget release...'
      $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -UseBasicParsing -TimeoutSec 60 -EA Stop
      $asset = $rel.assets | Where-Object { $_.name -like '*.msixbundle' -and $_.name -notlike '*symbol*' } | Sort-Object size | Select-Object -First 1
      if (-not $asset) { throw 'no msixbundle in latest release' }
      try {
        if ((Test-Path $msix) -and -not (Test-DownloadComplete $msix 1MB $asset.size)) { Remove-Item $msix -Force -EA SilentlyContinue; Log '  tossed bad partial: winget msixbundle' }
      } catch {}
      if (-not (Test-Path $msix)) {
        Log "downloading $($asset.name) ($([math]::Round($asset.size/1MB,1)) MB, wait)..."
        if (-not (Invoke-Download -Url $asset.browser_download_url -OutFile $msix -ExpectedBytes $asset.size)) { throw 'winget msixbundle download failed after 3 tries' }
        Log "  got winget ($([math]::Round((Get-Item $msix).Length/1MB,1)) MB)"
      } else { Log 'winget msixbundle cached, using it.' }
    }
    try { Log 'installing winget msixbundle (1-3 min, wait)...'; Add-AppxPackage -Path $msix -EA Stop }
    catch {
      if ("$_" -match '0x80073D06|already installed') { Log 'winget already newer, ok.' }
      else { throw }
    }
    $env:Path += ';' + (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps')
    if (Test-WingetRuns) { Log 'winget: installed.'; return $true }
    Log 'winget staged but will not execute here (AppX gutted). using choco/offline instead.'
    return $false
  } catch { Log "WARN winget bootstrap failed: $_. Install App Installer manually, then re-run."; return $false }
  finally { $ProgressPreference = $oldProg }
}
if ((-not $TweaksOnly) -and (-not $ConfigsOnly)) {
  if ($DryRun) {
    $hasWinget = Test-WingetRuns
    if (-not $hasWinget) { Log 'winget: missing (dry-run, bootstrap skipped).' }
  } else { $hasWinget = Ensure-Winget }
} else { $hasWinget = $false }

# ---------- 2a. choco. plain ps1 + exe/msi, no appx. this is the slick path on stripped images. ----------
function Ensure-Chocolatey {
  if (Get-Command choco -EA SilentlyContinue) { Log 'choco: found.'; return $true }
  if ($NoChocoBootstrap) { Log 'choco: missing, bootstrap skipped (-NoChocoBootstrap).'; return $false }
  if (-not $isAdmin) { Log 'choco: missing, needs admin to bootstrap. re-run as admin.'; return $false }
  if (-not $online) { Log 'choco: offline, bootstrap skipped. connect or stage -OfflineDir.'; return $false }
  Log 'choco: missing. Bootstrapping from community.chocolatey.org (needs net, 2-5 min)...'
  $oldProg = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try {
    # the fetch is the flaky part. two more shots before giving up.
    $body = $null
    for ($i = 1; $i -le 3 -and -not $body; $i++) {
      try {
        $body = (New-Object Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')
        if (-not $body -or $body.Length -lt 1024) { throw 'install.ps1 looks truncated' }
      } catch {
        Log "  WARN choco bootstrap download attempt $i failed: $($_.Exception.Message)"
        $body = $null
        if ($i -lt 3) { Start-Sleep -Seconds (2 * $i) }
      }
    }
    if (-not $body) { throw 'could not fetch install.ps1 after 3 tries' }
    # same script, executed without Invoke-Expression. PSSA sleeps better, behavior identical.
    & ([scriptblock]::Create($body))
    Refresh-Path
    if (Get-Command choco -EA SilentlyContinue) { Log 'choco: installed.'; return $true }
    Log 'WARN choco bootstrap: installer ran but choco not on PATH.'; return $false
  } catch { Log "WARN choco bootstrap failed: $_. Install from chocolatey.org manually, then re-run."; return $false }
  finally { $ProgressPreference = $oldProg }
}
# winget id -> community package. all 11 verified live on community.chocolatey.org.
# a bad name fails safe: choco errors, id lands in the retry list.
# no choco package: helium, all vcredists, dotnet. no choco needed: komorebi,
# whkd, vesktop, telegram, qbittorrent, obs, git, vscodium, opencode ride github.
# 'python' tracks latest 3.x (3.15 at last check) while the winget id says 3.12. close enough.
$chocoMap = @{
  'Git.Git' = 'git'
  'OpenJS.NodeJS.LTS' = 'nodejs-lts'
  'Python.Python.3.12' = 'python'
  '7zip.7zip' = '7zip'
  'VideoLAN.VLC' = 'vlc'
  'qBittorrent.qBittorrent' = 'qbittorrent'
  'OBSProject.OBSStudio' = 'obs-studio'
  'Telegram.TelegramDesktop' = 'telegram'
  'VSCodium.VSCodium' = 'vscodium'
  'WiresharkFoundation.Wireshark' = 'wireshark'
  'SST.opencode' = 'opencode'
}
if ((-not $TweaksOnly) -and (-not $ConfigsOnly)) {
  if ($DryRun) {
    $hasChoco = [bool](Get-Command choco -EA SilentlyContinue)
    if ($hasChoco) { Log 'choco: found.' } else { Log 'choco: missing (dry-run, bootstrap skipped).' }
  } else { $hasChoco = Ensure-Chocolatey }
} else { $hasChoco = $false }

# github-direct. no manager at all, straight off release pages. patterns verified
# against the live releases api. x64 only, this box is x64. helium has no assets
# on its releases page, so it stays staged-only. unauthenticated api = 60 calls/hr,
# this runs max 9 per pass. cached under TEMP so re-runs skip the download.
$gitMap = @{
  'LGUG2Z.komorebi'        = @{ repo='LGUG2Z/komorebi'; pattern='komorebi-*-x86_64.msi' }
  'LGUG2Z.whkd'            = @{ repo='LGUG2Z/whkd'; pattern='whkd-*-x86_64.msi' }
  'Vencord.Vesktop'        = @{ repo='Vencord/Vesktop'; pattern='Vesktop-Setup-*.exe' }
  'Telegram.TelegramDesktop' = @{ repo='telegramdesktop/tdesktop'; pattern='td-setup-win-x64-*.exe' }
  'qBittorrent.qBittorrent'  = @{ repo='qbittorrent/qBittorrent'; pattern='qbittorrent_*_x64_setup.exe' }
  'OBSProject.OBSStudio'   = @{ repo='obsproject/obs-studio'; pattern='OBS-Studio-*-Windows-x64-Installer.exe' }
  'Git.Git'                = @{ repo='git-for-windows/git'; pattern='Git-*-64-bit.exe' }
  'VSCodium.VSCodium'      = @{ repo='VSCodium/vscodium'; pattern='VSCodiumSetup-x64-*.exe' }
  'SST.opencode'           = @{ repo='sst/opencode'; pattern='opencode-windows-x64.zip' }
}
function Install-GitHubAsset($id) {
  $g = $gitMap[$id]
  $oldProg = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try {
    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$($g.repo)/releases/latest" -UseBasicParsing -TimeoutSec 60 -EA Stop
    $asset = $rel.assets | Where-Object {
      $_.name -like $g.pattern -and $_.name -notmatch '\.(blockmap|yml|asc|txt|sha1|sha256)$' -and $_.name -notmatch 'arm64|aarch64'
    } | Select-Object -First 1
    if (-not $asset) { throw "no asset matching $($g.pattern)" }
    $dir = Join-Path (Join-Path $env:TEMP 'github-dl') ($id -replace '[^A-Za-z0-9]+','_')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dst = Join-Path $dir $asset.name
    # api knows the real size. a sleep-killed download leaves a big partial
    # that the old 1MB check waved through, then the installer choked on it.
    try {
      if (Test-Path $dst) {
        $len = (Get-Item $dst).Length
        if (($len -lt 1MB) -or ($asset.size -gt 0 -and $len -ne $asset.size)) { Remove-Item $dst -Force -EA SilentlyContinue; Log "  tossed bad partial: $($asset.name)" }
      }
    } catch {}
    if (-not (Test-Path $dst)) {
      Log "  downloading $($asset.name) ($([math]::Round($asset.size/1MB,1)) MB)..."
      if (-not (Invoke-Download -Url $asset.browser_download_url -OutFile $dst -ExpectedBytes $asset.size)) { throw "download failed after 3 tries: $($asset.name)" }
    } else { Log "  cached: $($asset.name)" }
    if (-not (Test-DownloadHash (Get-Item $dst))) {
      Log '  hash mismatch, retrying once...'
      if (-not (Invoke-Download -Url $asset.browser_download_url -OutFile $dst -ExpectedBytes $asset.size -Force)) { throw "download failed after 3 tries: $($asset.name)" }
      if (-not (Test-DownloadHash (Get-Item $dst))) { throw "hash still bad for $($asset.name)" }
    }
    Install-OfflineFile (Get-Item $dst)
  } finally { $ProgressPreference = $oldProg }
}
# evergreen vendor urls, HEAD-verified. no api, no manager. runtimes only:
# everything else desktop-ish has no stable direct link (versioned paths).
$directMap = @{
  'Microsoft.VCRedist.2015+.x86' = 'https://aka.ms/vs/17/release/vc_redist.x86.exe'
  'Microsoft.VCRedist.2015+.x64' = 'https://aka.ms/vs/17/release/vc_redist.x64.exe'
  'Microsoft.DotNet.DesktopRuntime.8' = 'https://aka.ms/dotnet/8.0/windowsdesktop-runtime-win-x64.exe'
}
function Install-DirectUrl($id) {
  $url = $directMap[$id]
  $oldProg = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
  try {
    $dir = Join-Path (Join-Path $env:TEMP 'direct-dl') ($id -replace '[^A-Za-z0-9]+','_')
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dst = Join-Path $dir ($url -split '/')[-1]
    try { if ((Test-Path $dst) -and ((Get-Item $dst).Length -lt 1MB)) { Remove-Item $dst -Force -EA SilentlyContinue } } catch {}
    if (-not (Test-Path $dst)) {
      Log "  downloading $(Split-Path $url -Leaf)..."
      if (-not (Invoke-Download -Url $url -OutFile $dst)) { throw "download failed after 3 tries: $(Split-Path $url -Leaf)" }
    } else { Log "  cached: $(Split-Path $dst -Leaf)" }
    if (-not (Test-DownloadHash (Get-Item $dst))) {
      Log '  hash mismatch, retrying once...'
      if (-not (Invoke-Download -Url $url -OutFile $dst -Force)) { throw "download failed after 3 tries: $(Split-Path $url -Leaf)" }
      if (-not (Test-DownloadHash (Get-Item $dst))) { throw "hash still bad for $(Split-Path $dst -Leaf)" }
    }
    try { Install-OfflineFile (Get-Item $dst) }
    catch {
      # 1638 = that version already on disk. for runtimes that means covered.
      if ("$_" -match '1638') { Log '  already present, ok.' }
      else { throw }
    }
  } finally { $ProgressPreference = $oldProg }
}

# ---------- 2b. runtimes first. apps below need them. ----------
# ancient vendor tools still link the old redists, so all of them go on.
$runtimeApps = @(
  'Microsoft.VCRedist.2005.x86','Microsoft.VCRedist.2005.x64',
  'Microsoft.VCRedist.2008.x86','Microsoft.VCRedist.2008.x64',
  'Microsoft.VCRedist.2010.x86','Microsoft.VCRedist.2010.x64',
  'Microsoft.VCRedist.2012.x86','Microsoft.VCRedist.2012.x64',
  'Microsoft.VCRedist.2013.x86','Microsoft.VCRedist.2013.x64',
  'Microsoft.VCRedist.2015+.x86','Microsoft.VCRedist.2015+.x64',
  'Microsoft.DotNet.DesktopRuntime.8'
)
# 3.5 + DirectPlay for old vendor tools. some LTSC trims need install media, hence the warn.
if ((-not $TweaksOnly) -and (-not $ConfigsOnly)) {
  if ($DryRun) {
    Log '  [dry-run] would enable NetFx3 + DirectPlay via DISM.'
  } elseif ($isAdmin) {
    Start-Phase 'features'
    # install media carries its own payload. same-version sources only, per ms docs.
    $sxs = Get-PSDrive -PSProvider FileSystem -EA SilentlyContinue |
      ForEach-Object { Join-Path $_.Root 'sources\sxs' } |
      Where-Object { Test-Path $_ } | Select-Object -First 1
    if ($sxs) { Log "  features source: $sxs" }
    $featFailed = 0
    foreach ($f in @('NetFx3','DirectPlay')) {
      # NOTE learned the hard way: native exes don't throw. check the exit code or the log lies.
      if ($sxs) { $exit = Invoke-Native { DISM /Online /Enable-Feature /FeatureName:$f /All /NoRestart /LimitAccess "/Source:$sxs" | Out-Null } }
      else { $exit = Invoke-Native { DISM /Online /Enable-Feature /FeatureName:$f /All /NoRestart | Out-Null } }
      # 3010 = success, reboot pending. not a failure.
      if ($exit -in @(0,3010)) { Log "${f}: enabled.$(if ($exit -eq 3010) { ' (reboot pending, normal)' })" }
      else { Log "WARN ${f}: DISM exit=$exit (insert install media so sources\sxs is visible) - enable manually for old vendor tools."; $featFailed++ }
    }
    Stop-Phase
    # a failed feature stays open so -Idempotent runs retry it next pass.
    if ($featFailed -eq 0) { Complete-Phase 'features' }
    else { Log "  features left open ($featFailed failed, no install media?) - re-run to retry." }
  } else { Log 'WARN NetFx3/DirectPlay: skipped (not admin).' }
}
# 4.8 is already in the image. moving on.
$coreApps = @(
  'LGUG2Z.komorebi',
  'LGUG2Z.whkd',
  'ImputNet.Helium',
  'VSCodium.VSCodium',
  'Vencord.Vesktop',
  'Telegram.TelegramDesktop',
  'qBittorrent.qBittorrent',
  'VideoLAN.VLC',
  'OBSProject.OBSStudio',
  # automation-student essentials
  'Git.Git',
  'OpenJS.NodeJS.LTS',
  'Python.Python.3.12',
  '7zip.7zip',
  'WiresharkFoundation.Wireshark',
  # me. terminal agent, reads .m files like anything else.
  'SST.opencode'
)
# shell pack (taste port from the linux box): small native cli tools, no wsl.
# winget covers them, or Get-Offline stages the files like any other app.
$shellApps = @(
  'Starship.Starship',
  'ajeetdsouza.zoxide',
  'junegunn.fzf',
  'sharkdp.bat',
  'eza-community.eza',
  'Fastfetch-cli.Fastfetch'
)
$coreApps += $shellApps
$optionalApps = @('Obsidian.Obsidian','Spotify.Spotify')
if ($IncludeOptional) { $coreApps += $optionalApps }
# study pack, -IncludeStudy. keep in sync with ISO/Get-Offline.ps1.
$studyApps = @('DigitalScholar.Zotero','SumatraPDF.SumatraPDF','MiKTeX.MiKTeX','Typst.Typst')
# terminal wants win10 1903+. on ltsc 2019 it would just fail every run.
$studyBuild = 0
$wtOk = (-not $osInfo) -or (-not [int]::TryParse([string]$osInfo.Build, [ref]$studyBuild)) -or ($studyBuild -ge 18362)
if ($wtOk) { $studyApps += 'Microsoft.WindowsTerminal' }
if ($IncludeStudy) {
  if (-not $wtOk) { Log 'study: windows terminal skipped (build too old for it).' }
  $coreApps += $studyApps
}

# -Only/-SkipApps: substring match against app ids. runtimes can be filtered
# too, but that is on you, some apps need them.
function Test-AppFilter($id, $patterns) {
  foreach ($p in $patterns) { if ($id -like "*$p*") { return $true } }
  return $false
}
$appsAll = @($runtimeApps + $coreApps)
if ($Only.Count) {
  $appsAll = @($appsAll | Where-Object { Test-AppFilter $_ $Only })
  if (-not $appsAll.Count) { Log 'WARN: -Only matched no app ids. check the patterns.' }
  else { Log ('only: ' + ($appsAll -join ', ')) }
}
if ($SkipApps.Count) {
  $dropped = @($appsAll | Where-Object { Test-AppFilter $_ $SkipApps })
  if (@($dropped | Where-Object { $_ -like 'Microsoft.*' }).Count) { Log 'WARN: -SkipApps filtered runtimes. apps that need them may fail.' }
  if ($dropped.Count) { Log ('skipping on request: ' + ($dropped -join ', ')) }
  $appsAll = @($appsAll | Where-Object { -not (Test-AppFilter $_ $SkipApps) })
}

$failed = @()
$installed = @()
# apps we actually tried an engine on this run. skip-only failures don't need a retry pass.
$script:appAttempted = @{}
# per-app state so -Idempotent re-runs skip what already landed and retry
# only what failed. one small json next to phases.json.
function Get-AppState {
  $af = Join-Path $StateDir 'apps.json'
  if (-not (Test-Path $af)) { return @{} }
  try {
    $o = Get-Content $af -Raw | ConvertFrom-Json
    $d = @{}
    foreach ($p in $o.PSObject.Properties) { $d[$p.Name] = $p.Value }
    return $d
  } catch { return @{} }
}
function Test-AppDone($id) {
  if ($Force) { return $false }
  $st = Get-AppState
  return ($st.ContainsKey($id))
}
function Set-AppDone($id) {
  if ($DryRun) { return }
  try {
    if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Force -Path $StateDir -EA Stop | Out-Null }
    $st = Get-AppState
    $st[$id] = (Get-Date).ToString('o')
    ($st | ConvertTo-Json) | Set-Content -Path (Join-Path $StateDir 'apps.json') -Encoding UTF8 -EA Stop
  } catch { Log "  WARN app state $id`: $_" }
}
function Find-OfflineInstaller($id) {
  if (-not $OfflineDir -or -not (Test-Path $OfflineDir)) { return $null }
  # exact match: per-ID subfolder from Get-Offline.ps1. also sidesteps VC_redist name collisions.
  $sub = Join-Path $OfflineDir ($id -replace '[^A-Za-z0-9]+','_')
  if (Test-Path $sub) {
    return Get-ChildItem $sub -File -EA SilentlyContinue |
      Where-Object { $_.Extension -in @('.exe','.msi','.msix','.msixbundle','.appx','.zip') } |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
  # sloppy fallback for hand-dropped folders. VCRedist needs the year check
  # because the last segment is just x64/x86 and matches literally everything.
  $segs = $id -split '\.'
  $cands = Get-ChildItem $OfflineDir -File -EA SilentlyContinue |
    Where-Object { $_.Name -like "*$($segs[-1])*" -and $_.Extension -in @('.exe','.msi','.msix','.msixbundle','.appx','.zip') }
  if ($segs[0] -eq 'Microsoft' -and $segs[1] -like 'VCRedist*') {
    $year = $segs[-2]
    $dated = $cands | Where-Object { $_.Name -like "*$year*" }
    if ($dated) { return $dated | Sort-Object LastWriteTime -Descending | Select-Object -First 1 }
    $redist = $cands | Where-Object { $_.Name -like '*redist*' }
    if ($redist) { Log "  WARN $id : year unverifiable in flat folder, using $(($redist | Select-Object -First 1).Name)" }
    return $redist | Sort-Object LastWriteTime -Descending | Select-Object -First 1
  }
  return $cands | Sort-Object LastWriteTime -Descending | Select-Object -First 1
}
# silent flags per installer type. winget bakes the type into the filename
# (<name>_<ver>_<scope>_<arch>_<tech>_<lang>.<ext>) so read that, don't guess.
function Install-OfflineFile($file) {
  $seg = ($file.BaseName -split '[-_]')[0]
  switch ($file.Extension) {
    '.msi' {
      $proc = Start-Process msiexec -ArgumentList '/i', "`"$($file.FullName)`"", '/qn', '/norestart' -Wait -PassThru -EA Stop
      if ($proc.ExitCode -notin @(0,1641,3010)) { throw "msiexec exit=$($proc.ExitCode)" }
    }
    { $_ -in @('.appx','.msix','.msixbundle') } { Add-AppxPackage -Path $file.FullName -EA Stop }
    '.zip' {
      $dest = Join-Path $env:LOCALAPPDATA "Programs\$seg"
      New-Item -ItemType Directory -Force -Path $dest | Out-Null
      Expand-Archive -Path $file.FullName -DestinationPath $dest -Force -EA Stop
      # binary may sit in a subfolder (e.g. portable zips) - put the real dir on PATH
      $bin = Get-ChildItem $dest -Filter "$seg.exe" -Recurse -EA SilentlyContinue | Select-Object -First 1
      $bindir = if ($bin) { $bin.DirectoryName } else { $dest }
      $upath = [System.Environment]::GetEnvironmentVariable('Path','User')
      if ($upath -notlike "*$bindir*") {
        [System.Environment]::SetEnvironmentVariable('Path', "$upath;$bindir", 'User')
        $env:Path += ";$bindir"
      }
    }
    default {
      $exe = $file.FullName
      if ($file.Name -like '*_burn_*') {
        $proc = Start-Process $exe -ArgumentList '/install', '/quiet', '/norestart' -Wait -PassThru -EA Stop
      } elseif ($file.Name -like '*redist*' -or $file.Name -like '*dotnet*' -or $file.Name -like '*runtime*') {
        $proc = Start-Process $exe -ArgumentList '/q' -Wait -PassThru -EA Stop
      } elseif ($file.Name -like '*python*') {
        $proc = Start-Process $exe -ArgumentList '/quiet', 'InstallAllUsers=0', 'PrependPath=1' -Wait -PassThru -EA Stop
      } elseif ($file.Name -like '*VSCodium*' -or $file.Name -like '*Git*' -or $file.Name -like '*Telegram*' -or $file.Name -like '*tsetup*' -or $file.Name -like '*td-setup*') {
        $proc = Start-Process $exe -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART' -Wait -PassThru -EA Stop
      } else {
        $proc = Start-Process $exe -ArgumentList '/S' -Wait -PassThru -EA Stop
      }
      if ($proc.ExitCode -notin @(0,1641,3010)) { throw "installer exit=$($proc.ExitCode) ($($file.Name))" }
    }
  }
}
function Install-App($id) {
  # one app through the engines, in order. true when something landed.
  $off = Find-OfflineInstaller $id
  if ($off -and $Unattended) {
    # staged beats everything. no net needed, no manager needed.
    $script:appAttempted[$id] = $true
    Log "offline install: $($off.Name) for $id"
    try { Install-OfflineFile $off; Log '  ok (offline)'; return $true }
    catch { Log "  WARN offline failed, falling through: $_" }
  }
  if ($hasWinget -and $online) {
    $script:appAttempted[$id] = $true
    Log "winget install: $id"
    $exit = Invoke-Native { winget install --id $id -e --silent --accept-source-agreements --accept-package-agreements }
    if ($exit -eq 0) { Log '  ok'; return $true }
    Log "  WARN exit=$exit, falling through"
  }
  if ($hasChoco -and $chocoMap.ContainsKey($id)) {
    # NOTE native exe, exit code is the truth. try/catch alone lies.
    $script:appAttempted[$id] = $true
    Log "choco install: $($chocoMap[$id]) (for $id)"
    $exit = Invoke-Native { choco install $chocoMap[$id] -y --no-progress }
    if ($exit -eq 0) { Log '  ok'; return $true }
    Log "  WARN exit=$exit, falling through"
  }
  if ($online -and $gitMap.ContainsKey($id)) {
    $script:appAttempted[$id] = $true
    Log "github release: $id"
    try { Install-GitHubAsset $id; Log '  ok (github)'; return $true }
    catch { Log "  WARN github ${id}: $_"; return $false }
  }
  if ($online -and $directMap.ContainsKey($id)) {
    $script:appAttempted[$id] = $true
    Log "direct download: $id"
    try { Install-DirectUrl $id; Log '  ok (direct)'; return $true }
    catch { Log "  WARN direct ${id}: $_"; return $false }
  }
  if ($off) {
    Log "  SKIP $id (staged but no -Unattended. re-run with -Unattended or run $($off.Name) by hand)"
  } elseif (-not $chocoMap.ContainsKey($id) -and -not $gitMap.ContainsKey($id) -and -not $directMap.ContainsKey($id)) {
    Log "  SKIP $id (no choco/github source. stage it: Get-Offline.ps1 -GapsOnly on a normal pc)"
  }
  return $false
}
if ((-not $TweaksOnly) -and (-not $ConfigsOnly) -and (Should-Run 'apps') -and ($DryRun -or $hasWinget -or $hasChoco -or ($OfflineDir -and (Test-Path $OfflineDir)))) {
  Start-Phase 'apps'
  $appTotal = $appsAll.Count
  $appIdx = 0
  foreach ($id in $appsAll) {
    $appIdx++
    if ($DryRun) { Log "  [dry-run] would install: $id"; continue }
    if ($Idempotent -and (Test-AppDone $id)) { Log "  skip (done): $id"; continue }
    Write-Progress -Activity 'installing apps' -Status "$appIdx/$appTotal $id" -PercentComplete ([int]((($appIdx - 1) * 100) / [math]::Max(1, $appTotal))) -EA SilentlyContinue
    if (Install-App $id) { $installed += $id; Set-AppDone $id }
    else { $failed += $id }
  }
  Write-Progress -Activity 'installing apps' -Completed -EA SilentlyContinue
  # one free retry pass. flaky links and rate limits are the usual causes.
  # skip-only failures never hit an engine, retrying them just re-logs the skip.
  if ($failed.Count -and $online) {
    $retryList = @($failed | Where-Object { $script:appAttempted.ContainsKey($_) })
    $skipOnly = @($failed | Where-Object { -not $script:appAttempted.ContainsKey($_) })
    if ($retryList.Count) {
      Log "retrying $($retryList.Count) failed app(s)..."
      $failed = @($skipOnly)
      foreach ($id in $retryList) {
        Log "retry: $id"
        if (Install-App $id) { $installed += $id; Set-AppDone $id }
        else { $failed += $id }
      }
    }
  }
  if ($Only.Count) { Log 'bulk upgrades skipped (selective -Only run).' }
  elseif ($DryRun) { Log '[dry-run] would upgrade packages (winget upgrade --all / choco upgrade all).' }
  else {
    if ($hasWinget -and $online) {
      $exit = Invoke-Native { winget upgrade --all --silent --accept-source-agreements --accept-package-agreements }
      if ($exit -eq 0) { Log '  winget upgrade done.' } else { Log "  WARN winget upgrade exit=$exit" }
    }
    elseif ($hasWinget) { Log 'SKIP winget upgrade (offline).' }
    if ($hasChoco -and $online) {
      $exit = Invoke-Native { choco upgrade all -y --no-progress }
      if ($exit -eq 0) { Log '  choco upgrade done.' } else { Log "  WARN choco upgrade exit=$exit" }
    }
    elseif ($hasChoco) { Log 'SKIP choco upgrade (offline).' }
  }
  Stop-Phase
  # failures keep the phase open so -Idempotent re-runs retry them. an empty
  # list (typo in -Only, everything -SkipApps'd) stays open too, on purpose.
  if ($failed.Count -eq 0 -and $appsAll.Count -gt 0) { Complete-Phase 'apps' }
  elseif ($appsAll.Count -eq 0) { Log '  nothing selected, apps phase left open.' }
  else { Log "  apps left open ($($failed.Count) failed) - re-run to retry." }
} elseif ($TweaksOnly) { Log 'Tweaks-only: apps skipped.' } elseif ($ConfigsOnly) { Log 'Configs-only: apps skipped.' } else {
  Log 'SKIP installs (no winget, no choco, no -OfflineDir). Get net for choco, or stage with Get-Offline.ps1 - nothing marked failed yet.'
}

# fresh installs don't land on PATH in this session. re-read it or python/codium are "missing".
Refresh-Path
Log 'PATH refreshed.'

# bench drivers (ch340/cp210x/st-link). point at a folder of extracted vendor infs.
if ($DriverDir -and (Test-Path $DriverDir) -and (-not $TweaksOnly) -and (-not $ConfigsOnly)) {
  if ($DryRun) { Log "  [dry-run] would add drivers from $DriverDir." }
  elseif ($isAdmin) {
    Log "drivers: $DriverDir"
    $exit = Invoke-Native { pnputil /add-driver "$DriverDir\*.inf" /subdirs /install }
    if ($exit -in @(0,3010)) { Log "  drivers staged+installed$(if ($exit -eq 3010) { ' (reboot pending)' })" }
    else { Log "  WARN pnputil exit=$exit (check the inf folder, install manually)" }
  } else { Log '  WARN drivers: skipped (not admin).' }
} elseif ($DriverDir) { Log '  WARN drivers: folder missing or tweaks-only/configs-only run.' }

Log 'NOTE manual-only: ExplorerBlurMica (Maplespe releases, optional), Spicetify (after Spotify: Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/spicetify/cli/main/install.ps1 | Invoke-Expression).'

# ---------- 3. configs ----------
if ((-not $TweaksOnly) -and (Should-Run 'configs')) {
Log 'Configs...'
Start-Phase 'configs'
function Copy-Config($src, $dst) {
  if (-not (Test-Path $src)) { Log "  SKIP missing in repo (not fatal): $src"; return }
  if ($DryRun) { Log "  [dry-run] would copy: $dst"; return }
  New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
  Copy-Item $src $dst -Force -EA Stop
  Log "  $dst"
}
# stock PS 5.1 profile lives under WindowsPowerShell in docs. that's just how it is.
$docPS = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Microsoft.PowerShell_profile.ps1'
Copy-Config (Join-Path $Repo 'PowerShell\Microsoft.PowerShell_profile.ps1') $docPS
if (Get-Command pwsh -EA SilentlyContinue) {
  Copy-Config (Join-Path $Repo 'PowerShell\Microsoft.PowerShell_profile.ps1') (Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'PowerShell\Microsoft.PowerShell_profile.ps1')
}

# komorebi + whkd. the only WM here.
Copy-Config (Join-Path $Repo 'Komorebi\komorebi.json') (Join-Path $env:USERPROFILE 'komorebi.json')
Copy-Config (Join-Path $Repo 'Komorebi\whkdrc') (Join-Path $env:USERPROFILE '.config\whkd\whkdrc')

# extensions live in extensions.txt next to the script. edit that file, not this one.
$codium = Get-CmdPath 'codium'
if (-not $codium) {
  foreach ($cand in @("$env:LOCALAPPDATA\Programs\VSCodium\VSCodium.exe",
                      "$env:ProgramFiles\VSCodium\VSCodium.exe",
                      "${env:ProgramFiles(x86)}\VSCodium\VSCodium.exe")) {
    if (Test-Path $cand) { $codium = $cand; break }
  }
}

# vscodium eats vscode settings as-is. extensions come from open vsx though.
# appdata dir only shows up after first launch, so seed it when the exe exists.
$vs = Join-Path $env:APPDATA 'VSCodium\User\settings.json'
if ((Test-Path (Split-Path $vs)) -or ($codium -and (Test-Path $codium))) {
  if (-not $DryRun) { New-Item -ItemType Directory -Force -Path (Split-Path $vs) | Out-Null }
  Copy-Config (Join-Path $Repo 'VSCodium\settings.json') $vs
  Copy-Config (Join-Path $Repo 'VSCodium\keybindings.json') (Join-Path $env:APPDATA 'VSCodium\User\keybindings.json')
  # darkmatter theme ships as a folder extension. the folder name has to carry
  # the version or vscodium pretends it is not installed.
  $themeDst = Join-Path $env:USERPROFILE '.vscode-oss\extensions\xfcemlg.darkmatter-theme-0.6.0'
  if ($DryRun) { Log "  [dry-run] would copy: $themeDst (plus drop any older versions)" }
  else {
    try {
      # a version bump would otherwise leave both folders there and vscodium gets grumpy.
      Get-ChildItem (Split-Path $themeDst -Parent) -Directory -Filter 'xfcemlg.darkmatter-theme-*' -EA SilentlyContinue |
        Where-Object { $_.Name -ne (Split-Path $themeDst -Leaf) } |
        ForEach-Object { Remove-Item $_.FullName -Recurse -Force -EA SilentlyContinue; Log "  dropped old theme folder: $($_.Name)" }
      New-Item -ItemType Directory -Force -Path $themeDst | Out-Null
      Copy-Item (Join-Path $Repo 'VSCodium\darkmatter-theme\*') $themeDst -Recurse -Force -EA Stop
      Log "  $themeDst"
    } catch { Log "  WARN vscodium theme: $_" }
  }
}
else { Log '  VSCodium not installed yet - settings kept in repo VSCodium/.' }
if ($DryRun -and (-not $ConfigsOnly)) {
  Log '  [dry-run] would install vscodium extensions from extensions.txt.'
} elseif ($codium -and (Test-Path $codium) -and (-not $ConfigsOnly)) {
  $extList = @('yasirarafat.opencode-ai-chat','Gimly81.matlab')
  $extFile = Join-Path $Repo 'VSCodium\extensions.txt'
  if (Test-Path $extFile) {
    $extList = @(Get-Content $extFile -EA SilentlyContinue |
      Where-Object { $_ -and $_ -notmatch '^\s*#' } |
      ForEach-Object { $_.Trim() } |
      Where-Object { $_ })
  }
  # study pack rides on top, both names live on open-vsx.org (checked, not guessed).
  if ($IncludeStudy) { $extList += @('James-Yu.latex-workshop','myriad-dreamin.tinymist') }
  foreach ($ext in $extList) {
    try {
      $exit = Invoke-Native { & $codium --install-extension $ext }
      if ($exit -ne 0) { throw "exit=$exit" }
      Log "  vscodium ext: $ext"
    }
    catch { Log "  WARN vscodium ext ${ext}: install manually from Open VSX." }
  }
  Log '  NOTE: MATLAB extension (MathWorks) is MS-marketplace only - download the .vsix and: codium --install-extension <file>.vsix'
} elseif ($ConfigsOnly) { Log '  extensions skipped (configs-only).' } else { Log '  VSCodium exe not found - extensions skipped.' }

# pip libs for bench work. needs python on PATH, so this runs after the refresh above.
if (-not $ConfigsOnly) {
  if ($DryRun) { Log '  [dry-run] would pip install: numpy scipy matplotlib pyserial pymodbus' }
  else {
  try {
    $exit = Invoke-Native { python -m pip install --upgrade pip }
    if ($exit -ne 0) { throw "pip upgrade exit=$exit" }
    $exit = Invoke-Native { python -m pip install numpy scipy matplotlib pyserial pymodbus }
    if ($exit -ne 0) { throw "pip install exit=$exit" }
    Log '  python libs: numpy scipy matplotlib pyserial pymodbus'
  } catch { Log '  WARN pip libs skipped - run manually: python -m pip install numpy scipy matplotlib pyserial pymodbus' }
  }
} else { Log '  python libs skipped (configs-only).' }

# fresh installs get configs; -ConfigsOnly (or -Force) re-deploys over existing ones.
function Copy-Fresh($src, $dst) {
  if (($ConfigsOnly -or $Force) -or -not (Test-Path $dst)) { Copy-Config $src $dst }
  else { Log "  keep existing: $dst" }
}
Copy-Fresh (Join-Path $Repo 'Vesktop\settings.json') (Join-Path $env:APPDATA 'Vesktop\settings.json')
Copy-Fresh (Join-Path $Repo 'qBittorrent\qbittorrent.ini') (Join-Path $env:APPDATA 'qBittorrent\qbittorrent.ini')
Copy-Fresh (Join-Path $Repo 'VLC\vlcrc') (Join-Path $env:APPDATA 'vlc\vlcrc')
Copy-Fresh (Join-Path $Repo 'OBS\profiles\Recording\basic.ini') (Join-Path $env:APPDATA 'obs-studio\basic\profiles\Recording\basic.ini')
# git defaults. fresh-only on purpose: identity is blank in the repo copy, so an overwrite
# on re-run would wipe the name/email you set. (needs Copy-Fresh, so it lives down here.)
Copy-Fresh (Join-Path $Repo 'Git\.gitconfig') (Join-Path $env:USERPROFILE '.gitconfig')
# quickcss ships as a placeholder, so an untouched one upgrades to the real
# darkmatter theme on re-run. a quickcss you edited yourself is kept.
$qcss = Join-Path $env:APPDATA 'Vesktop\settings\quickcss.css'
$qsrc = Join-Path $Repo 'Vesktop\quickcss.css'
$qcur = $null
if (Test-Path $qcss) { $qcur = Get-Content $qcss -Raw -EA SilentlyContinue }
if ((Test-QuickcssStale $qcur) -or $ConfigsOnly -or $Force) { Copy-Config $qsrc $qcss } else { Log "  keep existing: $qcss" }
# opencode global config: curated MCP servers (context7, playwright). fresh-only.
Copy-Fresh (Join-Path $Repo 'config\opencode.json') (Join-Path $env:USERPROFILE '.config\opencode\opencode.json')
# study pack configs, fresh-only like the rest. -IncludeStudy territory.
if ($IncludeStudy) {
  Copy-Fresh (Join-Path $Repo 'SumatraPDF\SumatraPDF-settings.txt') (Join-Path $env:LOCALAPPDATA 'SumatraPDF\SumatraPDF-settings.txt')
  # terminal config only where terminal can actually land (same build gate as the install).
  if ($wtOk) { Copy-Fresh (Join-Path $Repo 'WindowsTerminal\settings.json') (Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json') }
  # latex workshop points at the per-user sumatra path. a machine-wide install needs a nudge.
  if (-not (Test-Path (Join-Path $env:LOCALAPPDATA 'SumatraPDF\SumatraPDF.exe')) -and (Test-Path (Join-Path $env:ProgramFiles 'SumatraPDF\SumatraPDF.exe'))) {
    Log '  NOTE: SumatraPDF sits in Program Files. fix the two latex-workshop viewer paths in VSCodium\settings.json.'
  }
}
$ocPlugins = Join-Path $env:USERPROFILE '.config\opencode\plugins'
if (-not $DryRun -and -not (Test-Path $ocPlugins)) { New-Item -ItemType Directory -Force -Path $ocPlugins | Out-Null }
if (Test-Path (Join-Path $Repo 'Helium\master_preferences')) {
  $heData = Join-Path $env:LOCALAPPDATA 'Helium\User Data'
  if (-not (Test-Path $heData)) { Copy-Config (Join-Path $Repo 'Helium\master_preferences') (Join-Path $heData 'master_preferences') }
  else { Log '  Helium already ran - master_preferences ignored (change settings in UI).' }
}

# drop your .ttfs in Fonts/ and they get installed. admin only, windows rules.
$fontDir = Join-Path $Repo 'Fonts'
if ((Test-Path $fontDir) -and $isAdmin) {
  if ($DryRun) { Log '  [dry-run] would install fonts from Fonts/.' }
  else {
  try {
    $shell = New-Object -ComObject Shell.Application -EA Stop
    $fFolder = $shell.Namespace(0x14)
    Get-ChildItem $fontDir -Include *.ttf,*.otf -Recurse -EA SilentlyContinue | ForEach-Object {
      try { $fFolder.CopyHere($_.FullName, 0x10); Log "  font: $($_.Name)" } catch { Log "  WARN font $($_.Name): $_" }
    }
  } catch { Log "  WARN fonts: shell object unavailable on this trim - right-click Install the .ttfs." }
  }
} else { Log '  Fonts: drop JetBrainsMono Nerd Font + Monocraft .ttf into Fonts/ and re-run as admin (or right-click Install).' }
Stop-Phase
Complete-Phase 'configs'
} elseif ($TweaksOnly) { Log 'Configs skipped (tweaks-only).' } else { Log 'Configs skipped (already done).' }

# tweaks live up top now (section 1). runs first, cleanup lands in the finale.

# ---------- 4. rip out what helium/vlc/vscodium already replace ----------
# checks state first. on tiny10 half of this is already gone, it just says so and moves on.
if ((-not $NoDebloat) -and (-not $TweaksOnly) -and (-not $ConfigsOnly) -and (Should-Run 'debloat')) {
  Log 'Ripping out the replaced stuff...'
  Start-Phase 'debloat'
  if ($DryRun) { Log '  [dry-run] would remove IE11, Edge, Media Player, ISE, WordPad, OneDrive, and sweep appx.' }
  elseif (-not $isAdmin) { Log '  skipped (not admin).' }
  else {
    try {
      $ie = Get-WindowsOptionalFeature -Online -FeatureName 'Internet-Explorer-Optional-amd64' -EA Stop
      if ($ie -and $ie.State -ne 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName 'Internet-Explorer-Optional-amd64' -NoRestart -EA Stop | Out-Null; Log '  IE11 removed.' }
      else { Log '  IE11 already gone.' }
    } catch { Log "  WARN IE11: $_" }
    try {
      $edgeVer = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft\Edge\Application" -Directory -EA SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
      $edgeSetup = if ($edgeVer) { Join-Path $edgeVer.FullName 'Installer\setup.exe' } else { $null }
      if ($edgeSetup -and (Test-Path $edgeSetup)) {
        $proc = Start-Process $edgeSetup -ArgumentList '--uninstall','--system-level','--force-uninstall' -Wait -PassThru -EA Stop
        if ($proc.ExitCode -eq 0) { Log '  Edge uninstalled (edgeupdate services left alone - other MS apps may use them).' }
        else { Log "  WARN Edge exit=$($proc.ExitCode)" }
      } else { Log '  Edge already gone.' }
    } catch { Log "  WARN Edge: $_" }
    try {
      $wmp = Get-WindowsOptionalFeature -Online -FeatureName 'WindowsMediaPlayer' -EA Stop
      if ($wmp -and $wmp.State -ne 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName 'WindowsMediaPlayer' -NoRestart -EA Stop | Out-Null; Log '  Media Player removed (VLC covers media).' }
      else { Log '  Media Player already gone.' }
    } catch { Log "  WARN Media Player: $_" }
    # PowerShell ISE <- VSCodium (editing) + console (running)
    try {
      $ise = Get-WindowsOptionalFeature -Online -FeatureName 'MicrosoftWindowsPowerShellISE' -EA Stop
      if ($ise -and $ise.State -ne 'Disabled') { Disable-WindowsOptionalFeature -Online -FeatureName 'MicrosoftWindowsPowerShellISE' -NoRestart -EA Stop | Out-Null; Log '  PowerShell ISE removed (VSCodium covers it).' }
      else { Log '  PowerShell ISE already gone.' }
    } catch { Log "  WARN ISE: $_" }
    # WordPad <- VSCodium/Obsidian (capability, not a feature)
    try {
      $wp = Get-WindowsCapability -Online -Name 'Microsoft.Windows.WordPad~~~~0.0.1.0' -EA Stop
      if ($wp -and $wp.State -ne 'NotPresent') { Remove-WindowsCapability -Online -Name 'Microsoft.Windows.WordPad~~~~0.0.1.0' -EA Stop | Out-Null; Log '  WordPad removed.' }
      else { Log '  WordPad already gone.' }
    } catch { Log "  WARN WordPad: $_" }
    # OneDrive. nothing here replaces sync, but nobody asked for it either. out.
    try {
      $od = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
      if (-not (Test-Path $od)) { $od = "$env:SystemRoot\System32\OneDriveSetup.exe" }
      if (Test-Path $od) {
        $proc = Start-Process $od -ArgumentList '/uninstall' -Wait -PassThru -EA Stop
        if ($proc.ExitCode -eq 0) { Log '  OneDrive removed.' } else { Log "  WARN OneDrive exit=$($proc.ExitCode)" }
      }
      else { Log '  OneDrive already gone.' }
    } catch { Log "  WARN OneDrive: $_" }
    # appx leftovers (bing, solitaire, xbox...). tiny10 usually has none; normal boxes do.
    if (Get-Command Get-AppxPackage -EA SilentlyContinue) {
      foreach ($fam in @('Microsoft.BingNews','Microsoft.BingWeather','Microsoft.GetHelp','Microsoft.Getstarted','Microsoft.MicrosoftOfficeHub','Microsoft.MicrosoftSolitaireCollection','Microsoft.People','Microsoft.WindowsFeedbackHub','Microsoft.YourPhone','Microsoft.ZuneMusic','Microsoft.ZuneVideo','Microsoft.SkypeApp','Microsoft.MixedReality.Portal','Microsoft.Print3D','Microsoft.XboxApp','Microsoft.XboxGameOverlay','Microsoft.XboxGamingOverlay','Microsoft.XboxSpeechToTextOverlay','Microsoft.Xbox.TCUI')) {
        try {
          Get-AppxPackage -Name "$fam*" -EA Stop | ForEach-Object {
            try { Remove-AppxPackage -Package $_.PackageFullName -EA Stop; Log "  appx removed: $($_.Name)" }
            catch { Log "  WARN appx $($_.Name): $_" }
          }
          Get-AppxProvisionedPackage -Online -EA Stop | Where-Object { $_.DisplayName -like "$fam*" } | ForEach-Object {
            try { Remove-AppxProvisionedPackage -Online -PackageName $_.PackageName -EA Stop | Out-Null; Log "  provisioned removed: $($_.DisplayName)" }
            catch { Log "  WARN provisioned $($_.DisplayName): $_" }
          }
        } catch { Log "  WARN appx sweep ${fam}: $_" }
      }
    } else { Log '  appx sweep skipped (no appx provider).' }
  }
  Stop-Phase
  Complete-Phase 'debloat'
} else { if ($TweaksOnly) { Log 'Tweaks-only: debloat skipped.' } elseif ($ConfigsOnly) { Log 'Configs-only: debloat skipped.' } else { Log 'Debloat skipped (-NoDebloat).' } }

# ---------- 5. autostart Komorebi + whkd (user logon), stock panel untouched ----------
if ((-not $TweaksOnly) -and (-not $ConfigsOnly) -and (Should-Run 'autostart')) {
Log 'Autostart...'
Start-Phase 'autostart'
function Set-StartupShortcut($name, $target, $argl) {
  $sm = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
  $lnk = Join-Path $sm "$name.lnk"
  if ($DryRun) { Log "  [dry-run] would create startup shortcut: $name"; return }
  try {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lnk)
    $sc.TargetPath = $target; $sc.Arguments = $argl; $sc.WorkingDirectory = (Split-Path $target); $sc.Save()
    Log "  startup: $name"
  } catch { Log "  WARN startup ${name}: $_" }
}
$kExe = Get-CmdPath 'komorebi'
if (-not $kExe) { $kExe = "$env:ProgramFiles\komorebi\bin\komorebi.exe" }
$wExe = Get-CmdPath 'whkd'
if (-not $wExe) { $wExe = "$env:ProgramFiles\whkd\whkd.exe" }
if ($kExe -and (Test-Path $kExe)) { Set-StartupShortcut 'komorebi' $kExe '' } else { Log '  komorebi exe not found yet - install it, shortcut applies next run.' }
if ($wExe -and (Test-Path $wExe)) { Set-StartupShortcut 'whkd' $wExe '' } else { Log '  whkd exe not found yet - install it, shortcut applies next run.' }

# helium default. per-user, needs no admin.
if ($DryRun) { Log '  [dry-run] would set Helium as default browser.' }
else {
try {
  $helium = Get-CmdPath 'helium'
  if (-not $helium) {
    foreach ($root in @("$env:LOCALAPPDATA\Helium", "$env:ProgramFiles\Helium", "${env:ProgramFiles(x86)}\Helium")) {
      if (-not (Test-Path $root)) { continue }
      $h = Get-ChildItem $root -Filter 'helium.exe' -Recurse -EA SilentlyContinue | Select-Object -First 1
      if ($h) { $helium = $h.FullName; break }
    }
  }
  if ($helium) { Start-Process $helium -ArgumentList '--make-default-browser' -WindowStyle Hidden -EA Stop; Log '  Helium default-browser requested (confirm in Settings > Apps > Default apps).' }
  else { Log '  Helium not found yet - set default manually in Settings > Apps > Default apps.' }
} catch { Log "  WARN default browser: $_" }
}

# auth can't run unattended, so it goes on the desktop as a double-click thing.
if ($DryRun) { Log '  [dry-run] would write Desktop Win-Iot-Finish.cmd.' }
else {
try {
  $finishCmd = '@echo off' + "`r`n" + 'title Win-Iot finish setup' + "`r`n" +
    'powershell -NoProfile -ExecutionPolicy Bypass -Command "opencode auth login"' + "`r`n" +
    'echo.' + "`r`n" + 'echo Set a password now if you want one (Enter twice to stay blank):' + "`r`n" +
    'net user "My Pc" *' + "`r`n" +
    'echo.' + "`r`n" + 'echo Delete this shortcut when finished.' + "`r`n" + 'pause'
  $finishPath = Join-Path ([Environment]::GetFolderPath('CommonDesktopDirectory')) 'Win-Iot-Finish.cmd'
  Set-Content -Path $finishPath -Value $finishCmd -Encoding Ascii -Force -EA Stop
  Log "  finish helper: $finishPath"
} catch { Log "  WARN finish helper: $_" }
}
Stop-Phase
Complete-Phase 'autostart'
} elseif ($ConfigsOnly) { Log 'Autostart/browser/finish skipped (configs-only).' } else { Log 'Autostart/browser/finish skipped (tweaks-only).' }

if ((-not $TweaksOnly) -and (-not $ConfigsOnly)) {
  if ($DryRun) { Log 'Smoke test skipped (dry-run).' }
  else {
  Log 'Smoke test...'
  foreach ($s in @(
    @{ n='komorebi'; cmd={ komorebi --version } },
    @{ n='whkd'; cmd={ Get-Command whkd -EA Stop | Out-Null } },
    @{ n='git'; cmd={ git --version } },
    @{ n='python'; cmd={ python --version } },
    @{ n='node'; cmd={ node --version } },
    @{ n='codium'; cmd={ & (Get-CmdPath 'codium') --version } },
    @{ n='opencode'; cmd={ opencode --version } },
    @{ n='7zip'; cmd={ Get-Command 7z -EA Stop | Out-Null } }
  )) {
    if ((Invoke-Native $s.cmd) -eq 0) { Log "  smoke ok: $($s.n)" }
    else { Log "  smoke MISSING: $($s.n)" }
  }
  }
}

# ---------- 6. finale. sweep up, including our own mess. ----------
if (-not $NoTweaks) {
  Log 'Cleanup...'
  Start-Phase 'cleanup'
  if ($DryRun) { Log '  [dry-run] would clear temp files, prune old logs, hibernate off, disk cleanup.' }
  else {
  # installer caches + the fallback log dir survive for faster re-runs. rest goes.
  try {
    Get-ChildItem (Join-Path $env:TEMP '*') -Exclude 'winget-bootstrap','github-dl','direct-dl','Win-Iot-Setup' -EA SilentlyContinue |
      Remove-Item -Recurse -Force -EA SilentlyContinue
    if ($isAdmin) { Remove-Item 'C:\Windows\Temp\*' -Recurse -Force -EA SilentlyContinue }
    Log '  temp files removed.'
  } catch { Log "  WARN temp cleanup: $_" }
  # our own logs pile up in the log dir. keep 30 days, quietly.
  try {
    Get-ChildItem (Join-Path $LogDir 'install-*.log') -EA SilentlyContinue |
      Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) } |
      Remove-Item -Force -EA SilentlyContinue
  } catch {}
  if ($isAdmin) {
    # hibernate off (frees hiberfil.sys - matters on small tiny10 disks). it also kills fast startup,
    # so -KeepFastStartup skips it. before this the switch only logged and hibernate went off anyway.
    if ($KeepFastStartup) { Log '  hibernate left alone (-KeepFastStartup).' }
    else {
      $exit = Invoke-Native { powercfg /hibernate off }
      if ($exit -eq 0) { Log '  hibernation off.' } else { Log "  WARN hibernate exit=$exit" }
    }
    # disk cleanup, no prompts (may be stripped on tiny10 -> warn only)
    try { Start-Process cleanmgr -ArgumentList '/VERYLOWDISK' -Wait -EA Stop; Log '  disk cleanup done.' }
    catch { Log '  WARN disk cleanup: cleanmgr missing (common on tiny10).' }
  }
  }
  Stop-Phase
  Complete-Phase 'cleanup'
} elseif ($ConfigsOnly) { Log 'Cleanup skipped (configs-only).' } else { Log 'Cleanup skipped (-NoTweaks).' }

# machine-readable run report. one json, easy to diff between runs.
try {
  $report = [ordered]@{
    stamp     = $Stamp
    mode      = if ($TweaksOnly) { 'tweaks-only' } elseif ($ConfigsOnly) { 'configs-only' } else { 'full' }
    dryRun    = [bool]$DryRun
    admin     = [bool]$isAdmin
    online    = [bool]$online
    os        = if ($osInfo) {
      $osName = if ($osInfo.PSObject.Properties['Caption']) { $osInfo.Caption } elseif ($osInfo.PSObject.Properties['ProductName']) { $osInfo.ProductName } else { 'unknown' }
      $osBuild = if ($osInfo.PSObject.Properties['BuildNumber']) { $osInfo.BuildNumber } elseif ($osInfo.PSObject.Properties['Build']) { $osInfo.Build } else { '' }
      "$osName build $osBuild"
    } else { 'unknown' }
    phases    = $script:phaseTimes
    installed = $installed
    failed    = $failed
    warnings  = $script:warnCount
    log       = $LogFile
  }
  $reportPath = Join-Path $LogDir "report-$Stamp.json"
  ($report | ConvertTo-Json -Depth 4) | Set-Content -Path $reportPath -Encoding UTF8 -EA Stop
  Log "Report: $reportPath"
} catch { Log "  WARN report: $_" }
Log '---'
if ($failed.Count) { Log ('FAILED/RETRY: ' + ($failed -join ', ')) } elseif ((-not $TweaksOnly) -and (-not $ConfigsOnly)) { Log 'All installs reported ok.' }
# one-line scoreboard, then per-phase seconds. details are in the log already.
Log ("summary: $(if ($DryRun) { 'dry-run, ' })installed $($installed.Count), failed $($failed.Count), warnings $($script:warnCount)")
foreach ($p in $script:phaseTimes.Keys) { Log ("  {0}: {1}s" -f $p, $script:phaseTimes[$p]) }
# success means caches are dead weight on a small disk. failures keep them for retry.
if ((-not $TweaksOnly) -and (-not $ConfigsOnly) -and (-not $DryRun) -and ($failed.Count -eq 0)) {
  foreach ($c in @('winget-bootstrap','github-dl','direct-dl')) {
    Remove-Item (Join-Path $env:TEMP $c) -Recurse -Force -EA SilentlyContinue
  }
  Log '  installer caches purged.'
}
Log "Log: $LogFile"
if ($DryRun) { Log 'Dry-run finished. nothing changed, nothing marked done.' }
elseif (-not $TweaksOnly) {
Log 'NEXT:'
Log '  1. reboot, Komorebi + whkd autostart, stock taskbar as-is.'
Log '  2. double-click Desktop Win-Iot-Finish.cmd (opencode auth + optional password).'
Log '  3. MATLAB via campus license + USB-serial drivers (CH340/CP210x/ST-Link) manually.'
} elseif ($ConfigsOnly) { Log 'Configs-only done.' } else { Log 'Tweaks-only done. reboot to feel the taskbar changes.' }
if ($Reboot -and -not $DryRun) {
  Log 'rebooting in 60s (-Reboot). save your stuff.'
  shutdown /r /t 60 /c 'Win-Iot setup done. rebooting.' 2>&1 | Out-Null
}
if ($Reboot -and $DryRun) { Log 'reboot skipped (dry-run).' }
if ($transcriptOn) { try { Stop-Transcript | Out-Null } catch {} }
