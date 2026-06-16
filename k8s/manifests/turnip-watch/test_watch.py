import os
import http.server
import json
import threading
import urllib.error
import urllib.request

# watch.py reads these at import time; set them before importing.
os.environ.setdefault("PUSHOVER_TOKEN", "skip")
os.environ.setdefault("PUSHOVER_USER_KEY", "test")

import watch  # noqa: E402


def test_build_snapshot_maps_name_and_price_in_order():
    islands = [
        {"name": "Alpha", "turnipPrice": 600, "messageID": "a"},
        {"name": "Beta", "turnipPrice": 555, "messageID": "b"},
    ]
    snap = watch.build_snapshot(islands, now=1000.0)
    assert snap["last_checked"] == 1000.0
    assert snap["islands"] == [
        {"name": "Alpha", "turnipPrice": 600},
        {"name": "Beta", "turnipPrice": 555},
    ]


def test_build_snapshot_empty_list():
    snap = watch.build_snapshot([], now=42.0)
    assert snap == {"last_checked": 42.0, "islands": []}


def test_build_snapshot_missing_name_becomes_none():
    snap = watch.build_snapshot([{"turnipPrice": 700}], now=1.0)
    assert snap["islands"] == [{"name": None, "turnipPrice": 700}]


def test_build_state_not_snoozed_no_poll_yet():
    watch.latest = {"last_checked": None, "islands": []}
    watch.snooze_until = 0.0
    state = watch.build_state(now=2000.0)
    assert state == {
        "snoozed": False,
        "snooze_until": None,
        "last_checked": None,
        "islands": [],
    }


def test_build_state_snoozed_in_future():
    watch.latest = {
        "last_checked": 1500.0,
        "islands": [{"name": "Alpha", "turnipPrice": 612}],
    }
    watch.snooze_until = 9000.0
    state = watch.build_state(now=2000.0)
    assert state["snoozed"] is True
    assert state["snooze_until"] == watch.fmt_local(9000.0)
    assert state["last_checked"] == watch.fmt_local(1500.0)
    assert state["islands"] == [{"name": "Alpha", "turnipPrice": 612}]


def test_build_state_snooze_in_past_is_not_snoozed():
    watch.latest = {"last_checked": 1500.0, "islands": []}
    watch.snooze_until = 1000.0  # before now
    state = watch.build_state(now=2000.0)
    assert state["snoozed"] is False
    assert state["snooze_until"] is None
    assert state["last_checked"] == watch.fmt_local(1500.0)


def _serve():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), watch.SnoozeHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def test_state_endpoint_serves_json():
    watch.latest = {
        "last_checked": 1500.0,
        "islands": [{"name": "Alpha", "turnipPrice": 600}],
    }
    watch.snooze_until = 0.0
    server = _serve()
    port = server.server_address[1]
    try:
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/state", timeout=5
        ) as resp:
            assert resp.status == 200
            assert resp.headers["Content-Type"] == "application/json"
            data = json.load(resp)
        assert data["snoozed"] is False
        assert data["islands"] == [{"name": "Alpha", "turnipPrice": 600}]
        assert data["last_checked"] == watch.fmt_local(1500.0)
    finally:
        server.shutdown()
        server.server_close()


def test_unknown_path_returns_404():
    server = _serve()
    port = server.server_address[1]
    try:
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{port}/nope", timeout=5)
            assert False, "expected HTTP 404"
        except urllib.error.HTTPError as e:
            assert e.code == 404
    finally:
        server.shutdown()
        server.server_close()
