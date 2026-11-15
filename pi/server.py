#!/usr/bin/env python3
"""
PrintDeck - Raspberry Pi backend
- Connects to Creality K2 Combo over its local WebSocket (port 9999)
- Caches the current-print thumbnail from the printer
- Listens for the Mac "Omni Bridge" broadcast and polls its status
- Serves the full-screen dashboard on http://localhost:5000
"""
import asyncio
import json
import logging
import os
import socket
import ssl
import time
import uuid

from aiohttp import ClientSession, ClientTimeout, WSMsgType, web

BASE = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(BASE, "config.json")) as f:
    CFG = json.load(f)

K2_IP = CFG.get("k2_ip", "").strip()
K2_PORT = int(CFG.get("k2_ws_port", 9999))
BRIDGE_UDP_PORT = int(CFG.get("bridge_discovery_port", 47800))
DASH_PORT = int(CFG.get("dashboard_port", 5000))

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("printdeck")

def _read_version():
    try:
        with open(os.path.join(BASE, ".version")) as f:
            return f.read().strip()[:7]
    except OSError:
        return "dev"


STATE = {
    "boot_id": uuid.uuid4().hex,
    "version": _read_version(),
    "k2": {"connected": False, "last_rx": 0, "raw": {}, "thumb_ver": 0},
    "omni": {"connected": False, "bridge": None, "status": {}, "last_rx": 0},
    "config": {
        "camera_mode": CFG.get("camera_mode", "webrtc"),
        "go2rtc_port": int(CFG.get("go2rtc_port", 1984)),
        "k2_ip": K2_IP,
        "k2_name": CFG.get("k2_name", "Creality K2 Combo"),
        "pi_camera": CFG.get("pi_camera", "lite"),   # lite = small MJPEG on the Pi screen; webrtc = full HD
    },
}
THUMB = {"png": None, "file": None, "fetched": 0}

# ---------------------------------------------------------------- K2 ----

def _ssl_noverify():
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


async def fetch_thumbnail(session):
    """Printer serves the sliced preview of the current job here."""
    path = "/downloads/original/current_print_image.png"
    for scheme in ("http", "https"):
        url = f"{scheme}://{K2_IP}{path}"
        try:
            kw = {"ssl": _ssl_noverify()} if scheme == "https" else {}
            async with session.get(url, timeout=ClientTimeout(total=6), **kw) as r:
                if r.status == 200:
                    data = await r.read()
                    if data[:8] == b"\x89PNG\r\n\x1a\n":
                        THUMB["png"] = data
                        THUMB["fetched"] = time.time()
                        STATE["k2"]["thumb_ver"] += 1
                        log.info("Thumbnail updated (%d bytes)", len(data))
                        return True
        except Exception as e:
            log.debug("thumb %s failed: %s", url, e)
    return False


async def k2_heartbeat(ws):
    while True:
        await asyncio.sleep(10)
        msg = {"ModeCode": "heart_beat", "msg": time.strftime("%Y-%m-%d %H:%M:%S")}
        await ws.send_str(json.dumps(msg))


async def k2_thumb_watcher(session):
    """Refetch thumbnail when the file name changes, or every 60 s while printing."""
    while True:
        await asyncio.sleep(3)
        raw = STATE["k2"]["raw"]
        fname = raw.get("printFileName") or ""
        printing = str(raw.get("state", "")) in ("1", "5")
        stale = time.time() - THUMB["fetched"] > 60
        if STATE["k2"]["connected"] and fname and (fname != THUMB["file"] or (printing and stale)):
            if await fetch_thumbnail(session):
                THUMB["file"] = fname
            else:
                THUMB["fetched"] = time.time()  # don't hammer it


async def k2_loop(app):
    if not K2_IP:
        log.warning("No k2_ip in config.json - K2 disabled")
        return
    url = f"ws://{K2_IP}:{K2_PORT}"
    backoff = 2
    async with ClientSession() as session:
        thumb_task = asyncio.create_task(k2_thumb_watcher(session))  # noqa: F841
        while True:
            try:
                log.info("Connecting to K2 at %s", url)
                async with session.ws_connect(url, timeout=10, max_msg_size=0) as ws:
                    STATE["k2"]["connected"] = True
                    backoff = 2
                    log.info("K2 connected")
                    hb = asyncio.create_task(k2_heartbeat(ws))
                    try:
                        # Ask for a full dump (printer also pushes on its own)
                        for req in ({"method": "get", "params": {"reqPrinterPara": 1}},
                                    {"method": "get", "params": {"boxsInfo": 1}},
                                    {"method": "get", "params": {"reqMaterials": 1}}):
                            await ws.send_str(json.dumps(req))
                        while True:
                            msg = await ws.receive(timeout=45)
                            if msg.type == WSMsgType.TEXT:
                                STATE["k2"]["last_rx"] = time.time()
                                await handle_k2_message(ws, msg.data)
                            elif msg.type in (WSMsgType.CLOSED, WSMsgType.CLOSING, WSMsgType.ERROR):
                                break
                    finally:
                        hb.cancel()
            except asyncio.TimeoutError:
                log.warning("K2 went quiet for 45 s - reconnecting")
            except Exception as e:
                log.warning("K2 connection error: %s", e)
            STATE["k2"]["connected"] = False
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 30)


async def handle_k2_message(ws, data):
    data = data.strip()
    if not data.startswith("{"):
        return  # printer answers heartbeats with plain "ok"
    try:
        obj = json.loads(data)
    except json.JSONDecodeError:
        return
    if not isinstance(obj, dict):
        return
    if obj.get("ModeCode") == "heart_beat":
        await ws.send_str("ok")
        return
    # Some fields arrive as JSON-encoded strings; decode them
    for k, v in list(obj.items()):
        if isinstance(v, str) and v[:1] in "[{":
            try:
                obj[k] = json.loads(v)
            except json.JSONDecodeError:
                pass
    STATE["k2"]["raw"].update(obj)

# ------------------------------------------------------- Omni bridge ----

class BridgeDiscovery(asyncio.DatagramProtocol):
    """Mac app broadcasts:  PRINTDECK_OMNI_BRIDGE <http_port>"""
    def datagram_received(self, data, addr):
        try:
            text = data.decode().strip().split()
        except UnicodeDecodeError:
            return
        if len(text) >= 2 and text[0] == "PRINTDECK_OMNI_BRIDGE":
            url = f"http://{addr[0]}:{int(text[1])}"
            if STATE["omni"]["bridge"] != url:
                log.info("Found Omni Bridge at %s", url)
            STATE["omni"]["bridge"] = url


async def omni_loop(app):
    fixed = CFG.get("bridge_url", "").strip()
    if fixed:
        STATE["omni"]["bridge"] = fixed.rstrip("/")
    else:
        loop = asyncio.get_running_loop()
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(("0.0.0.0", BRIDGE_UDP_PORT))
        await loop.create_datagram_endpoint(BridgeDiscovery, sock=sock)
        log.info("Listening for Omni Bridge broadcasts on UDP %d", BRIDGE_UDP_PORT)

    async with ClientSession() as session:
        while True:
            url = STATE["omni"]["bridge"]
            if url:
                try:
                    async with session.get(url + "/status.json", timeout=ClientTimeout(total=3)) as r:
                        STATE["omni"]["status"] = await r.json(content_type=None)
                        STATE["omni"]["connected"] = True
                        STATE["omni"]["last_rx"] = time.time()
                except Exception:
                    if time.time() - STATE["omni"]["last_rx"] > 10:
                        STATE["omni"]["connected"] = False
            await asyncio.sleep(2)

# --------------------------------------------------------------- web ----

async def api_state(request):
    return web.json_response(STATE, headers={"Cache-Control": "no-store"})


async def api_raw(request):
    """Everything the K2 has sent - handy for debugging field names."""
    return web.json_response(STATE["k2"]["raw"], dumps=lambda o: json.dumps(o, indent=2, sort_keys=True))


async def api_thumb(request):
    if not THUMB["png"]:
        raise web.HTTPNotFound()
    return web.Response(body=THUMB["png"], content_type="image/png",
                        headers={"Cache-Control": "no-store"})


async def index(request):
    return web.FileResponse(os.path.join(BASE, "static", "index.html"),
                            headers={"Cache-Control": "no-store"})


async def on_startup(app):
    app["k2_task"] = asyncio.create_task(k2_loop(app))
    app["omni_task"] = asyncio.create_task(omni_loop(app))


def main():
    app = web.Application()
    app.router.add_get("/", index)
    app.router.add_get("/api/state", api_state)
    app.router.add_get("/api/thumb.png", api_thumb)
    app.router.add_get("/api/raw", api_raw)
    app.router.add_static("/static/", os.path.join(BASE, "static"))
    app.on_startup.append(on_startup)
    web.run_app(app, host="0.0.0.0", port=DASH_PORT, print=None)


if __name__ == "__main__":
    main()
