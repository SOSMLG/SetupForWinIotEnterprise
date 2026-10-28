# OpenCode on this box

two configs, kept apart on purpose:

- `config/opencode.json`, `config/AGENTS.global.md`, `config/opencode-skills/` are **deployed** by the installer to `~\.config\opencode\` (fresh-only, per file). this is your everyday setup.
- `opencode.json` at the repo root only configures OpenCode while you work **on this repo** (test runner permission, review agent, `/test` `/precheck` `/dryrun`). it inherits everything else from the global one.

## why it is built this way: tokens
every message you send carries OpenCode's system prompt and the definition of every enabled tool. measured with OpenCode 1.19.4, one word ("hello"), numbers are estimates (characters / 4):

| setup | tokens per message |
|---|---|
| stock OpenCode | ~8,100 (system ~3,000, tools ~5,100) |
| the old deployed config (context7 + playwright always on) | **~14,400** (playwright alone ~4,500, 25 tools) |
| **new default agent** (same MCP servers, gated) | **~8,500** |
| `lean` agent | **~3,500** |
| `docs`, `video` agents | ~5,800 |
| `web` agent (playwright on) | ~9,600 |

so the old config made every message about 77% heavier, including the ones that never touched a browser. on a free model with a small context window that is the difference between a long session and a compacted one.

## how
- **gating.** both MCP servers stay configured, but `"tools": {"playwright_*": false, "context7_*": false}` hides them. one agent turns each back on (`web`, `lookup`). you pay for browser tools only while you are testing a site. (the 3 `*_mcp_resource*` helper tools, ~375 tokens, appear whenever any MCP server is on and can't be gated.)
- **short prompts.** an agent with its own `prompt` replaces OpenCode's ~3,000 token default prompt. your `AGENTS.md` files (global and project) still load for every agent. i checked.
- **skills, not rules.** ffmpeg, LaTeX, PowerShell 5.1 and Playwright notes live in skills. each costs ~50 tokens in the prompt (name and description) and its body only loads when the agent asks for it.
- **pinned MCP versions.** `npx -y @upstash/context7-mcp@4.4.4` and `@playwright/mcp@0.0.83`. the old config pulled whatever was latest on every start. bump them on purpose.

## agents (Tab cycles the primary ones)
| agent | use it for | notes |
|---|---|---|
| `build`, `plan` | OpenCode's own defaults | unchanged |
| `lean` | small edits, quick questions | tiny prompt, no todo/webfetch/subagents |
| `web` | testing a site in a real browser | playwright tools on, can't edit files |
| `docs` | Word, PDF, LaTeX | latexmk, pdflatex, xelatex, typst, pandoc run without asking |
| `video` | scripts, captions, ffmpeg, Remotion | ffprobe runs freely, ffmpeg asks first, never overwrites a source |
| `lookup` | library docs (context7) | subagent. `@lookup` it, or let `build` call it. read-only |
| `review` | review a diff | subagent, read-only |

## commands
`/commit` drafts a message and never commits. `/handoff` writes `HANDOFF.md` so you can start a fresh session (long chats cost more per message). `/rmslop` strips AI padding from lines you added. `/usage` shows your last 7 days of tokens and where they went. `/review` reviews your uncommitted diff.
in this repo also: `/test`, `/precheck`, `/dryrun`.

## measure your own setup
```powershell
python tools\token-audit\oc_token_audit.py                # default agent
python tools\token-audit\oc_token_audit.py --agent lean   # one agent
python tools\token-audit\oc_token_audit.py --cwd C:\proj  # with that project's rules
```
it runs OpenCode against a fake local model, records what it sends, and prints system / tools / per-MCP-server cost plus ideas. nothing leaves the machine, no key needed, your config is untouched. this is the video's mitm idea without the proxy and certificate setup. the first run may take a while if it has to fetch the MCP packages.

## upgrading an existing machine
the installer is fresh-only, so a machine that already has `~\.config\opencode\opencode.json` keeps the old heavy one. to switch: back it up, then `install-Win-Iot.ps1 -ConfigsOnly` (this overwrites the other configs too) or copy `config\opencode.json` over by hand.

## still yours to do
- **pick a model.** none is set on purpose. `opencode models`, then `/models` in the TUI. also set a cheap `small_model` (it writes session titles).
- **`opencode providers login`** for your provider.
- permissions, in words: reads and edits are allowed, secrets (`.env`, `.pem`, ssh keys) can't be read. git status/diff/log/show/add run freely. commit, push, checkout, merge, rebase and unknown commands ask. `reset --hard`, `clean`, force push, `rm -rf`, `format`, `diskpart`, `shutdown` are denied.

## what i took from the three sources, and what i left
- from *opencode-video-content*: look at what actually gets sent. built into the audit tool above. its `experimental.openTelemetry` flag exists in 1.19.4 but needs a collector, so it is off.
- from *joelhooks/opencode-config*: separate cheap read-only agents, slash commands, knowledge loaded on demand (skills here), `/handoff`-style flow, `/rmslop`. **not taken:** the swarm/hive/hivemind stack. it needs ollama embeddings, global npm CLIs and a strong paid model, and it runs several agents that each carry their own prompt and tool definitions. that is the opposite of lean.
- from the *CONFIGURATION gist*: the key reference. but it is from Nov 2025 and 1.19.4 differs: `experimental.hook` is gone, `autoupdate` never auto-installs now, `opencode auth` is `opencode providers`, and there are new `compaction`, `skills`, `subagent_depth` and `tool_output` keys. the configs here are validated against the 1.19.4 schema, and CI re-checks that on every push.

## caveats
- token numbers are estimates and were measured through OpenAI-style requests. the default system prompt differs per provider, so your absolute numbers will vary. the relative savings hold. run the audit tool for yours.
- `tool_output` (caps for huge command output) is a real key but i did not set it, because i could not verify its defaults.
- OpenCode changes fast. CI pins `opencode-ai@1.19.4`. bump it when you bump OpenCode, and read the failures.
