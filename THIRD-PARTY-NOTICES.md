# third-party notices

this repo configures and installs other people's software. it owns none of it.
the license column is blank on purpose: confirm each one yourself before relying on it.

## installed by the installer (not stored in this repo)
engines per app, first hit wins: staged `-OfflineDir` files, winget, Chocolatey, GitHub releases.

| item | ids / source | license (confirm) |
|---|---|---|
| Komorebi, whkd | `LGUG2Z.komorebi`, `LGUG2Z.whkd` | |
| Helium | `ImputNet.Helium` | |
| VSCodium | `VSCodium.VSCodium` | |
| Vesktop | `Vencord.Vesktop` | |
| Telegram Desktop | `Telegram.TelegramDesktop` | |
| qBittorrent, VLC, OBS Studio | `qBittorrent.qBittorrent`, `VideoLAN.VLC`, `OBSProject.OBSStudio` | |
| Git, Node.js LTS, Python 3.12, 7-Zip | `Git.Git`, `OpenJS.NodeJS.LTS`, `Python.Python.3.12`, `7zip.7zip` | |
| Wireshark | `WiresharkFoundation.Wireshark` | |
| opencode | `SST.opencode` | |
| shell pack | Starship, zoxide, fzf, bat, eza, Fastfetch | |
| study pack (`-IncludeStudy`) | Zotero, SumatraPDF, MiKTeX, Typst, Windows Terminal | |
| optional (`-IncludeOptional`) | Obsidian, Spotify | |
| runtimes | VC++ 2005 to 2022, .NET 8 Desktop Runtime | |
| Chocolatey | bootstrapped when missing | |
| Lenovo ChargeThreshold.exe | downloaded from Lenovo, sha256-pinned, never stored here | |

## stored in this repo
| item | where | license (confirm) |
|---|---|---|
| O&O ShutUp10++ settings (titus cfg) | `OOSU/ooshutup10.cfg`. the exe itself is not committed | |
| Darkmatter VSCodium theme | `VSCodium/darkmatter-theme/` | |
| system24 darkmatter quickcss | `Vesktop/quickcss.css` | |
| tweak list inspired by Chris Titus Tech | `docs/TWEAKS.md` | |

## used to build the ISO
tiny10 (the base image), Ventoy, Windows ADK `oscdimg`. see `ISO/README-ISO.md`.

add the license name and a link for each row. include a copy of any license that requires one.
