# 2025-09-29 11:35:23 by RouterOS 7.14.1
# software id = GNVB-4V9V
#
# model = RB5009UG+S+
# serial number = HFD095R4B6E
/interface bridge
add admin-mac=78:9A:18:BD:BF:20 auto-mac=no comment=defconf name=bridge port-cost-mode=short
add comment="bridges some ports to \"WAN\" (dtcnet/home LAN) on ether1" name=dtcnet_bridge
add comment="Private IoT network for ESP32 devices" name=iotnet_bridge
/interface ethernet
set [ find default-name=ether1 ] comment="NUC (2.5GbE)"
set [ find default-name=ether2 ] comment="Laptop docking station"
set [ find default-name=ether3 ] comment="PoE switch to Ubiquiti APs"
set [ find default-name=ether4 ] comment=Protectli
set [ find default-name=ether5 ] comment="eero (uplink to dtcnet LAN)"
set [ find default-name=ether6 ] comment="RPi4 (bastion.local)"
set [ find default-name=ether7 ] comment="dtcnet Netgear switch"
set [ find default-name=sfp-sfpplus1 ] comment="Synology NAS"
/interface vlan
add comment="WiFi SSID for labnet" interface=ether3 name=vlan10 vlan-id=10
add comment="WiFi SSID for IoT network" interface=ether3 name=vlan20 vlan-id=20
add comment="NUC -> dtcnet bridge" interface=ether1 name=vlan192 vlan-id=192
/interface list
add comment=defconf name=WAN
add comment=defconf name=LAN
/interface wireless security-profiles
set [ find default=yes ] supplicant-identity=MikroTik
/ip pool
add comment="Address pool for office network" name=dhcp ranges=10.42.42.2-10.42.42.254
add comment="Address pool for private IoT network" name=iotnet ranges=192.168.20.2-192.168.20.254
/ip dhcp-server
add address-pool=dhcp interface=bridge lease-time=10m name=defconf
add address-pool=iotnet comment="DHCP for private IoT network" interface=iotnet_bridge name=iotnet
/interface bridge port
add bridge=bridge comment=defconf interface=ether2 internal-path-cost=10 path-cost=10
add bridge=bridge interface=ether6 internal-path-cost=10 path-cost=10
add bridge=bridge comment="Synology NAS" interface=sfp-sfpplus1 internal-path-cost=10 path-cost=10
add bridge=bridge interface=ether4
add bridge=bridge interface=ether1
add bridge=dtcnet_bridge interface=ether5
add bridge=dtcnet_bridge comment="Bridges dpu-host to dtcnet" interface=vlan192
add bridge=dtcnet_bridge interface=ether3
add bridge=dtcnet_bridge interface=ether7
add bridge=bridge comment="Bridges WiFi APs to office network" interface=vlan10
add bridge=iotnet_bridge interface=vlan20
add bridge=bridge interface=ether8
/ip firewall connection tracking
set udp-timeout=10s
/ip neighbor discovery-settings
set discover-interface-list=LAN
/interface list member
add comment=defconf interface=bridge list=LAN
add comment=defconf interface=dtcnet_bridge list=WAN
/ip address
add address=10.42.42.1/16 comment=defconf interface=bridge network=10.42.0.0
add address=192.168.20.1/24 interface=iotnet_bridge network=192.168.20.0
/ip dhcp-client
add interface=dtcnet_bridge
/ip dhcp-server lease
add address=10.42.42.10 client-id=work-laptop comment="Work MBP" mac-address=90:8D:6E:35:11:38 server=defconf
add address=10.42.42.16 comment=Protectli mac-address=00:E0:67:30:D6:DE
add address=10.42.42.11 client-id=personal-laptop comment="Personal MBP" mac-address=90:8D:6E:35:11:38 server=defconf
add address=10.42.42.42 client-id=1:e4:5f:1:ef:d7:10 comment="bastion RPi" mac-address=E4:5F:01:EF:D7:10 server=defconf
add address=10.42.42.2 comment="NUC br0" mac-address=92:B9:36:6D:7F:97 server=defconf
add address=10.42.42.12 client-id=1:90:9:d0:66:1f:3b comment="Synology NAS" mac-address=90:09:D0:66:1F:3B server=defconf
add address=10.42.42.5 client-id=1:d8:3a:dd:c8:db:3c comment="RPi 5" mac-address=D8:3A:DD:C8:DB:3C server=defconf
/ip dhcp-server network
add address=10.42.0.0/16 comment="Office network" dns-server=10.42.42.1 gateway=10.42.42.1 netmask=16
add address=192.168.20.0/24 comment="Private IoT network" dns-server=172.16.42.53 gateway=192.168.20.1
/ip dns
set allow-remote-requests=yes servers=8.8.8.8,8.8.4.4
/ip dns static
add address=10.42.42.1 comment=defconf name=router.lan
add address=10.42.42.2 name=dpu-host
add address=192.168.6.40 name=dtcnet-netgear
add address=10.42.42.16 name=protectli
add address=10.42.42.12 name=nas
add address=10.42.42.42 name=bastion
add address=10.42.42.5 name=rpi
/ip firewall filter
add action=accept chain=input comment="defconf: accept established,related,untracked" connection-state=established,related,untracked
add action=drop chain=input comment="defconf: drop invalid" connection-state=invalid log=yes log-prefix="[invalidinput]"
add action=accept chain=input comment="defconf: accept ICMP" protocol=icmp
add action=accept chain=input comment="defconf: accept to local loopback (for CAPsMAN)" dst-address=127.0.0.1
add action=accept chain=input comment="Allow SNMP from RPi for monitoring" dst-port=161 protocol=udp src-address=192.168.5.238
add action=drop chain=input comment="defconf: drop all not coming from LAN" in-interface-list=!LAN
add action=accept chain=forward comment="Accept traffic from RPi towards k8s LB IPs" dst-address=172.16.42.0/24 src-address=192.168.5.100
add action=accept chain=forward comment="defconf: accept in ipsec policy" ipsec-policy=in,ipsec
add action=accept chain=forward comment="defconf: accept out ipsec policy" ipsec-policy=out,ipsec
add action=fasttrack-connection chain=forward comment="defconf: fasttrack" connection-state=established,related hw-offload=yes
add action=accept chain=forward comment="defconf: accept established,related, untracked" connection-state=established,related,untracked
add action=drop chain=forward comment="defconf: drop invalid" connection-state=invalid log=yes log-prefix="[invalid]"
add action=drop chain=forward comment="defconf: drop all from WAN not DSTNATed" connection-nat-state=!dstnat connection-state=new in-interface-list=WAN
/ip firewall nat
add action=masquerade chain=srcnat comment="defconf: masquerade" ipsec-policy=out,none out-interface-list=WAN
/ip firewall raw
add action=notrack chain=prerouting comment="Disable conntrack for traffic between labnet and k8s subnet" dst-address=10.96.0.0/12 src-address=10.42.0.0/16
add action=notrack chain=prerouting comment="Disable conntrack for traffic between labnet and MetalLB subnet" dst-address=172.16.42.0/24 src-address=10.42.0.0/16
add action=notrack chain=prerouting comment="Disable conntrack for traffic between labnet and k8s VM subnet" dst-address=192.168.42.0/24 src-address=10.42.0.0/16
/ip route
add comment="Route for MetalLB" disabled=no distance=1 dst-address=172.16.42.0/24 gateway=10.42.42.100 pref-src="" routing-table=main suppress-hw-offload=no
add comment="Route for k8s cluster" disabled=no distance=1 dst-address=10.96.0.0/12 gateway=10.42.42.100 pref-src="" routing-table=main suppress-hw-offload=no
add comment="Route for k8s VM private subnet" disabled=no distance=1 dst-address=192.168.42.0/24 gateway=10.42.42.100 pref-src="" routing-table=main suppress-hw-offload=no
/ipv6 firewall address-list
add address=::/128 comment="defconf: unspecified address" list=bad_ipv6
add address=::1/128 comment="defconf: lo" list=bad_ipv6
add address=fec0::/10 comment="defconf: site-local" list=bad_ipv6
add address=::ffff:0.0.0.0/96 comment="defconf: ipv4-mapped" list=bad_ipv6
add address=::/96 comment="defconf: ipv4 compat" list=bad_ipv6
add address=100::/64 comment="defconf: discard only " list=bad_ipv6
add address=2001:db8::/32 comment="defconf: documentation" list=bad_ipv6
add address=2001:10::/28 comment="defconf: ORCHID" list=bad_ipv6
add address=3ffe::/16 comment="defconf: 6bone" list=bad_ipv6
/ipv6 firewall filter
add action=accept chain=input comment="defconf: accept established,related,untracked" connection-state=established,related,untracked
add action=drop chain=input comment="defconf: drop invalid" connection-state=invalid
add action=accept chain=input comment="defconf: accept ICMPv6" protocol=icmpv6
add action=accept chain=input comment="defconf: accept UDP traceroute" port=33434-33534 protocol=udp
add action=accept chain=input comment="defconf: accept DHCPv6-Client prefix delegation." dst-port=546 protocol=udp src-address=fe80::/10
add action=accept chain=input comment="defconf: accept IKE" dst-port=500,4500 protocol=udp
add action=accept chain=input comment="defconf: accept ipsec AH" protocol=ipsec-ah
add action=accept chain=input comment="defconf: accept ipsec ESP" protocol=ipsec-esp
add action=accept chain=input comment="defconf: accept all that matches ipsec policy" ipsec-policy=in,ipsec
add action=drop chain=input comment="defconf: drop everything else not coming from LAN" in-interface-list=!LAN
add action=accept chain=forward comment="defconf: accept established,related,untracked" connection-state=established,related,untracked
add action=drop chain=forward comment="defconf: drop invalid" connection-state=invalid
add action=drop chain=forward comment="defconf: drop packets with bad src ipv6" src-address-list=bad_ipv6
add action=drop chain=forward comment="defconf: drop packets with bad dst ipv6" dst-address-list=bad_ipv6
add action=drop chain=forward comment="defconf: rfc4890 drop hop-limit=1" hop-limit=equal:1 protocol=icmpv6
add action=accept chain=forward comment="defconf: accept ICMPv6" protocol=icmpv6
add action=accept chain=forward comment="defconf: accept HIP" protocol=139
add action=accept chain=forward comment="defconf: accept IKE" dst-port=500,4500 protocol=udp
add action=accept chain=forward comment="defconf: accept ipsec AH" protocol=ipsec-ah
add action=accept chain=forward comment="defconf: accept ipsec ESP" protocol=ipsec-esp
add action=accept chain=forward comment="defconf: accept all that matches ipsec policy" ipsec-policy=in,ipsec
add action=drop chain=forward comment="defconf: drop everything else not coming from LAN" in-interface-list=!LAN
/snmp
set enabled=yes
/system clock
set time-zone-name=America/New_York
/system note
set show-at-login=no
/tool mac-server
set allowed-interface-list=LAN
/tool mac-server mac-winbox
set allowed-interface-list=LAN
