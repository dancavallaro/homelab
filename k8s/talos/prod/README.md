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
    version: 2
```

Then `sudo netplan apply` (will kill SSH session)

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
     --ram 4096 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
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
$ kubectl apply -k cilium # Install GatewayClass CRD before Cilium
$ helm repo add cilium https://helm.cilium.io/
$ helm repo update
$ helm install cilium cilium/cilium --version 1.17.1 --namespace kube-system --values=cilium/values.yaml
```

### Worker nodes

#### Create VMs

```shell
$ virt-install --name talos-prod-worker1 \
     --ram 4096 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 --disk size=100,format=qcow2 \
     --location "$IMAGE_PATH",kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge="$VM_BRIDGE",mac=02:52:A7:0B:1D:89
$ virsh autostart talos-prod-worker1
$ virt-install --name talos-prod-worker2 \
     --ram 4096 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 --disk size=100,format=qcow2 \
     --location "$IMAGE_PATH",kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge="$VM_BRIDGE",mac=DE:6F:9F:0D:15:96 --network bridge=br0,mac=1e:03:e4:b3:4f:47
$ virsh autostart talos-prod-worker2
```

#### Prepare config

```shell
$ talosctl mc patch worker.yaml \
    --patch @patches/common.patch.yaml \
    --patch @patches/worker-common.patch.yaml \
    --output worker1.final.yaml
$ talosctl mc patch worker.yaml \
    --patch @patches/common.patch.yaml \
    --patch @patches/worker-common.patch.yaml \
    --patch @patches/worker-dtcnet.patch.yaml \
    --output worker2.final.yaml
```

#### Apply config and join nodes to cluster

```shell
$ talosctl apply-config --insecure -n 192.168.42.100 --file worker1.final.yaml
$ talosctl apply-config --insecure -n 192.168.42.101 --file worker2.final.yaml
```

## Final manual bootstrapping

### Finish setting up Cilium

Configure LB pool and gateways:

```shell
$ kubectl apply -f cilium/resources.yaml
```

### Set up ArgoCD

```shell
$ kubectl create namespace argocd
$ kubectl apply -k argocd
```

### Install infra apps

```shell
$ kubectl apply -f ../../apps/dns-gateway.yaml
$ kubectl apply -f ../../apps/cert-manager.yaml
$ kubectl apply -f ../../apps/aws-iamra-manager.yaml
$ kubectl apply -f ../../apps/letsencrypt.yaml

# Restart cert-manager -- aws-iamram should inject sidecar, and should be able
# to talk to Route53 and issue wildcard cert.
$ kubectl -n cert-manager rollout restart deployment cert-manager

$ kubectl apply -f ../../apps/metrics-server.yaml
```

### Install apps

```shell
$ kubectl apply -f ../../apps/hass-proxy.yaml
```

## TODOs

* Fix HTTPS redirect on private gateway
* Set up cloudflared and test public gateway
* Make sure everything works after reboot (what about routes for LBs?)
* Set up local path provisioner, restore PV backups, test Unifi
* Test backup job
* Figure out why private IP range isn't accessible anymore
