# contributing

small project, simple rules. `AGENTS.md` has the full list of lessons. the short version:

1. test in a VM first. this changes system settings.
2. run `powershell -File tests\run-all.ps1` before every commit (syntax, json, static, module smoke, installer smoke).
3. new switches default off. every write gets a dry-run log line.
4. check `$LASTEXITCODE` after native exes. try/catch alone lies.
5. fresh-install-only deploys never overwrite a lived-in config.
6. edit `ISO/autounattend.xml` and `ventoy/script/Win-Iot-unattended.xml` together.
7. no secrets in the tree. blank values only.
8. keep comments short and plain, like the rest of the repo.

enable the local hook once: `git config core.hooksPath .githooks`

bugs and ideas go in issues. for anything security related, read `SECURITY.md` first.
