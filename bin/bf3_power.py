import json
import requests
import sys

TOKEN = "<REPLACE ME>"
HA_API_ENDPOINT = "http://rpi.local:8123"
VALID_STATES = ["on", "off"]
DEFAULT_HEADERS = {
    "Authorization": f"Bearer {TOKEN}",
    "Content-Type": "application/json"
}

# Entity ID of the socket that the BF3 is plugged into
BF3_SOCKET_ENTITY_ID = "switch.tp_link_power_strip_b225_plug_1"


def set_state(new_state):
    if new_state not in VALID_STATES:
        raise Exception(f"{new_state} is not a valid state")

    url = f"{HA_API_ENDPOINT}/api/services/switch/turn_{new_state}"
    payload = {
        "entity_id": BF3_SOCKET_ENTITY_ID
    }
    r = requests.post(url, headers=DEFAULT_HEADERS, data=json.dumps(payload))

    if r.status_code != 200:
        raise Exception(f"Unexpected response: {r.status_code} {r.reason}")


def get_state():
    url = f"{HA_API_ENDPOINT}/api/states/{BF3_SOCKET_ENTITY_ID}"
    r = requests.get(url, headers=DEFAULT_HEADERS)

    if r.status_code != 200:
        raise Exception(f"Unexpected response: {r.status_code} {r.reason}")

    response = json.loads(r.content)
    print(response["state"])


def main():
    if len(sys.argv) < 2:
        get_state()
    else:
        set_state(sys.argv[1].lower())


if __name__ == "__main__":
    main()
