# rpi-config

This repo *originally* (starting in December 2023) contained config files, scripts, and documentation
that I used to manage the Raspberry Pi 4 that I had running as a home server, mostly to run Home Assistant
for home automation.

It's grown and morphed in the last couple of years and last week (in May 2025) I just completed migrating
the last service from that RPi (actually an RPi 5 which replaced the original RPi 4 when my needs outgrew
its 1 GB of RAM) to a Kubernetes cluster running on Talos Linux in 5 VMs on a NUC 11. Both RPis are still
running, but they're really just sitting around as little ARM Linux boxes for when I need that (and as 
additional Tailscale nodes on my home office network).
