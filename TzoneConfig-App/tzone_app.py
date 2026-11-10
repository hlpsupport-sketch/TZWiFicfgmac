#!/usr/bin/env python3
"""Tzone Config - single entry point for the packaged Mac app.

Normal launch (as you): asks macOS for administrator permission with the standard password
dialog, starts itself again as an admin helper (--server), and opens the page in your browser.
"""
import os, sys, time, secrets, random, shlex, subprocess, urllib.request, webbrowser


def alert(text):
    text = text.replace("\\", "\\\\").replace('"', '\\"')
    subprocess.run(["osascript", "-e", f'display dialog "{text}" with title "Tzone Config" buttons {{"OK"}} default button 1'],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def self_command():
    if getattr(sys, "frozen", False):
        return [sys.executable]
    return [sys.executable, os.path.abspath(__file__)]


def run_server(port, token):
    os.environ["TZ_PORT"] = str(port)
    os.environ["TZ_TOKEN"] = token
    import tzone_web
    tzone_web.main()


def launch():
    port = random.randint(20000, 40000)
    token = secrets.token_urlsafe(16)
    cmd = " ".join(shlex.quote(c) for c in self_command() + ["--server", str(port), token])
    shell = f"{cmd} > /tmp/tzone-config.log 2>&1 &"
    shell = shell.replace("\\", "\\\\").replace('"', '\\"')
    osa = (f'do shell script "{shell}" with administrator privileges '
           f'with prompt "Tzone Config needs permission to access the USB logger."')
    r = subprocess.run(["osascript", "-e", osa], capture_output=True, text=True)
    if r.returncode != 0:
        if "-128" in r.stderr:      # user pressed Cancel
            return
        alert("Could not get administrator permission.\n\n" + r.stderr.strip()[:300])
        return
    url = f"http://127.0.0.1:{port}/"
    for _ in range(60):
        try:
            urllib.request.urlopen(url, timeout=1)
            break
        except Exception:
            time.sleep(0.25)
    else:
        alert("The helper did not start. Details are in /tmp/tzone-config.log")
        return
    webbrowser.open(f"{url}?t={token}")


if __name__ == "__main__":
    if len(sys.argv) >= 4 and sys.argv[1] == "--server":
        run_server(int(sys.argv[2]), sys.argv[3])
    else:
        launch()
