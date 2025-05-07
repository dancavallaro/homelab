## Note on DNS delegation

Delegation of the k.cavnet.cloud zone from Route 53 to my private k8s_gateway nameserver
at 172.16.42.53 doesn't work when using a typical public recursive resolver (e.g. ISP),
even if the client is on the private network -- it only works when using a recursive
resolver with access to the private nameserver. For now I'm just relying on Tailscale's
DNS delegation since all of my clients are running Tailscale anyway, but if I ever want
this to work for non-Tailscale clients on the LAN (e.g. open it to the home network)
I'll need to run a recursive resolver and vend that via DHCP (Mikrotik's built-in "resolver"
only forwards and caches, it doesn't do recursion itself, so the queries will still fail
when a public resolver tries to reach the k.cavnet.cloud zone).

After that, I'd left the k.cavnet.cloud DNS record in Route54 since it seemed harmless
and at some point I want to get this working with non-Tailscale clients on the LAN.
But it was a problem for the LetsEncrypt validation, since it was trying to query the
private nameserver. So I deleted the NS record, and I actually don't think I'll need
it again. When I set up a private recursive resolver I won't need any actual delegation
from Route53, I can just return whatever I want from the resolver.

## TLS certs w/ LetsEncrypt and certbot

certbot-dns-updater-role with certbot-dns-updater-policy:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "route53:ListHostedZones",
                "route53:GetChange"
            ],
            "Resource": [
                "*"
            ]
        },
        {
            "Effect": "Allow",
            "Action": [
                "route53:ChangeResourceRecordSets"
            ],
            "Resource": [
                "arn:aws:route53:::hostedzone/Z05015042OJX42009787V"
            ]
        }
    ]
}
```

```shell
aws sts assume-role --role-arn arn:aws:iam::484396241422:role/certbot-dns-updater-role --role-session-name certbot-cert-request

// TODO: try running this with --manual?
docker run -it --rm --name certbot \
    -v "/etc/letsencrypt:/etc/letsencrypt" \
    -e "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" \
    -e "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" \
    -e "AWS_SESSION_TOKEN=$AWS_SESSION_TOKEN" \
    certbot/dns-route53 certonly --preferred-challenges dns

sudo openssl storeutl -noout -text -certs /etc/letsencrypt/live/o.cavnet.cloud/cert.pem

sudo kubectl create secret tls o.cavnet-wildcard-cert \
    --cert /etc/letsencrypt/live/o.cavnet.cloud/fullchain.pem \
    --key /etc/letsencrypt/live/o.cavnet.cloud/privkey.pem
```

## Multi-homing with homenet

On the Mikrotik I created a new VLAN interface on the port connected to dpu-host, tagged
with VLAN 192, and bridged to dtcnet. Then on dpu-host, I create a tagged interface:

```shell
sudo ip link add link br0 name dtcnet0 type vlan id 192
sudo ip link set dtcnet0 up
sudo dhclient dtcnet0
```

```shell
$ ip a show dev dtcnet0
206: dtcnet0@br0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP group default qlen 1000
    inet 192.168.6.9/22 brd 192.168.7.255 scope global dynamic dtcnet0
```

NOTE: This interface isn't actually necessary! The Talos worker has its own VLAN 
interface, and this one winds up having no use in the end.

### Set up dtcnet worker node

```shell
virt-install --name talos-worker2 \
     --ram 4096 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 --disk size=100,format=qcow2 \
     --location /usr/local/images/metal-amd64.iso,kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge=virbr2,mac=de:6f:9f:0d:15:96 --network bridge=br0,mac=1e:03:e4:b3:4f:47

talosctl machineconfig patch worker.yaml --patch @worker2.patch.yaml -o worker2.yaml
talosctl apply-config --insecure -n 192.168.100.101 --file worker2.yaml

# Needs to be added manually
kubectl taint nodes talos-worker2 dtcnet:NoSchedule
```

Here's what the label and taint look like:

```shell
dan@dpu-host:~/rpi-config/talos$ kubectl get node talos-worker2 --show-labels
NAME            STATUS   ROLES    AGE   VERSION   LABELS
talos-worker2   Ready    <none>   25m   v1.30.3   beta.kubernetes.io/arch=amd64,beta.kubernetes.io/os=linux,kubernetes.io/arch=amd64,kubernetes.io/hostname=talos-worker2,kubernetes.io/os=linux,network=dtcnet

dan@dpu-host:~/rpi-config/talos$ kubectl get nodes -o json | jq '.items[] | select(.metadata.name == "talos-worker2") | .spec.taints'
[
  {
    "effect": "NoSchedule",
    "key": "dtcnet",
  }
]
```

To see what's running on the node:

```shell
dan@dpu-host:~/rpi-config/talos$ kubectl get pods --all-namespaces -o wide --field-selector spec.nodeName=talos-worker2
NAMESPACE     NAME                 READY   STATUS    RESTARTS      AGE   IP              NODE            NOMINATED NODE   READINESS GATES
kube-system   kube-flannel-gq55j   1/1     Running   1 (14m ago)   27m   192.168.6.100   talos-worker2   <none>           <none>
kube-system   kube-proxy-68jqc     1/1     Running   0             14m   192.168.6.100   talos-worker2   <none>           <none>
```

### Running on host network on dtcnet 

First, need to allow pods to run with host networking:

```shell
kubectl label ns default pod-security.kubernetes.io/enforce=privileged
```

Then, run a pod with host networking, the dtcnet node selector, and toleration:

```yaml
  hostNetwork: true
  nodeSelector:
    network: dtcnet
  tolerations:
    - key: dtcnet
      operator: Exists
      effect: NoSchedule
```

## Upgrading Talos

### Worker nodes

```shell
for node in 192.168.100.100 192.168.100.101; do
    talosctl upgrade -n $node \
      --image ghcr.io/siderolabs/installer:v1.8.0
done
```

### Control plane nodes

NOTE: Make sure to upgrade CP node with --preserve=true, while I only have one CP node.

```shell
talosctl upgrade --preserve=true -n 192.168.100.10 \
    --image ghcr.io/siderolabs/installer:v1.8.0
```

## Bluetooth

Getting the NUC's Bluetooth adapter working on Kubernetes in the Talos VM was a two-step
process. Making this Bluetooth adapter available inside a VM was relatively straightforward
once I found this excellent comment: https://github.com/home-assistant/operating-system/issues/2611#issuecomment-2081271327.
By passing through both the PCI device and the USB Bluetooth device, I was able to see
and access the Bluetooth adapter from within an Ubuntu VM. These steps are documented in
talos/prod/README.md.

Getting it to work in a *Talos* VM was trickier because Talos's kernel is compiled without
BT support (confirmed in https://github.com/siderolabs/pkgs/issues/486). There's an open
request for a Talos System Extension for BT support (https://github.com/siderolabs/extensions/issues/247),
but in the meantime the solution is to just build the kernel with BT-related modules.

I originally got this working with the built-in AX201, but after a reboot it stopped working
and I never got it working again. I switched to a TP-Link UB500, and that's working after
building in the Realtek firmware system extension image which has the necessary firmware.

### Building Talos with Bluetooth support

1. Start container registry if not one already: `docker run -d -p 5005:5000 --restart always --name local registry:2`
2. Make kernel config changes in `pkgs` repo.
3. Build kernel image: `make kernel REGISTRY=127.0.0.1:5005 PUSH=true PLATFORM=linux/amd64`
4. Update `hack/modules-amd64.txt` in `talos` repo to include new modules.
5. Build kernel and initramfs: `make kernel initramfs PKG_KERNEL=127.0.0.1:5005/siderolabs/kernel:<TAG> PLATFORM=linux/amd64`
6. Build imager image: `make imager PKG_KERNEL=127.0.0.1:5005/siderolabs/kernel:<TAG> PLATFORM=linux/amd64 INSTALLER_ARCH=targetarch PUSH=true REGISTRY=127.0.0.1:5005`
7. May need to explicitly pull imager image if it's been updated: `docker pull 127.0.0.1:5005/siderolabs/imager:<TAG>`
8. Build ISO: `docker run --rm -t -v $PWD/_out:/out 127.0.0.1:5005/siderolabs/imager:<TAG> iso --system-extension-image ghcr.io/siderolabs/realtek-firmware:20250211@sha256:6c22784b86d781eba07a4025b9dfb4ae5679e05e3577d54c6c4283ba5dd7cec5`
9. Build installer image: `docker run --rm -t -v $PWD/_out:/out 127.0.0.1:5005/siderolabs/imager:<TAG> installer --base-installer-image ghcr.io/siderolabs/installer:v1.9.5 --system-extension-image ghcr.io/siderolabs/realtek-firmware:20250211@sha256:6c22784b86d781eba07a4025b9dfb4ae5679e05e3577d54c6c4283ba5dd7cec5`

To upgrade a node:

```shell
talosctl upgrade -n <NODE IP> --image ghcr.io/dancavallaro/talos/installer:v1.9.5
```

## Loki log volume analysis

See log stream size by service name in the last day:

```
sum by(service_name) (bytes_over_time({service_name=~".+"} [24h]))
```

(spoiler alert, it was Talos service logs)

Break it down by service and level:

```
sum by(talos_service, level) (bytes_over_time({service_name="talos.service_logs"} [24h]))
```

## Use Pocket ID to get token to access k8s APIs from CLI

First get a token:

```shell
export CLIENT_SECRET="$(kubectl -n headlamp get secret headlamp-oidc -o jsonpath="{.data['client-secret']}" | base64 -d)"
export TOKEN="$(kubectl oidc-login get-token --oidc-issuer-url=https://pocket-id.o.cavnet.cloud --oidc-client-id=816acb21-3d87-470c-8d90-8c17ee9da65c --oidc-client-secret="$CLIENT_SECRET" --oidc-extra-scope=email,groups | jq -r .status.token)"
```

Then use the token to access an authenticated API:

```shell
curl -s -k -H "Authorization: Bearer $TOKEN" https://10.42.42.100:6443/metrics
```
