# rpi-config

This repo mostly contains config files, scripts, and documentation that I use to manage the Raspberry Pi 4 that I have running as a home server, mostly to run Home Assistant for home automation. 

## Add Mosquitto user

1. ssh into RPi
1. Open shell in Mosquitto Docker container: `docker exec -it $(docker ps -f name=mosquitto -q) "/bin/sh"`
1. Create new user: `mosquitto_passwd -b -c /mosquitto/config/password.txt USER PASSWORD`
