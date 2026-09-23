#!/usr/bin/env bash
# Runs inside the privileged container started by ./run: static checks on the rendered
# files, then firewall and DHCP behaviour in network namespaces.
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq nftables netplan.io dnsmasq-base netcat-openbsd iproute2 python3 busybox >/dev/null

R=/rendered/protectli.lan
failures=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; failures=$((failures + 1)); }
check() { local label=$1; shift; if "$@" >/dev/null 2>&1; then pass "$label"; else fail "$label"; fi; }

echo "--- daemon.json"
check "protectli daemon.json is valid JSON" python3 -m json.tool "$R/daemon.json"
check "protectli daemon.json sets ip-forward-no-drop" grep -q '"ip-forward-no-drop": true' "$R/daemon.json"
check "Go template in loki labels survives Jinja" grep -qF 'container_name={{.Name}}' "$R/daemon.json"
check "the string \"false\" leaves the flag off" bash -c "! grep -q ip-forward-no-drop $R/daemon.false-string.json"
check "rpi daemon.json omits the flag" bash -c "! grep -q ip-forward-no-drop /rendered/rpi.lan/daemon.json"

echo "--- netplan"
mkdir -p /tmp/np/etc/netplan && install -m 600 "$R/netplan.yaml" /tmp/np/etc/netplan/99-dan.yaml
check "netplan generate" netplan generate --root-dir /tmp/np
N=/tmp/np/run/systemd/network
check "uplink address" grep -q 'Address=10.255.0.2/30' "$N/10-netplan-enp1s0.network"
check "uplink default gateway" grep -q 'Gateway=10.255.0.1' "$N/10-netplan-enp1s0.network"
check "uplink DNS" grep -q 'DNS=10.42.42.1' "$N/10-netplan-enp1s0.network"
check "guest VLAN id" grep -q 'Id=4' "$N/10-netplan-enp2s0.4.netdev"
check "guest VLAN address" grep -q 'Address=10.255.4.1/24' "$N/10-netplan-enp2s0.4.network"
check "data path address" grep -q 'Address=10.255.3.1/24' "$N/10-netplan-enp4s0.network"
check "no bridge" bash -c "! ls $N | grep -q br0"
for i in enp2s0 enp2s0.4 enp3s0 enp4s0; do
  check "$i ignores router advertisements" grep -q 'IPv6AcceptRA=no' "$N/10-netplan-$i.network"
done
check "no downstream gateway" bash -c "! grep -l Gateway= $N/10-netplan-enp[234]s0*.network"

echo "--- nftables"
check "nft syntax" nft -c -f "$R/nftables.conf"
check "ruleset file never flushes the ruleset" bash -c "! grep -q 'flush ruleset' $R/nftables.conf"
check "ExecStop drop-in never flushes the ruleset" bash -c "! grep -q '^ExecStop=.*flush' /role/files/nftables-override.conf"

echo "--- firewall matrix"
ns() { ip netns exec "$@"; }
for n in r up host guest dpu p0 ts; do
  ip netns add "$n"
  ns "$n" ip link set lo up
  ns "$n" sysctl -qw net.ipv4.conf.all.rp_filter=0 net.ipv4.conf.default.rp_filter=0
done
ns r sysctl -qw net.ipv4.ip_forward=1
wire() { ip link add "$1" netns r type veth peer name "$3" netns "$2"; ns r ip link set "$1" up; ns "$2" ip link set "$3" up; }
wire enp1s0 up up0
wire enp2s0 host h0
wire enp3s0 dpu d0
wire enp4s0 p0 p0
wire tailscale0 ts t0
ns r ip link add link enp2s0 name enp2s0.4 type vlan id 4
ns r ip link set enp2s0.4 up
ns host ip link add link h0 name h0.4 type vlan id 4
ns host ip link set h0.4 netns guest
ns guest ip link set h0.4 up

addr() { ns "$1" ip addr add "$2" dev "$3"; }
addr r 10.255.0.2/30 enp1s0; addr r 10.255.1.1/24 enp2s0; addr r 10.255.4.1/24 enp2s0.4
addr r 10.255.2.1/24 enp3s0; addr r 10.255.3.1/24 enp4s0; addr r 100.100.100.2/24 tailscale0
ns r ip route add default via 10.255.0.1
# "up" stands in for the MikroTik and everything behind it.
addr up 10.255.0.1/30 up0
for a in 10.42.42.1 10.42.42.5 10.42.42.10 10.42.42.12 172.16.42.2 1.1.1.1; do addr up "$a/32" lo; done
ns up ip route add 10.255.0.0/16 via 10.255.0.2
ns up ip route add 100.64.0.0/10 via 10.255.0.2
addr host 10.255.1.10/24 h0;    ns host ip route add default via 10.255.1.1
addr guest 10.255.4.20/24 h0.4; ns guest ip route add default via 10.255.4.1
addr dpu 10.255.2.10/24 d0; addr dpu 10.255.2.11/24 d0; ns dpu ip route add default via 10.255.2.1
addr p0 10.255.3.10/24 p0;      ns p0 ip route add default via 10.255.3.1
addr ts 100.100.100.1/24 t0;    ns ts ip route add default via 100.100.100.2

# Stand-in for Docker's and Tailscale's table: accepts everything, so any drop is ours.
ns r nft add table ip filter
ns r nft add chain ip filter FORWARD '{ type filter hook forward priority 0; policy accept; }'
ns r nft -f "$R/nftables.conf"
ns r nft -f "$R/nftables.conf"
check "loading twice leaves other tables alone" ns r nft list table ip filter
check "loading twice leaves one router table" test "$(ns r nft list tables | grep -c 'inet router')" = 1

listen() { local n=$1; shift; for p in "$@"; do ns "$n" nc -4 -lk "$p" >/dev/null 2>&1 & done; }
listen up 53 80 443 445
listen r 22
listen host 8006
listen guest 8080
listen dpu 22 443
listen p0 22
sleep 1

probe() { # probe allow|deny <ns> <src> <dst> <port>
  local want=$1 n=$2 src=$3 dst=$4 port=$5 got
  if ns "$n" nc -4 -z -w 1 -s "$src" "$dst" "$port" >/dev/null 2>&1; then got=allow; else got=deny; fi
  if [ "$got" = "$want" ]; then pass "$want $n $src -> $dst:$port"; else fail "$n $src -> $dst:$port: want $want, got $got"; fi
}
# Upstream into the segments
probe allow up 10.42.42.10 10.255.1.10 8006
probe allow up 10.42.42.10 10.255.2.11 22
probe allow up 10.42.42.10 10.255.2.10 443
probe deny  up 10.42.42.5  10.255.1.10 8006
probe deny  up 10.42.42.5  10.255.2.11 22
probe allow up 10.42.42.5  10.255.3.10 22
probe allow up 10.42.42.5  10.255.4.20 8080
# dpu-host; the first line is the boundary the design exists for
probe deny  host 10.255.1.10 10.255.2.11 22
probe deny  host 10.255.1.10 10.255.2.10 443
probe deny  host 10.255.1.10 10.255.3.10 22
probe deny  host 10.255.1.10 10.255.4.20 8080
probe allow host 10.255.1.10 10.42.42.1 53
probe deny  host 10.255.1.10 172.16.42.2 443
probe deny  host 10.255.1.10 10.42.42.12 445
probe allow host 10.255.1.10 1.1.1.1 443
# BF3 SoC
probe deny  dpu 10.255.2.11 10.255.1.10 8006
probe deny  dpu 10.255.2.11 10.255.4.20 8080
probe allow dpu 10.255.2.11 10.42.42.1 53
probe allow dpu 10.255.2.11 172.16.42.2 443
probe deny  dpu 10.255.2.11 172.16.42.2 80
probe deny  dpu 10.255.2.11 10.42.42.12 445
probe allow dpu 10.255.2.11 1.1.1.1 443
# BF3 BMC
probe deny  dpu 10.255.2.10 10.42.42.1 53
probe deny  dpu 10.255.2.10 1.1.1.1 443
# Data path
probe deny  p0 10.255.3.10 10.255.2.11 22
probe deny  p0 10.255.3.10 172.16.42.2 443
probe allow p0 10.255.3.10 1.1.1.1 443
# Guests
probe deny  guest 10.255.4.20 10.255.1.10 8006
probe deny  guest 10.255.4.20 10.255.2.11 22
probe deny  guest 10.255.4.20 10.42.42.12 445
probe allow guest 10.255.4.20 10.42.42.1 53
probe allow guest 10.255.4.20 1.1.1.1 443
# Tailscale exit node: anything out the uplink, nothing into the segments
probe allow ts 100.100.100.1 1.1.1.1 443
probe allow ts 100.100.100.1 10.42.42.12 445
probe deny  ts 100.100.100.1 10.255.2.11 22
# The Protectli itself
probe deny  host 10.255.1.10 10.255.1.1 22
probe allow up 10.42.42.5 10.255.0.2 22
probe allow r 10.255.0.2 172.16.42.2 80

echo "--- docker"
ip netns add ctr
ns ctr ip link set lo up
ip link add docker0 netns r type veth peer name c0 netns ctr
ns r ip link set docker0 up; ns ctr ip link set c0 up
addr r 172.17.0.1/16 docker0; addr ctr 172.17.0.2/16 c0
ns ctr ip route add default via 172.17.0.1
ns up ip route add 172.17.0.0/16 via 10.255.0.2
# Stand-in for a published port: Docker DNATs host port 8081 to the container.
ns r nft add table ip dockernat
ns r nft add chain ip dockernat prerouting '{ type nat hook prerouting priority dstnat; }'
ns r nft add rule ip dockernat prerouting fib daddr type local tcp dport 8081 dnat to 172.17.0.2:80
listen ctr 80
sleep 1
probe allow up 10.42.42.5 10.255.0.2 8081
probe deny  host 10.255.1.10 10.255.1.1 8081
probe allow ctr 172.17.0.2 1.1.1.1 443
probe deny  ctr 172.17.0.2 10.255.2.11 22

echo "--- spoofed SoC source"
ns up nft add table inet spy
ns up nft add chain inet spy input '{ type filter hook input priority 0; }'
ns up nft add rule inet spy input ip saddr 10.255.2.11 tcp dport 443 counter
addr host 10.255.2.11/32 h0
ns host nc -4 -z -w 1 -s 10.255.2.11 172.16.42.2 443 >/dev/null 2>&1
spoofed=$(ns up nft list chain inet spy input | grep -oE 'packets [0-9]+' | awk '{print $2}')
ns host ip addr del 10.255.2.11/32 dev h0
check "dpu-host cannot pass as the SoC (spoofed SYNs reaching upstream: $spoofed)" test "$spoofed" = 0

echo "--- nftables.service stop"
stop_cmd=$(sed -n 's/^ExecStop=\(\/.*\)/\1/p' /role/files/nftables-override.conf)
ns r $stop_cmd
check "ExecStop succeeds when the table is already gone" ns r $stop_cmd
check "ExecStop removes the router table" bash -c "! ip netns exec r nft list table inet router"
check "ExecStop leaves other tables alone" ns r nft list table ip filter
ns r nft -f "$R/nftables.conf"

echo "--- dnsmasq"
check "dnsmasq syntax" dnsmasq --test --conf-file="$R/dnsmasq.conf"
check "port=0 is a line of dnsmasq.conf (Debian's resolvconf hook greps for it)" grep -q '^port=0' "$R/dnsmasq.conf"
check "dnsmasq does not serve the uplink" bash -c "! grep -q '^interface=enp1s0' $R/dnsmasq.conf"

ns r dnsmasq --conf-file="$R/dnsmasq.conf" --user=root --group=root \
  --pid-file=/tmp/dnsmasq.pid --dhcp-leasefile=/tmp/dnsmasq.leases --log-facility=/tmp/dnsmasq.log
sleep 1
# dnsmasq pings a pool address for ~3 s before offering it, so clients must wait longer than that.
lease() { # lease <ns> <ifname> <mac>: prints the offered address, or nothing
  ns "$1" ip link set "$2" address "$3"
  ns "$1" busybox udhcpc -i "$2" -n -q -f -t 3 -T 3 -s /bin/true 2>&1 | sed -n 's/.*lease of \([0-9.]*\) obtained.*/\1/p'
}
expect_lease() { # expect_lease <address or ""> <ns> <ifname> <mac>
  local got; got=$(lease "$2" "$3" "$4")
  if [ "$got" = "$1" ]; then pass "DHCP $4 on $2 -> ${1:-no lease}"; else fail "DHCP $4 on $2: want '${1}', got '${got}'"; fi
}
expect_lease 10.255.1.10 host h0 84:47:09:92:3e:97
expect_lease 10.255.2.10 dpu d0 a0:88:c2:4d:4d:6b
expect_lease 10.255.2.11 dpu d0 a0:88:c2:4d:4d:6a
expect_lease ""          dpu d0 02:00:00:00:00:01
expect_lease 10.255.4.20 guest h0.4 bc:24:11:71:96:44
expect_lease 10.255.3.10 p0 p0 02:90:ef:4f:75:ed

printf '#!/bin/sh\n[ "$1" = bound ] && echo "router=[$router]"\nexit 0\n' > /tmp/udhcpc-router.sh
chmod +x /tmp/udhcpc-router.sh
expect_router() { # expect_router <router or ""> <ns> <ifname> <mac>
  local got
  ns "$2" ip link set "$3" address "$4"
  got=$(ns "$2" busybox udhcpc -i "$3" -n -q -f -t 3 -T 3 -s /tmp/udhcpc-router.sh 2>/dev/null | sed -n 's/^router=\[\(.*\)\]$/\1/p')
  if [ "$got" = "$1" ]; then pass "DHCP $4 router -> ${1:-none}"; else fail "DHCP $4 router: want '${1}', got '${got}'"; fi
}
# The DPU's data-path SF must not get a default route; its egress belongs on oob_net0.
expect_router ""          p0 p0 02:90:ef:4f:75:ed
expect_router 10.255.1.1  host h0 84:47:09:92:3e:97
pool=$(lease guest h0.4 02:00:00:00:00:02)
case "$pool" in 10.255.4.1[0-9][0-9]) pass "DHCP unknown guest -> pool ($pool)";; *) fail "DHCP unknown guest: want pool address, got '$pool'";; esac

echo
if [ "$failures" -eq 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed"; exit 1; fi
