#!/usr/bin/env python3
"""oc_token_audit.py: how many tokens does OpenCode send for one short message?

it starts a tiny local fake model server, runs `opencode run "hello"` against it,
records the request and breaks it down: system prompt, each tool, each MCP server.
your config is not changed. nothing leaves the machine. no api key needed.

  python oc_token_audit.py                 default agent, current folder
  python oc_token_audit.py --agent lean    audit one agent
  python oc_token_audit.py --cwd C:\\proj  audit with that project's AGENTS.md and config

tokens are estimated as characters / 4. close enough to compare setups, not to bill by.
idea from agardnerIT/opencode-video-content ("7000 tokens to say hello").
"""
import argparse, json, os, shutil, subprocess, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BUILTIN = {'bash', 'read', 'glob', 'grep', 'edit', 'write', 'task', 'webfetch', 'websearch',
           'todowrite', 'todoread', 'skill', 'lsp', 'patch', 'multiedit', 'batch', 'question'}
MCP_HELPERS = {'read_mcp_resource', 'list_mcp_resources', 'list_mcp_resource_templates'}

seen = []
got_main = threading.Event()


class Recorder(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(b'{"object":"list","data":[]}')

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get('Content-Length', 0)))
        try:
            body = json.loads(raw)
        except ValueError:
            body = {}
        seen.append(body)
        if body.get('tools'):
            got_main.set()
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.end_headers()
        self.wfile.write(b'data: [DONE]\n\n')


def est(chars):
    return round(chars / 4)


def text_of(content):
    if isinstance(content, str):
        return content
    parts = []
    for c in content or []:
        parts.append(c.get('text', '') if isinstance(c, dict) else str(c))
    return ''.join(parts)


def analyze(req):
    sys_chars = len(req.get('instructions') or '')
    user_chars = 0
    msgs = req.get('input') or req.get('messages') or []
    for m in msgs:
        t = text_of(m.get('content'))
        if m.get('role') in ('system', 'developer'):
            sys_chars += len(t)
        else:
            user_chars += len(t)
    tools = []
    for t in req.get('tools') or []:
        name = t.get('name') or (t.get('function') or {}).get('name') or '?'
        tools.append((name, len(json.dumps(t))))
    tools.sort(key=lambda x: -x[1])
    groups = {}
    for name, chars in tools:
        if name in BUILTIN or name in MCP_HELPERS or '_' not in name:
            g = 'built-in' if name in BUILTIN else ('mcp helpers' if name in MCP_HELPERS else 'other')
        else:
            g = 'mcp: ' + name.split('_', 1)[0]
        groups.setdefault(g, [0, 0])
        groups[g][0] += 1
        groups[g][1] += chars
    tool_chars = sum(c for _, c in tools)
    return {
        'total': est(sys_chars + user_chars + tool_chars),
        'system': est(sys_chars), 'user': est(user_chars),
        'tools_count': len(tools), 'tools': est(tool_chars),
        'per_tool': {n: est(c) for n, c in tools},
        'groups': {g: {'count': v[0], 'tokens': est(v[1])} for g, v in groups.items()},
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--agent', help='agent name (default: the default agent)')
    ap.add_argument('--cwd', default=os.getcwd(), help='project folder to run in')
    ap.add_argument('--prompt', default='hello')
    ap.add_argument('--opencode', default='opencode', help='path to the opencode binary')
    ap.add_argument('--timeout', type=int, default=90)
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()

    exe = shutil.which(args.opencode)
    if not exe:
        sys.exit('opencode not found on PATH. pass --opencode <path>.')

    srv = ThreadingHTTPServer(('127.0.0.1', 0), Recorder)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    override = {
        'provider': {'openai': {
            'options': {'baseURL': 'http://127.0.0.1:%d/v1' % port, 'apiKey': 'audit'},
            'models': {'gpt-4o': {'name': 'audit', 'limit': {'context': 128000, 'output': 4096}}}}},
        'model': 'openai/gpt-4o', 'small_model': 'openai/gpt-4o',
    }
    env = dict(os.environ, OPENCODE_CONFIG_CONTENT=json.dumps(override),
               OPENCODE_DISABLE_MODELS_FETCH='1', OPENCODE_DISABLE_AUTOUPDATE='1')
    cmd = [exe, 'run'] + (['--agent', args.agent] if args.agent else []) + [args.prompt]
    if exe.lower().endswith(('.cmd', '.bat')):
        cmd = ['cmd', '/c'] + cmd
    proc = subprocess.Popen(cmd, cwd=args.cwd, env=env, stdin=subprocess.DEVNULL,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    got_main.wait(args.timeout)
    proc.kill()
    srv.shutdown()

    mains = [r for r in seen if r.get('tools')]
    if not mains:
        sys.exit('no request captured. try --timeout 180 (first run may be installing MCP servers).')
    res = analyze(max(mains, key=lambda r: len(json.dumps(r))))

    if args.json:
        print(json.dumps(res, indent=2))
        return
    who = args.agent or 'default agent'
    print('%s, one "%s" message: ~%d tokens' % (who, args.prompt, res['total']))
    print('  system prompt        ~%d' % res['system'])
    print('  tool definitions     ~%d  (%d tools)' % (res['tools'], res['tools_count']))
    print('  your message         ~%d' % res['user'])
    print('\nby source:')
    for g, v in sorted(res['groups'].items(), key=lambda kv: -kv[1]['tokens']):
        print('  %-22s ~%-6d %d tools' % (g, v['tokens'], v['count']))
    print('\nbiggest tools:')
    for n, t in list(res['per_tool'].items())[:8]:
        print('  %-40s ~%d' % (n, t))
    tips = []
    for g, v in res['groups'].items():
        if g.startswith('mcp: ') and v['tokens'] > 1500:
            s = g[5:]
            tips.append('%s costs ~%d tokens on every message. gate it: "tools": {"%s_*": false} globally, true on one agent.' % (s, v['tokens'], s))
    if res['system'] > 2500 and not args.agent:
        tips.append('the default system prompt is ~%d tokens. an agent with its own short "prompt" replaces it.' % res['system'])
    if tips:
        print('\nideas:')
        for t in tips:
            print('  - ' + t)


if __name__ == '__main__':
    main()
