#!/usr/bin/env python

import adafruit_dht
from board import D25

def c_to_f(temp):
  return 1.8 * temp + 32

dht = adafruit_dht.DHT22(D25)

print(c_to_f(dht.temperature))

dht.exit()
