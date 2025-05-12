## Set up host

### Networking config

In `/etc/netplan/50-cloud-init.yaml`:

```yaml
network:
    ethernets:
        enp89s0:
            dhcp4: false
    bridges:
        br0:
            dhcp4: true
            macaddress: "92:B9:36:6D:7F:97"
            interfaces:
              - enp89s0
            routes:
              - to: 172.16.42.0/24
                via: 10.42.42.100
              - to: 10.96.0.0/12
                via: 10.42.42.100
    version: 2
```

Then `sudo netplan apply` (will kill SSH session)

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

Define VM network in `talos-prod-net.xml`:

```xml
<network>
  <name>talos-prod-net</name>
  <forward mode="nat">
    <nat>
      <port start="1024" end="65535"/>
    </nat>
  </forward>
  <bridge name="virbr4" />
  <ip address="192.168.42.1" netmask="255.255.255.0">
    <dhcp>
      <host mac="02:C0:77:B4:28:80" ip="192.168.42.10" name="talos-prod-cp1" />
      <host mac="02:52:A7:0B:1D:89" ip="192.168.42.100" name="talos-prod-worker1" />
      <host mac="DE:6F:9F:0D:15:96" ip="192.168.42.101" name="talos-prod-worker2" />
      <host mac="12:62:54:B1:2D:B0" ip="192.168.42.102" name="talos-prod-worker3" />
      <host mac="06:31:E2:44:ED:4C" ip="192.168.42.103" name="talos-prod-worker4" />
    </dhcp>
  </ip>
</network>
```

Then:

```shell
$ virsh net-define talos-prod-net.xml --validate
$ virsh net-start talos-prod-net
$ virsh net-autostart talos-prod-net
```

Constants:

```shell
IMAGE_PATH=/usr/local/images/metal-amd64_v1.9.2.iso
VM_BRIDGE=virbr4
BOOTSTRAP_IP=10.42.42.100
```

### CP node

#### Create VM

```shell
$ virt-install --name talos-prod-cp1 \
     --ram 6144 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 \
     --location "$IMAGE_PATH",kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge="$VM_BRIDGE",mac=02:C0:77:B4:28:80 --network bridge=br0,mac=02:7F:50:1E:B0:55
$ virsh autostart talos-prod-cp1
```

#### Prepare config

```shell
$ talosctl gen config talos-prod https://$BOOTSTRAP_IP:6443
$ talosctl mc patch controlplane.yaml --patch @patches/common.patch.yaml --patch @patches/cp.patch.yaml --output cp.final.yaml
$ talosctl config merge ./talosconfig
$ talosctl config endpoint k8s.cavnet.cloud
```

#### Bootstrap Talos and k8s

```shell
$ talosctl apply-config --insecure -n 192.168.42.10 --file cp.final.yaml
$ talosctl bootstrap -n $BOOTSTRAP_IP
$ talosctl kubeconfig -n $BOOTSTRAP_IP --force-context-name talos-prod
```

#### Install Cilium

```shell
$ kubectl apply -k talos/prod/cilium # Install GatewayClass CRD before Cilium
$ helm repo add cilium https://helm.cilium.io/
$ helm repo update
$ helm install cilium cilium/cilium --version 1.17.1 --namespace kube-system --values=cilium/values.yaml
```

### Worker nodes

#### Create VMs

```shell
$ virt-install --name talos-prod-worker1 \
     --ram 4096 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=50,format=qcow2 --disk size=100,format=qcow2 \
     --location "$IMAGE_PATH",kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge="$VM_BRIDGE",mac=02:52:A7:0B:1D:89
$ virsh autostart talos-prod-worker1
# Create worker2, attached to dtcnet and pass through the TP-Link BT USB device
$ virt-install --name talos-prod-worker2 \
     --ram 6144 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=50,format=qcow2 --disk size=100,format=qcow2 \
     --location "$IMAGE_PATH",kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge="$VM_BRIDGE",mac=DE:6F:9F:0D:15:96 --network bridge=br0,mac=1e:03:e4:b3:4f:47 \
     --hostdev 0x2357:0x0604
$ virsh autostart talos-prod-worker2
# Create worker3, pass through the attached ESP32's USB serial device
$ virt-install --name talos-prod-worker3 \
     --ram 4096 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=50,format=qcow2 --disk size=100,format=qcow2 \
     --location "$IMAGE_PATH",kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge="$VM_BRIDGE",mac=12:62:54:B1:2D:B0 \
     --hostdev 0x0403:0x6001
$ virsh autostart talos-prod-worker3
```

#### Prepare config

```shell
$ talosctl mc patch worker.yaml \
    --patch @patches/common.patch.yaml \
    --patch @patches/worker-common.patch.yaml \
    --output worker.final.yaml
$ talosctl mc patch worker.yaml \
    --patch @patches/common.patch.yaml \
    --patch @patches/worker-common.patch.yaml \
    --patch @patches/worker-dtcnet.patch.yaml \
    --output worker2.final.yaml
$ talosctl mc patch worker.yaml \
    --patch @patches/common.patch.yaml \
    --patch @patches/worker-common.patch.yaml \
    --patch @patches/worker-esp32.patch.yaml \
    --output worker3.final.yaml
```

#### Apply config and join nodes to cluster

```shell
$ talosctl apply-config --insecure -n 192.168.42.100 --file worker.final.yaml
$ talosctl apply-config --insecure -n 192.168.42.101 --file worker2.final.yaml
$ talosctl apply-config --insecure -n 192.168.42.102 --file worker3.final.yaml
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
$ kubectl apply -k talos/prod/argocd
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
$ kubectl apply -f infra/aws-iamra-manager.yaml
$ kubectl apply -f infra/letsencrypt.yaml

# Restart cert-manager -- aws-iamram should inject sidecar, and cert-manager should
# be able to talk to Route53 and issue certs.
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

## OIDC w/ Keycloak

Install Keycloak:

```shell
$ kubectl apply -f infra/keycloak.yaml
```

Add public DNS record in Route53 pointing to Pocket ID's ingress IP (needed for OIDC in apiserver):

```
pocket-id.o.cavnet.cloud. 300	IN	A	172.16.42.4
```

Patch apiserver to enable OIDC auth:

```shell
$ talosctl -n 192.168.42.10 patch mc -p @talos/prod/patches/oidc.patch.yaml
```
