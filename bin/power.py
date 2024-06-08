#!/usr/bin/env python3
import json
import requests
import sys

TOKEN = "<REPLACE ME>"
HA_API_ENDPOINT = "http://rpi.local:8123"
VALID_STATES = ["on", "off"]
SOCKET_IDS = {
    "bf3": "1",
    "host": "2"
}
DEFAULT_HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Content-Type": "application/json"
}

# Templatized string for HA entity IDs
SOCKET_ENTITY_ID = "switch.tp_link_power_strip_b225_plug_{}"


def set_state(entity_id, new_state):
    if new_state not in VALID_STATES:
        raise Exception(f"{new_state} is not a valid state")

    url = f"{HA_API_ENDPOINT}/api/services/switch/turn_{new_state}"
    payload = {
        "entity_id": entity_id
    }
    r = requests.post(url, headers=DEFAULT_HEADERS, data=json.dumps(payload))

    if r.status_code != 200:
        raise Exception(f"Unexpected response: {r.status_code} {r.reason}")


def get_state(entity_id):
    url = f"{HA_API_ENDPOINT}/api/states/{entity_id}"
    r = requests.get(url, headers=DEFAULT_HEADERS)

    if r.status_code != 200:
        raise Exception(f"Unexpected response: {r.status_code} {r.reason}")

    response = json.loads(r.content)
    print(response["state"])


def main():
    if len(sys.argv) < 2:
        raise Exception("Usage: power.py <device> [<state>]")

    device = sys.argv[1]
    if device.lower() not in SOCKET_IDS:
        raise Exception(f"Invalid device '{device}'! Valid devices are {list(SOCKET_IDS.keys())}")
    socket_id = SOCKET_IDS[device]
    entity_id = SOCKET_ENTITY_ID.format(socket_id)

    if len(sys.argv) == 2:
        get_state(entity_id)
    else:
        set_state(entity_id, sys.argv[2].lower())


if __name__ == "__main__":
    main()
