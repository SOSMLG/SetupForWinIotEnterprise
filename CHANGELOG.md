# changelog

format follows keep a changelog. versions are git tags like `v0.1.0`.

## [Unreleased]
### fixed
- `Win32-Battery` typo (hyphen) in the power-plan fallback. the laptop-by-battery check could never run, so a laptop with no system type got the desktop power plan. now `Win32_Battery`.
- `-KeepFastStartup` only logged a line, and `powercfg /hibernate off` still ran (which disables fast startup). it now skips the hibernate-off step.
- `Git/.gitconfig` is deployed fresh-only. it has a blank identity, so overwriting on re-run would have wiped the user's name and email.
- `Git/.gitconfig` was missing from the repo. the installer logged a skip and the README promised it.
- `.gitignore` was missing. AGENTS.md says it excludes `*.iso`, `ISO/build/`, `ISO/Offline/`.
- removed a stray 2-byte file `ISO/s`.

### added
- `tests/static-check.ps1`: wmi class names, script encoding, call-before-define, gitconfig deploy, the KeepFastStartup gate, plus warnings for unused params and missing expected files. wired into `run-all.ps1`.
- CI (`tests.yml`), release workflow, Dependabot, issue forms, PR template.
- local pre-commit hook (`.githooks/`): blocks 99 MB+ files and obvious keys, runs tests.
- `.gitattributes`, `.editorconfig`, `opencode.json` (project permissions, review agent, slash commands).
- docs: `docs/TWEAKS.md`, `docs/OPENCODE.md`, `CONTRIBUTING.md`, `SECURITY.md`, `THIRD-PARTY-NOTICES.md`.

### changed
- README split into a short front page and `docs/TWEAKS.md`. config table now lists the real file names and which configs overwrite on re-run.
- AGENTS.md: workflow rules for agents, and the OOSU note now says the exe is not committed.
