"""Provision our Portainer HA stack, onboard HA, and verify real MQTT entities.

Run from the laptop with requirements-dev.txt installed. Passwords are read from
the ignored .env file; tokens and API responses containing secrets are not logged.
Existing HA users and MQTT integrations are preserved. The dedicated Team Zero
    dashboard is updated from deploy/ha-dashboard.json on each run.
"""
import argparse
import asyncio
import json
from pathlib import Path

import aiohttp

ROOT = Path(__file__).resolve().parents[1]


def environment():
    return dict(
        line.split("=", 1)
        for line in (ROOT / ".env").read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#") and "=" in line
    )


async def request(session, method, url, *, token=None, **kwargs):
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    async with session.request(method, url, headers=headers, **kwargs) as response:
        if response.status >= 400:
            # Bodies can contain passwords, tokens, or reflected request data.
            raise RuntimeError(f"{method} {url.split('?')[0]}: HTTP {response.status}")
        return await response.json()


async def portainer_stack(session, args, env):
    base = args.portainer_url.rstrip("/") + "/api"
    # Portainer's fresh installation generates its own self-signed certificate.
    # This override applies only to explicitly requested Portainer API calls.
    options = {"ssl": False} if args.portainer_self_signed else {}
    auth = await request(session, "POST", base + "/auth", json={
        "Username": "admin", "Password": env["PORTAINER_ADMIN_PASSWORD"],
    }, **options)
    token = auth["jwt"]
    endpoints = await request(session, "GET", base + "/endpoints", token=token, **options)
    local = [e for e in endpoints if e["URL"] == "unix:///var/run/docker.sock"]
    if len(local) != 1:
        raise RuntimeError("Expected one local Docker socket environment in Portainer")
    endpoint_id = local[0]["Id"]
    stacks = await request(session, "GET", base + "/stacks", token=token, **options)
    matches = [s for s in stacks if s["Name"] == "water-homeassistant"
               and s["EndpointId"] == endpoint_id]
    if not matches:
        await request(session, "POST", base + "/stacks/create/standalone/string",
                      params={"endpointId": endpoint_id}, token=token, json={
                          "Name": "water-homeassistant",
                          "StackFileContent": (ROOT / "deploy/homeassistant.compose.yaml").read_text(),
                          "Env": [{"name": "WATER_PROJECT_DIR", "value": args.remote_dir}],
                      }, **options)
        print("Created water-homeassistant stack in Portainer.", flush=True)
    else:
        print("Portainer HA stack already exists; preserving its running configuration.", flush=True)


async def wait_ready(session, base):
    for attempt in range(180):
        try:
            async with session.get(base + "/manifest.json") as response:
                if response.status == 200:
                    return
        except (aiohttp.ClientError, asyncio.TimeoutError):
            pass
        if attempt % 10 == 0:
            print("Waiting for Home Assistant startup...", flush=True)
        await asyncio.sleep(5)
    raise RuntimeError("Home Assistant did not start within 15 minutes")


async def authenticate(session, base, env):
    client_id = base + "/"
    async with session.get(base + "/api/onboarding") as response:
        steps = await response.json() if response.status == 200 else []
    if any(s["step"] == "user" and not s["done"] for s in steps):
        result = await request(session, "POST", base + "/api/onboarding/users", json={
            "name": "Dewin", "username": "teamzero",
            "password": env["HA_ADMIN_PASSWORD"], "client_id": client_id, "language": "en",
        })
        code = result["auth_code"]
        print("Created Home Assistant administrator teamzero.", flush=True)
    else:
        flow = await request(session, "POST", base + "/auth/login_flow", json={
            "client_id": client_id, "redirect_uri": client_id,
            "handler": ["homeassistant", None],
        })
        result = await request(session, "POST", base + "/auth/login_flow/" + flow["flow_id"], json={
            "client_id": client_id, "username": "teamzero", "password": env["HA_ADMIN_PASSWORD"],
        })
        if result["type"] != "create_entry":
            raise RuntimeError("Home Assistant login requires attention")
        code = result["result"]
    auth = await request(session, "POST", base + "/auth/token", data={
        "grant_type": "authorization_code", "code": code, "client_id": client_id,
    })
    token = auth["access_token"]
    for step in steps:
        if step["done"] or step["step"] == "user":
            continue
        data = {"client_id": client_id, "redirect_uri": client_id} if step["step"] == "integration" else {}
        await request(session, "POST", base + "/api/onboarding/" + step["step"], token=token, json=data)
    # Token is short-lived and used only in this process; no bearer token is saved.
    return token, auth["refresh_token"], client_id


async def mqtt_integration(session, base, token, env):
    entries = await request(session, "GET", base + "/api/config/config_entries/entry", token=token)
    mqtt = [e for e in entries if e["domain"] == "mqtt"]
    if mqtt:
        print("Existing MQTT integration preserved.", flush=True)
        return
    flow = await request(session, "POST", base + "/api/config/config_entries/flow", token=token,
                         json={"handler": "mqtt", "show_advanced_options": True})
    if flow.get("step_id") != "broker":
        raise RuntimeError("Expected HA Container's manual MQTT broker setup")
    result = await request(session, "POST", base + "/api/config/config_entries/flow/" + flow["flow_id"],
                           token=token, json={
                               "broker": "127.0.0.1", "port": 1883, "protocol": "3.1.1",
                               "username": "homeassistant", "password": env["HA_PASSWORD"],
                               "other_settings": {"set_ca_cert": "off", "set_client_cert": False,
                                                  "transport": "tcp"},
                           })
    if result["type"] != "create_entry":
        raise RuntimeError(f"MQTT setup did not complete: {result.get('errors', {})}")
    print("Home Assistant MQTT connected to NATS using MQTT 3.1.1.", flush=True)


async def dashboard(session, base, token):
    async with session.ws_connect(base + "/api/websocket") as ws:
        await ws.receive_json()
        await ws.send_json({"type": "auth", "access_token": token})
        if (await ws.receive_json())["type"] != "auth_ok":
            raise RuntimeError("HA WebSocket authentication failed")
        sequence = 0

        async def command(kind, **kwargs):
            nonlocal sequence
            sequence += 1
            await ws.send_json({"id": sequence, "type": kind, **kwargs})
            while True:
                result = await ws.receive_json()
                if result.get("id") == sequence:
                    if not result.get("success"):
                        raise RuntimeError(f"HA command {kind} failed: {result.get('error', {}).get('code')}")
                    return result.get("result")

        dashboards = await command("lovelace/dashboards/list")
        existing = next((d for d in dashboards if d["url_path"] == "team-zero"), None)
        if existing is None:
            await command("lovelace/dashboards/create", url_path="team-zero", title="Dewin",
                          icon="mdi:water-thermometer", show_in_sidebar=True, require_admin=False)
        elif existing["title"] != "Dewin":
            await command("lovelace/dashboards/update", dashboard_id=existing["id"], title="Dewin")
        config = json.loads((ROOT / "deploy/ha-dashboard.json").read_text(encoding="utf-8"))
        await command("lovelace/config/save", url_path="team-zero", config=config)
        print("Saved Dewin dashboard with three simulated Pico devices.", flush=True)
        return set(e for view in config["views"] for card in view["cards"] for e in card.get("entities", []))


async def verify(session, base, token, expected):
    for attempt in range(36):
        states = await request(session, "GET", base + "/api/states", token=token)
        found = {s["entity_id"]: s for s in states if s["entity_id"] in expected}
        if expected <= found.keys() and all(s["state"] not in {"unknown", "unavailable"} for s in found.values()):
            print(f"Verified {len(found)} live HA entities:", flush=True)
            for name, state in sorted(found.items()):
                print(f"  {name}: {state['state']} {state['attributes'].get('unit_of_measurement', '')}", flush=True)
            return
        if attempt % 6 == 0:
            print(f"Waiting for MQTT discovery/live readings ({len(found)}/{len(expected)} entities)...", flush=True)
        await asyncio.sleep(5)
    raise RuntimeError("Not all simulated HA entities became available")


async def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ha-url", required=True)
    parser.add_argument("--portainer-url", required=True)
    parser.add_argument("--portainer-self-signed", action="store_true")
    parser.add_argument("--remote-dir", default="/home/hacker9/team-zero-water-monitor")
    args = parser.parse_args()
    env = environment()
    base = args.ha_url.rstrip("/")
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=45)) as session:
        await portainer_stack(session, args, env)
        await wait_ready(session, base)
        token, refresh, client_id = await authenticate(session, base, env)
        try:
            await mqtt_integration(session, base, token, env)
            expected = await dashboard(session, base, token)
            await verify(session, base, token, expected)
        finally:
            # Revoke our temporary login session; the admin's browser logins are independent.
            async with session.post(base + "/auth/token", data={"action": "revoke", "token": refresh}):
                pass


if __name__ == "__main__":
    asyncio.run(main())
