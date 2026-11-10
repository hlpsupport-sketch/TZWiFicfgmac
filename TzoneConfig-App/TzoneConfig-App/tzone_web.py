#!/usr/bin/env python3
"""Local one-window UI (opens in your browser). Run via 'Tzone Config.command'."""
import json, os, sys, threading, secrets, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import tzone_proto as tp

PORT = int(os.environ.get("TZ_PORT", "8765"))
TOKEN = os.environ.get("TZ_TOKEN") or secrets.token_urlsafe(16)
LOCK = threading.Lock()
IDLE_SECONDS = 20 * 60
_last = [time.time()]

PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Tzone WiFi Setup</title>
<style>
:root{--bg:#f5f5f7;--card:#fff;--ink:#1d1d1f;--mute:#6e6e73;--line:#d2d2d7;--acc:#0a6cff;--ok:#1a7f37;--bad:#c62828}
@media (prefers-color-scheme:dark){:root{--bg:#1c1c1e;--card:#2c2c2e;--ink:#f5f5f7;--mute:#98989d;--line:#48484a;--acc:#4c9aff;--ok:#4cc26b;--bad:#ff6b6b}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.45 -apple-system,system-ui,sans-serif;display:flex;justify-content:center;padding:32px 16px}
main{width:100%;max-width:520px;background:var(--card);border:1px solid var(--line);border-radius:14px;padding:24px}
h1{font-size:20px;margin:0 0 4px}p.sub{margin:0 0 20px;color:var(--mute);font-size:14px}
dl{display:grid;grid-template-columns:110px 1fr;gap:6px 12px;margin:0 0 18px;font-size:15px}dt{color:var(--mute)}dd{margin:0;word-break:break-all}
label{display:block;font-size:14px;color:var(--mute);margin:12px 0 4px}
input[type=text]{width:100%;padding:10px 12px;font-size:16px;border:1px solid var(--line);border-radius:8px;background:transparent;color:var(--ink)}
input:disabled{opacity:.5}.row{display:flex;gap:10px;margin-top:20px;align-items:center}
button{font:inherit;padding:10px 18px;border-radius:8px;border:1px solid var(--line);background:transparent;color:var(--ink);cursor:pointer}
button.primary{background:var(--acc);border-color:var(--acc);color:#fff}button:disabled{opacity:.45;cursor:default}
.chk{display:flex;gap:8px;align-items:center;font-size:14px;color:var(--mute);margin-top:14px}
#msg{margin-top:16px;min-height:22px;font-size:14px}.ok{color:var(--ok)}.bad{color:var(--bad)}.sp{flex:1}
</style></head><body><main>
<h1>Tzone WiFi Setup</h1><p class="sub">Plug in a WF501 / WF502 logger, then press Read.</p>
<dl><dt>Model</dt><dd id="model">&ndash;</dd><dt>Device ID</dt><dd id="id">&ndash;</dd><dt>Clock</dt><dd id="time">&ndash;</dd></dl>
<label for="ssid">WiFi name</label><input id="ssid" type="text" autocomplete="off" disabled>
<label for="pw">WiFi password</label><input id="pw" type="text" autocomplete="off" disabled>
<label class="chk"><input type="checkbox" id="clock"> Also set the logger clock to now</label>
<div class="row"><button id="read" class="primary">Read</button><button id="save" disabled>Save to logger</button><span class="sp"></span><button id="quit">Quit</button></div>
<div id="msg" role="status"></div></main>
<script>
const T=new URLSearchParams(location.search).get('t')||'';const $=i=>document.getElementById(i);
function msg(t,c){$('msg').textContent=t;$('msg').className=c||''}
async function call(path,body){const r=await fetch(path,{method:'POST',headers:{'X-Token':T,'Content-Type':'application/json'},body:JSON.stringify(body||{})});
 const j=await r.json();if(!r.ok||j.error)throw new Error(j.error||('HTTP '+r.status));return j}
function busy(b){$('read').disabled=b;$('save').disabled=b||!window.canSave}
function fill(j){$('model').textContent=j.model||'–';$('id').textContent=j.id||'–';$('time').textContent=j.time||'not reported by logger';
 window.canSave=j.wifi;$('ssid').disabled=$('pw').disabled=!j.wifi;if(j.wifi){$('ssid').value=j.ssid;$('pw').value=j.password}}
$('read').onclick=async()=>{busy(true);msg('Reading logger… (needs a few seconds)');try{fill(await call('/api/read'));msg(window.canSave?'Read OK.':'Read OK, but WiFi settings are only available for WF501/WF502 models.','ok')}catch(e){msg(e.message,'bad')}busy(false)};
$('save').onclick=async()=>{busy(true);msg('Writing to logger…');try{const j=await call('/api/save',{ssid:$('ssid').value.trim(),password:$('pw').value.trim(),clock:$('clock').checked});fill(j);msg(j.verified?'Saved and verified: the logger now holds these settings.':'Written, but the logger reports different values - please try again.',j.verified?'ok':'bad')}catch(e){msg(e.message,'bad')}busy(false)};
$('quit').onclick=async()=>{try{await call('/api/quit')}catch(e){}document.body.innerHTML='<p style="padding:40px">You can close this tab.</p>'};
</script></body></html>"""


def snapshot(lg, info):
    cfg = lg.get_wifi_config() if info.dtype in tp.WIFI_DTYPES else None
    t = None
    if cfg and cfg.device_time_utc:
        t = cfg.device_time_utc.astimezone().strftime("%Y/%m/%d %H:%M:%S")
    return {"model": info.hardware, "id": info.device_id, "firmware": info.firmware,
            "wifi": cfg is not None, "time": t,
            "ssid": cfg.ssid if cfg else "", "password": cfg.password if cfg else ""}


class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def _send(self, code, body, ctype="application/json"):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def _host_ok(self):
        return self.headers.get("Host", "") in (f"127.0.0.1:{PORT}", f"localhost:{PORT}")

    def do_GET(self):
        _last[0] = time.time()
        if not self._host_ok():
            return self._send(403, "forbidden", "text/plain")
        self._send(200, PAGE, "text/html")

    def do_POST(self):
        _last[0] = time.time()
        if not self._host_ok() or self.headers.get("X-Token") != TOKEN:
            return self._send(403, json.dumps({"error": "forbidden"}))
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            return self._send(400, json.dumps({"error": "bad request"}))
        if self.path == "/api/quit":
            self._send(200, "{}")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        try:
            with LOCK:
                t = tp.open_logger()
                try:
                    lg = tp.Logger(t)
                    info = lg.get_info()
                    if self.path == "/api/read":
                        out = snapshot(lg, info)
                    elif self.path == "/api/save":
                        if info.dtype not in tp.WIFI_DTYPES:
                            raise tp.TzoneError("WiFi settings are only supported on WF501/WF502 models.")
                        ssid, pw = str(body.get("ssid", "")), str(body.get("password", ""))
                        lg.set_wifi_config(ssid, pw, set_time=bool(body.get("clock")))
                        out = snapshot(lg, info)
                        out["verified"] = (out["ssid"], out["password"]) == (ssid, pw)
                    else:
                        return self._send(404, json.dumps({"error": "not found"}))
                finally:
                    t.close()
            self._send(200, json.dumps(out))
        except (tp.TzoneError, UnicodeError) as e:
            self._send(200, json.dumps({"error": str(e)}))
        except Exception as e:  # noqa
            self._send(200, json.dumps({"error": f"Unexpected error: {e}"}))


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    def watchdog():
        while True:
            time.sleep(15)
            if time.time() - _last[0] > IDLE_SECONDS:
                srv.shutdown()
                return
    threading.Thread(target=watchdog, daemon=True).start()
    print(f"Tzone WiFi Setup running at http://127.0.0.1:{PORT}/?t={TOKEN}", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
