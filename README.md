# rpi-config

This repo mostly contains config files, scripts, and documentation that I use to manage the Raspberry Pi 4 that I have running as a home server, mostly to run Home Assistant for home automation. 

## Add Mosquitto user

1. ssh into RPi
1. Open shell in Mosquitto Docker container: `docker exec -it $(docker ps -f name=mosquitto -q) "/bin/sh"`
1. Create new user: `mosquitto_passwd -b -c /tmp/mosquitto.passwd USER PASSWORD`
1. Verify the new password entry in `/tmp/mosquitto.passwd`, then copy it into `/mosquitto/config/password.txt`.
1. Restart Mosquitto container: `docker container restart mosquitto`