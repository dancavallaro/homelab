#!/usr/local/rpi-config/.venv/bin/python
import adafruit_dht
from board import D25
from retry import retry


def c_to_f(temp):
  return 1.8 * temp + 32

# For unknown (to me) reasons this sometimes throws "RuntimeError: Checksum did not
# validate. Try again.", so just automatically retry a couple times.
@retry(RuntimeError, tries=3, delay=2)
def get_temp(dht):
  return dht.temperature

def print_temp_in_degrees():
  dht = adafruit_dht.DHT22(D25)

  try:
    temp_f = c_to_f(get_temp(dht))
    print(temp_f)
  finally:
    dht.exit()


if __name__ == '__main__':
  import logging
  logging.basicConfig()
  print_temp_in_degrees()
