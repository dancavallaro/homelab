import http.server
import json
import logging
import os
import random
import threading
import time
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

API_URL = "https://api.turnip.exchange/islands/"
PUSHOVER_URL = "https://api.pushover.net/1/messages.json"
SNOOZE_URL = "https://turnips.o.cavnet.cloud/snooze"
# Sentinel returned when no real islands match the query.
NO_ISLANDS_CODE = "00000000"
USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:151.0) "
    "Gecko/20100101 Firefox/151.0"
)

BASE_INTERVAL = 300
JITTER_MAX = 60
TZ = ZoneInfo("America/New_York")


THRESHOLD = int(os.getenv("THRESHOLD", "200"))
PUSHOVER_TOKEN = os.environ["PUSHOVER_TOKEN"]
PUSHOVER_USER_KEY = os.environ["PUSHOVER_USER_KEY"]

# Ephemeral; resets on pod restart.
snooze_until = 0.0


def next_sunday_noon():
    now = datetime.now(TZ)
    # weekday(): Mon=0..Sun=6
    days_ahead = (6 - now.weekday()) % 7
    candidate = now.replace(
        hour=12, minute=0, second=0, microsecond=0
    ) + timedelta(days=days_ahead)
    if candidate <= now:
        candidate += timedelta(days=7)
    return candidate.timestamp()


def fmt_local(ts):
    return datetime.fromtimestamp(ts, TZ).strftime("%a %b %d %I:%M %p %Z")


def fetch_islands():
    body = json.dumps({"islander": "neither", "category": "turnips"}).encode()
    req = urllib.request.Request(
        API_URL,
        data=body,
        headers={
            "User-Agent": USER_AGENT,
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp).get("islands", [])


def notify(count, max_price):
    plural = "s" if count != 1 else ""
    data = urllib.parse.urlencode({
        "token": PUSHOVER_TOKEN,
        "user": PUSHOVER_USER_KEY,
        "title": f"Turnip prices: max {max_price} bells",
        "message": f"{count} island{plural} with turnipPrice >= {THRESHOLD}",
        "url": SNOOZE_URL,
        "url_title": "Snooze until Sunday noon",
    }).encode()

    if PUSHOVER_TOKEN == "skip":
        logging.info("skipping Pushover notification; would notify with payload: %s", data)
    else:
        req = urllib.request.Request(PUSHOVER_URL, data=data)
        with urllib.request.urlopen(req, timeout=30) as resp:
            resp.read()


class SnoozeHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global snooze_until
        if self.path != "/snooze":
            self.send_response(404)
            self.end_headers()
            return
        snooze_until = next_sunday_noon()
        until_str = fmt_local(snooze_until)
        body = f"Snoozed until {until_str}\n".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        logging.info("snooze: until=%s", until_str)

    def log_message(self, format, *args):
        pass


def start_http_server():
    server = http.server.ThreadingHTTPServer(("0.0.0.0", 8080), SnoozeHandler)
    threading.Thread(target=server.serve_forever, daemon=True).start()


def main():
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    logging.info(
        "starting: threshold=%d interval=%ds+0-%ds jitter",
        THRESHOLD, BASE_INTERVAL, JITTER_MAX,
    )
    start_http_server()
    last_set = set()
    while True:
        try:
            islands = [
                i for i in fetch_islands()
                if i.get("turnipCode") != NO_ISLANDS_CODE
                # Patreon-promoted entries are paid/scammy treasure-island
                # listings, not real sellers.
                and not i.get("patreon")
            ]
            above = [
                i for i in islands
                if i.get("messageID")
                and (i.get("turnipPrice") or 0) >= THRESHOLD
            ]
            current_set = {i["messageID"] for i in above}
            if current_set and current_set != last_set:
                if time.time() < snooze_until:
                    logging.info(
                        "snoozed until %s; skipping alert for %d islands",
                        fmt_local(snooze_until), len(above),
                    )
                else:
                    max_price = max(i["turnipPrice"] for i in above)
                    logging.info("alert: %d islands, max %d", len(above), max_price)
                    notify(len(above), max_price)
            last_set = current_set
        except Exception as e:
            logging.exception("error: %s", e)
        sleep_for = BASE_INTERVAL + random.uniform(0, JITTER_MAX)
        logging.info("sleeping %.1fs (%d active)", sleep_for, len(last_set))
        time.sleep(sleep_for)


if __name__ == "__main__":
    main()
