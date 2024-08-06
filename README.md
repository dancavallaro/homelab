# rpi-config

This repo mostly contains config files, scripts, and documentation that I use to manage the Raspberry Pi 4 that I have running as a home server, mostly to run Home Assistant for home automation. 

## Migration notes

Here are some gotchas I ran into when migrating this server from my RPi4 to RPi5:

### flic DB

The button entries in the flic DB include the host's bluetooth hardware address, so
it wouldn't recognize the already-registered buttons until I updated the DB:

```shell
BT_ADDR=$(hciconfig hci0 | grep -Eo "([0-9A-F]{2}:){5}[0-9A-Z]{2}" | tr '[:upper:]' '[:lower:]')
sqlite3 flic.sqlite3 "update buttons set my_bdaddr='$BT_ADDR'"
```

### `Unsupported page size` error

The Home Assistant container was failing to start up at first on the RPi5, with these errors:

```
<jemalloc>: Unsupported system page size
Fatal Python error: _PyRuntimeState_Init: memory allocation failed
Python runtime state: unknown

[22:29:12] INFO: Home Assistant Core finish process exit code 1
[22:29:12] INFO: Home Assistant Core service shutdown
```

I found a few references online (e.g. [this](https://github.com/raspberrypi/bookworm-feedback/issues/107)
and [this](https://stackoverflow.com/questions/77674853/polars-jemalloc-error-unsupported-system-page-size))
that suggested this was due to the RPi5 having a default kernel with a page size of 
16 KB instead of 4 KB, which you can check by running this:

```shell
dan@rpi:~ $ getconf PAGE_SIZE
16384
```

Fix it by putting the following line in `/boot/firmware/config.txt` and rebooting:

```
kernel=kernel8.img
```
