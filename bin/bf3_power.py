import json
import requests
import sys

TOKEN = "<REPLACE ME>"
HA_API_ENDPOINT = "http://rpi.local:8123"
VALID_STATES = ["on", "off"]
# Entity ID of the socket that the BF3 is plugged into
BF3_SOCKET_ENTITY_ID = "switch.tp_link_power_strip_b225_plug_1"


def main():
    if len(sys.argv) < 2:
        raise Exception("Usage: ./bf3_power.py [off|on]")

    new_state = sys.argv[1].lower()
    if new_state not in VALID_STATES:
        raise Exception(f"{new_state} is not a valid state")

    url = f"{HA_API_ENDPOINT}/api/services/switch/turn_{new_state}"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {TOKEN}"
    }
    payload = {
        "entity_id": BF3_SOCKET_ENTITY_ID
    }
    r = requests.post(url, headers=headers, data=json.dumps(payload))

    if r.status_code != 200:
        raise Exception(f"Unexpected response: {r.status_code} {r.reason}")


if __name__ == "__main__":
    main()
