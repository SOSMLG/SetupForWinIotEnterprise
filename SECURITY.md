# security

## what this repo does
the installer changes system settings, installs software, removes some built-in components and
(with the ISO) can set up a machine with no prompts. read `docs/TWEAKS.md`, run `-DryRun`, and
use a VM first.

## what to know before running it
- `Setup.cmd` self-elevates. the installer is normally run with `-ExecutionPolicy Bypass`. without
  `-Unattended` it also sets the CurrentUser execution policy to RemoteSigned.
- **downloads are only hash-checked when pinned.** `config/hashes.json` currently pins one file
  (Lenovo's ChargeThreshold.exe, which is also signature-checked). everything else comes from
  winget, Chocolatey or GitHub releases without a pin. `-SkipHashVerify` turns checking off.
- **Chocolatey bootstrap.** if choco is missing the installer downloads and runs
  `https://community.chocolatey.org/install.ps1` with no hash check. `-NoChocoBootstrap` skips it.
- **Defender exclusions** are added for `C:\Setup` (where the ISO stages this repo and the offline
  installers) and `%ProgramFiles%\MATLAB`, if they exist. files there are not scanned.
- **the answer files** (`ISO/autounattend.xml`, `ventoy/script/*.xml`) create a local administrator
  named `My Pc` with a **blank password** and log it in once automatically. Windows normally limits
  blank-password accounts to console logon, but set a password after first boot if the machine
  leaves the bench.
- no secrets live in the tree. passwords and API keys are blank.

## reporting a problem
use GitHub's private vulnerability reporting (Security tab, "Report a vulnerability") instead of a
public issue. include the commit, the command you ran, and what you saw.

## supported versions
the latest commit on `main` and the latest tagged release.
