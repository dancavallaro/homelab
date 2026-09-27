## Set up host

### Networking config

`ansible/roles/talos_host` manages the host's netplan: `enp89s0` for the host's own labnet address,
`br11` for the cluster VLAN (VLAN 11), and `br192` for the homenet (VLAN 192), which every
worker's `enp9s0` joins. The host has no address on either VLAN bridge. See `docs/network.md`.

```shell
cd ansible && ansible-playbook -i inventory.ini bootstrap.yaml --limit talos-host.lan --tags talos_host
```

### Bluetooth

Create `/etc/modprobe.d/blacklist-bluetooth.conf` to blacklist the Bluetooth-related
kernel modules from being loaded by the host:

```
blacklist bluetooth
blacklist btrtl
blacklist btmtk
blacklist btintel
blacklist btbcm
blacklist bnep
blacklist btusb
```

Create `/etc/modprobe.d/bluetooth-vfio.conf` to assign the Bluetooth PCI device to the
vfio-pci driver:

```
alias pci:v00008086d0000A0F0sv00008086sd00000074bc02sc80i00 vfio-pci
options vfio-pci ids=8086:a0f0
```

Then reboot the host.

## Provision VMs and bootstrap cluster

The VMs attach to `br11`, the cluster VLAN, which has no DHCP. Each VM gets its maintenance-mode
address from an `ip=` kernel argument, and its permanent address from its `node-*.patch.yaml`.

Constants:

```shell
IMAGE_PATH=/usr/local/images/metal-amd64_v1.9.2.iso
VM_BRIDGE=br11
BOOTSTRAP_IP=10.11.0.10
GATEWAY=10.11.0.1
```

### CP node

#### Create VM

```shell
$ virt-install --name talos-prod-cp1 \
     --ram 6144 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 \
     --location "$IMAGE_PATH",kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args="console=ttyS0 talos.platform=metal slab_nomerge pti=on ip=$BOOTSTRAP_IP::$GATEWAY:255.255.255.0::enp1s0:off" --noautoconsole \
     --network bridge="$VM_BRIDGE",mac=02:C0:77:B4:28:80
$ virsh autostart talos-prod-cp1
```

#### Prepare config

```shell
# The secrets bundle is age-encrypted in talos-prod-secrets.yaml.age; the passphrase is in the password manager.
# The v1.9 contract matches how the running cluster was generated.
$ age -d talos-prod-secrets.yaml.age > /tmp/secrets.yaml
$ talosctl gen config talos-prod https://k8s.cavnet.cloud:6443 --with-secrets /tmp/secrets.yaml \
    --talos-version v1.9 --kubernetes-version <current> --with-docs=false --with-examples=false
$ rm /tmp/secrets.yaml
$ talosctl mc patch controlplane.yaml --patch @patches/common.patch.yaml --patch @patches/cp.patch.yaml \
    --patch @patches/node-cp1.patch.yaml --output cp.final.yaml
$ talosctl config merge ./talosconfig
$ talosctl config endpoint k8s.cavnet.cloud
```

#### Bootstrap Talos and k8s

```shell
$ talosctl apply-config --insecure -n $BOOTSTRAP_IP --file cp.final.yaml
$ talosctl bootstrap -n $BOOTSTRAP_IP
$ talosctl kubeconfig -n $BOOTSTRAP_IP --force-context-name talos-prod
```

#### Install Cilium

```shell
$ kubectl apply -k k8s/talos/prod/cilium/ --server-side --force-conflicts # Install CRDs before Cilium itself
$ helm repo add cilium https://helm.cilium.io/
$ helm repo update
$ helm upgrade --install cilium cilium/cilium --version 1.20.1 --namespace kube-system --values=k8s/talos/prod/cilium/values.yaml
```

### Worker nodes

#### Create VMs

```shell
$ virt-install --name talos-prod-worker1 \
     --ram 4096 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=50,format=qcow2 --disk size=100,format=qcow2 \
     --location "$IMAGE_PATH",kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args="console=ttyS0 talos.platform=metal slab_nomerge pti=on ip=10.11.0.100::$GATEWAY:255.255.255.0::enp1s0:off" --noautoconsole \
     --network bridge="$VM_BRIDGE",mac=02:52:A7:0B:1D:89
$ virsh autostart talos-prod-worker1
# Create worker2 and pass through the TP-Link BT USB device.
# xpath.delete strips the resolved USB bus/device address that virt-install bakes
# into the hostdev, so libvirt re-matches by vendor/product on every boot
# (USB device numbers are not stable across host reboots).
$ virt-install --name talos-prod-worker2 \
     --ram 6144 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=50,format=qcow2 --disk size=100,format=qcow2 \
     --location "$IMAGE_PATH",kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args="console=ttyS0 talos.platform=metal slab_nomerge pti=on ip=10.11.0.101::$GATEWAY:255.255.255.0::enp1s0:off" --noautoconsole \
     --network bridge="$VM_BRIDGE",mac=DE:6F:9F:0D:15:96 \
     --hostdev 0x2357:0x0604 \
     --xml xpath.delete=./devices/hostdev/source/address
$ virsh autostart talos-prod-worker2
# Create worker3, pass through the attached ESP32's USB serial device
$ virt-install --name talos-prod-worker3 \
     --ram 6144 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=50,format=qcow2 --disk size=100,format=qcow2 \
     --location "$IMAGE_PATH",kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args="console=ttyS0 talos.platform=metal slab_nomerge pti=on ip=10.11.0.102::$GATEWAY:255.255.255.0::enp1s0:off" --noautoconsole \
     --network bridge="$VM_BRIDGE",mac=12:62:54:B1:2D:B0 \
     --hostdev 0x0403:0x6001 \
     --xml xpath.delete=./devices/hostdev/source/address
$ virsh autostart talos-prod-worker3
```

Verify the persistent config matches USB hostdevs by vendor/product only (no
`<address bus=... device=.../>` inside `<source>`):

```shell
$ virsh dumpxml --inactive talos-prod-worker2 | grep -A8 '<hostdev'
```

Note: `virsh dumpxml` on a *running* domain will still show a resolved
`<address>` — that's live state only and expected.

#### Attach the homenet NIC

Every worker gets a second NIC on `br192` at PCI bus 9, so Talos names it `enp9s0` on all of
them and one Multus config works on any node. The MACs share the prefix `02:d7:c0:00:0b:`,
which `worker-common.patch.yaml` selects. Give each VM its own MAC, then power-cycle it
(a guest reboot does not pick up `--config` changes):

```shell
$ printf '%s\n' "<interface type='bridge'>" "  <mac address='02:d7:c0:00:0b:01'/>" \
    "  <source bridge='br192'/>" "  <model type='virtio'/>" \
    "  <address type='pci' domain='0x0000' bus='0x09' slot='0x00' function='0x0'/>" \
    "</interface>" > /tmp/home-nic.xml
$ virsh -c qemu:///system attach-device talos-prod-worker1 /tmp/home-nic.xml --config
```

#### Prepare config

```shell
$ talosctl mc patch worker.yaml \
    --patch @patches/common.patch.yaml \
    --patch @patches/worker-common.patch.yaml \
    --patch @patches/node-worker1.patch.yaml \
    --output worker1.final.yaml
$ talosctl mc patch worker.yaml \
    --patch @patches/common.patch.yaml \
    --patch @patches/worker-common.patch.yaml \
    --patch @patches/worker-bluetooth.patch.yaml \
    --patch @patches/node-worker2.patch.yaml \
    --output worker2.final.yaml
$ talosctl mc patch worker.yaml \
    --patch @patches/common.patch.yaml \
    --patch @patches/worker-common.patch.yaml \
    --patch @patches/worker-esp32.patch.yaml \
    --patch @patches/node-worker3.patch.yaml \
    --output worker3.final.yaml
```

#### Apply config and join nodes to cluster

```shell
$ talosctl apply-config --insecure -n 10.11.0.100 --file worker1.final.yaml
$ talosctl apply-config --insecure -n 10.11.0.101 --file worker2.final.yaml
$ talosctl apply-config --insecure -n 10.11.0.102 --file worker3.final.yaml
```

## Final manual bootstrapping

### Finish setting up Cilium

Configure LB pool and gateways:

```shell
$ kubectl apply -f talos/prod/cilium/resources.yaml
```

### Set up ArgoCD

```shell
$ kubectl create namespace argocd
$ kubectl apply -k k8s/talos/prod/argocd --server-side --force-conflicts
```

### Set up Cloudflare tunnel

```shell
$ cloudflared tunnel create talos-prod-tunnel
$ cloudflared tunnel route dns talos-prod-tunnel '*.cavnet.io'
$ kubectl -n internet create secret generic cloudflare-tunnel-creds \
    --from-file=credentials.json=/Users/dan/.cloudflared/cd7bbf2e-5242-4d0b-be03-42ed10007196.json
```


### Install infra apps

```shell
$ kubectl apply -f infra/dns-gateway.yaml
$ kubectl apply -f infra/cert-manager.yaml
$ kubectl apply -f infra/metrics-server.yaml
$ kubectl apply -f infra/local-storage.yaml
$ kubectl apply -f infra/cloudflare-tunnel.yaml
$ kubectl apply -f infra/cluster-archiver.yaml
$ kubectl apply -f infra/oidc-provider.yaml
$ kubectl apply -f infra/pod-identity-webhook.yaml
$ kubectl apply -f infra/letsencrypt.yaml

# Restart cert-manager -- pod-identity-webhook injects web-identity AWS credentials, so
# cert-manager can talk to Route53 and issue certs.
$ kubectl -n cert-manager rollout restart deployment cert-manager
```

### Install apps

```shell
$ kubectl apply -f apps/hass-proxy.yaml
$ kubectl apply -f apps/unifi.yaml
```

### Install top-level apps

```shell
$ kubectl apply -f app-roots/all-apps.yaml
$ kubectl apply -f app-roots/all-infra.yaml
```
