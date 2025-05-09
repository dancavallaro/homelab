#!/usr/bin/env bash

if [[ "$1" == "nuc" ]]; then
  wakeonlan -i 10.42.255.255 88:AE:DD:0E:7D:23
elif [[ "$1" == "nas" ]]; then
  wakeonlan -i 192.168.7.255 90:09:d0:77:4f:25
else
  echo "Usage: $0 {nuc|nas}"
  exit 1
fi
