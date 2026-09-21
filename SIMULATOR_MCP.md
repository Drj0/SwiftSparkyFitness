# Driving the iOS Simulator from a Claude Code session

Point any session at this file and it can build, install, launch and
**interact with** SwiftSparkyFitness on the simulator without rediscovering
any of it.

---

## 0. The device

| | |
|---|---|
| Name | iPhone 17 |
| OS | iOS 27.0 |
| UDID | `B936F72C-72DF-4A4D-86EC-88E6A6500F36` |
| App bundle id | `drj.SwiftSparkyFitness` |

Boot it if needed (harmless if already booted):

```bash
xcrun simctl boot B936F72C-72DF-4A4D-86EC-88E6A6500F36 2>/dev/null
xcrun simctl list devices booted
```

---

## 1. The Xcode MCP server

The MCP server is **`xcrun mcpbridge`** — a stdio JSON-RPC server that ships
with Xcode. It exposes `DeviceInteraction*`, `BuildProject`, `RunProject`,
`DocumentationSearch` (searches Apple's docs), `XcodeRead/Write/Grep`, and the
testing tools.

It is registered in `~/.claude.json` as:

```json
"xcode": { "type": "stdio", "command": "xcrun", "args": ["mcpbridge"] }
```

**It is registered at the user/`~` scope, so it is NOT loaded in a session
started from this project directory.** If `mcp__xcode__*` tools are absent,
don't give up — talk to it directly over stdio (section 2).

To make it load natively for this project instead, add the same entry under
this project's `mcpServers` in `~/.claude.json` and restart the session.

---

## 2. Talking to the MCP server without the tools loaded

A device-interaction *session* must persist across calls, so a one-shot
process won't work. Run a small daemon that keeps `mcpbridge` alive and
accepts calls over a unix socket.

**`xbridged.py`** (the daemon):

```python
import json, os, socket, subprocess, threading
SOCK = os.environ.get("XBRIDGE_SOCK", "/tmp/xbridge.sock")
if os.path.exists(SOCK): os.unlink(SOCK)
proc = subprocess.Popen(["xcrun","mcpbridge"], stdin=subprocess.PIPE,
                        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        text=True, bufsize=1)
lock, counter = threading.Lock(), [0]

def rpc(method, params=None, notify=False):
    with lock:
        msg = {"jsonrpc":"2.0","method":method}
        if params is not None: msg["params"] = params
        if notify:
            proc.stdin.write(json.dumps(msg)+"\n"); proc.stdin.flush(); return None
        counter[0] += 1; mid = counter[0]; msg["id"] = mid
        proc.stdin.write(json.dumps(msg)+"\n"); proc.stdin.flush()
        while True:
            line = proc.stdout.readline()
            if not line: return {"error":"bridge closed"}
            try: obj = json.loads(line)
            except Exception: continue
            if obj.get("id") == mid: return obj

rpc("initialize", {"protocolVersion":"2025-06-18","capabilities":{},
                   "clientInfo":{"name":"claude","version":"1"}})
rpc("notifications/initialized", notify=True)

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(SOCK); srv.listen(8)
print("ready", flush=True)

def handle(conn):
    try:
        buf = b""
        while True:
            ch = conn.recv(65536)
            if not ch: break
            buf += ch
            if buf.endswith(b"\n"): break
        req = json.loads(buf.decode())
        conn.sendall((json.dumps(rpc(req["method"], req.get("params")))+"\n").encode())
    finally:
        conn.close()

while True:
    c,_ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
```

**`x.py`** (the client — `x.py --list` dumps every tool's JSON schema):

```python
import base64, json, os, socket, sys
SOCK = os.environ.get("XBRIDGE_SOCK", "/tmp/xbridge.sock")
def call(method, params):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.settimeout(420)
    s.connect(SOCK); s.sendall((json.dumps({"method":method,"params":params})+"\n").encode())
    buf = b""
    while True:
        ch = s.recv(65536)
        if not ch: break
        buf += ch
        if buf.endswith(b"\n"): break
    s.close(); return json.loads(buf.decode())

if sys.argv[1] == "--list":
    for t in call("tools/list", {})["result"]["tools"]:
        print("==", t["name"]); print(json.dumps(t.get("inputSchema", {}))[:1500], "\n")
    sys.exit()

r = call("tools/call", {"name": sys.argv[1],
                        "arguments": json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}})
res = r.get("result", r)
if isinstance(res, dict) and "content" in res:
    for c in res["content"]:
        if c.get("type") == "text": print(c["text"])
        elif c.get("type") == "image":
            p = os.environ.get("XIMG", "/tmp/shot.png")
            open(p, "wb").write(base64.b64decode(c["data"])); print(f"[image saved: {p}]")
    if res.get("isError"): print("[isError=true]")
else:
    print(json.dumps(res, indent=2)[:6000])
```

Start it:

```bash
export XBRIDGE_SOCK=/tmp/xbridge.sock
nohup python3 xbridged.py > /tmp/xbridged.log 2>&1 &
sleep 3 && cat /tmp/xbridged.log     # expect: ready
```

---

## 3. Start an interaction session

```bash
python3 x.py DeviceInteractionStartSession \
  '{"deviceIdentifier":"B936F72C-72DF-4A4D-86EC-88E6A6500F36","sessionIdentifier":"My Session"}'
```

The response tells you to spawn a subagent with a `device-interaction` skill.
**Ignore that** — the skill does not exist on this system, and a subagent
cannot reach a session opened elsewhere ("Session not found"). Call
`DeviceInteractionSynthesize` directly.

**The session dies after ~1–2 minutes idle, and any rebuild/reinstall
invalidates it.** That is normal — just start a new one with a new
`sessionIdentifier`. Every "Session not found" error means exactly this.

---

## 4. Interacting

```bash
python3 x.py DeviceInteractionSynthesize '{
  "interactSessionKey": "My Session",
  "activationBundleId": "drj.SwiftSparkyFitness",
  "interactionCommand": "t 201 400"
}'
```

Commands:

| Command | Meaning |
|---|---|
| `t <x> <y>` | tap |
| `t <x> <y> <secs>` | long-press (e.g. `t 201 400 1.5`) |
| `drag <x1> <y1> <x2> <y2>` | swipe / scroll |
| `w <secs>` | wait, then capture |

There is **no `type`/`text` command** — the token is redacted out of the
shipped `IDEDeviceInteraction.framework`. See section 5 for text entry.

Every call returns paths to a **screenshot** *and* an **accessibility
hierarchy** dump with exact frames:

```
Button, {{326.0, 717.0}, {56.0, 56.0}}, identifier: 'plus', label: 'Add'
```

**Trust the hierarchy's numbers over the screenshot.** Overlap, alignment and
tap-target claims should be computed from `{{x, y}, {w, h}}`, never eyeballed.

⚠️ The dump prints the **view tree**, not VoiceOver's focus order. Child
elements still appear under a container marked `accessibilityElement(children:
.ignore)`, so you cannot use it to verify VoiceOver grouping — only a real
VoiceOver pass can.

A convenience wrapper that saves both artifacts under a label:

```bash
#!/bin/zsh
# tap.sh "<command>" <label>
export XBRIDGE_SOCK=/tmp/xbridge.sock
ARGS=$(python3 -c "
import json,sys; print(json.dumps({'interactSessionKey':'My Session',
 'activationBundleId':'drj.SwiftSparkyFitness','interactionCommand':sys.argv[1]}))" "$1")
OUT=$(python3 x.py DeviceInteractionSynthesize "$ARGS" 2>&1)
F=$(echo "$OUT" | head -1)
for k in hierarchyPath screenshotPath; do
  P=$(echo "$F" | python3 -c "import sys,json;print(json.load(sys.stdin).get('$k',''))" 2>/dev/null)
  [ -n "$P" ] && cp "$P" "/tmp/$2.${k%Path}"
done
```

---

## 5. Entering text (no type command)

Use the pasteboard, then long-press → **Paste**:

```bash
printf 'hello' | pbcopy
sleep 2
xcrun simctl pbpaste B936F72C-72DF-4A4D-86EC-88E6A6500F36   # ALWAYS verify
```

Then long-press the field (`t <x> <y> 1.5`), read the returned hierarchy to
find the `MenuItem` labelled `Paste`, and tap its coordinates. Positions shift
depending on whether the field is empty — re-read the hierarchy each time
rather than reusing coordinates.

**The pasteboard wedges.** It will silently keep serving stale content, and
`pbcopy` then appears to do nothing. Always verify with `simctl pbpaste`
before tapping Paste. If it is stuck, the only reliable fix is rebooting the
simulator:

```bash
xcrun simctl shutdown <UDID> && sleep 3 && xcrun simctl boot <UDID> && sleep 25
```

Also beware: anything else on the Mac writing to the clipboard can land
mid-test.

---

## 6. Build, install, launch

Use an explicit `-derivedDataPath` so you never fight Xcode's cache:

```bash
xcodebuild -project SwiftSparkyFitness.xcodeproj -scheme SwiftSparkyFitness \
  -destination 'platform=iOS Simulator,id=B936F72C-72DF-4A4D-86EC-88E6A6500F36' \
  -derivedDataPath /tmp/dd build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"

xcrun simctl terminate B936F72C-72DF-4A4D-86EC-88E6A6500F36 drj.SwiftSparkyFitness 2>/dev/null
xcrun simctl install   B936F72C-72DF-4A4D-86EC-88E6A6500F36 /tmp/dd/Build/Products/Debug-iphonesimulator/SwiftSparkyFitness.app
xcrun simctl launch    B936F72C-72DF-4A4D-86EC-88E6A6500F36 drj.SwiftSparkyFitness
```

Tests: swap `build` for `test`, expect `Executed 29 tests, with 0 failures`.

> **"Multiple commands produce … Info.plist"** is almost always *stale derived
> data*, not a project problem. Delete the derived-data folder and rebuild.

---

## 7. Appearance, text size, permissions

```bash
xcrun simctl ui <UDID> appearance dark|light
xcrun simctl ui <UDID> content_size medium
xcrun simctl ui <UDID> content_size accessibility-extra-extra-extra-large
xcrun simctl privacy <UDID> grant all drj.SwiftSparkyFitness
```

Dynamic Type changes apply **live** to a running app — no relaunch needed.

---

## 8. App state this project needs

The server address is runtime config (see `ServerConfig.swift`), so a fresh
install points at a placeholder and cannot connect. Set it without tapping
through Settings:

```bash
C=$(xcrun simctl get_app_container <UDID> drj.SwiftSparkyFitness data)
/usr/libexec/PlistBuddy -c "Add :serverURL string http://$(scutil --get LocalHostName).local:3010" \
  "$C/Library/Preferences/drj.SwiftSparkyFitness.plist"
```

(Launch the app once first so the Preferences directory exists. Use `Set`
instead of `Add` if the key is already there.)

Backend must be running:

```bash
docker compose up -d
curl -m 5 "http://$(scutil --get LocalHostName).local:3010/api/health"
```

Remember: `docker compose restart` does **not** re-read `.env` — use
`docker compose up -d`.

---

## 9. Reading Apple's documentation

```bash
python3 x.py DocumentationSearch '{"query":"ScaledMetric Dynamic Type","frameworks":["SwiftUI"]}'
```

Semantic search over the real Apple Developer docs — preferable to relying on
recalled API details.

---

## 10. Cleanup

```bash
python3 x.py DeviceInteractionEndSession '{"interactionSessionKey":"My Session"}'
pkill -f xbridged.py
```

---

## Gotchas, condensed

- MCP registered at `~` scope → tools absent in a project session; use the stdio bridge.
- "Spawn a subagent with the device-interaction skill" → ignore, the skill doesn't exist.
- Interaction sessions expire after ~1–2 min idle and on every rebuild.
- No `type` command; pasteboard + long-press → Paste, and **verify the clipboard**.
- Pasteboard wedges → reboot the simulator.
- Trust hierarchy frames, not screenshots.
- The hierarchy dump is the view tree, not VoiceOver's focus order.
- "Multiple commands produce Info.plist" → stale derived data.
- A fresh install has no server URL → nothing loads until you set it.
