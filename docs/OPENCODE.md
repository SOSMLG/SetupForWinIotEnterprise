# OpenCode on this repo

## two different opencode.json files
- `opencode.json` at the repo root configures OpenCode while you work **on this repo**: permissions, a read-only review agent, slash commands.
- `config/opencode.json` is a **deployed** config. the installer copies it to `~\.config\opencode\` on a fresh install (context7 and playwright MCP servers). keep them separate.

## slash commands
| command | does |
|---|---|
| `/test` | runs `tests\run-all.ps1` and summarizes. fixes nothing |
| `/review` | read-only review of your uncommitted diff against the AGENTS.md rules |
| `/precheck` | the AGENTS.md checklist (dry-run lines, `$LASTEXITCODE`, autounattend parity, Get-Offline ids), then the tests |
| `/commit` | drafts a commit message from the staged diff. never runs `git commit` |
| `/dryrun` | runs `install-Win-Iot.ps1 -DryRun`, then reads the log and `report-<stamp>.json` back (they land in `C:\Windows\Logs\Win-Iot-Setup`) |

## permissions in plain words
- allowed without asking: git status, diff, log, show, add, and the test runner
- asks first: commit, push, checkout, deletes, any other shell command
- denied: `reset --hard`, `clean`, force push, `format`
- `.env` files can't be read, sharing is off

## check on first use
1. config keys change between OpenCode versions. if it complains, see opencode.ai/docs/config. the `read` patterns and `subtask` are the likeliest to differ.
2. the last matching bash rule is meant to win. try a harmless `git push` and confirm it asks.
3. no model is set on purpose. pick one with `/models`. free models follow rules less reliably, so the hook, `/precheck` and CI are the real safety net.
