<network>
  <name>talos-net</name>
  <forward mode="nat">
    <nat>
      <port start="1024" end="65535"/>
    </nat>
  </forward>
  <bridge name="virbr2" />
  <ip address="192.168.100.1" netmask="255.255.255.0">
    <dhcp>
      <host mac="02:C0:77:B4:28:80" ip="192.168.100.10" name="talos-cp1" />
      <host mac="02:52:A7:0B:1D:89" ip="192.168.100.100" name="talos-worker1" />
    </dhcp>
  </ip>
</network>

---

virsh net-define talos-net.xml --validate
virsh net-start talos-net
virsh net-autostart talos-net

====================================================================================

$ cat controlplane.patch.yaml
machine:
  certSANs:
    - cavnet.cloud
  install:
    disk: /dev/vda
  network:
    interfaces:
      - deviceSelector:
          hardwareAddr: '02:7f:50:1e:b0:55'
        # Configure this interface statically, since it gets a default route from DHCP that
        # conflicts with the default route on the private network.
        dhcp: false
        addresses:
          - 10.42.42.100/16
        routes:
          - network: 10.42.0.0/16
cluster:
  apiServer:
    certSANs:
      - cavnet.cloud
  controlPlane:
    endpoint: https://cavnet.cloud:6443

====================================================================================

virt-install --name talos-cp1 \
     --ram 2048 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 \
     --location /usr/local/images/metal-amd64.iso,kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge=virbr2,mac=02:C0:77:B4:28:80 --network bridge=br0,mac=02:7F:50:1E:B0:55

virsh console talos-cp1

export BOOTSTRAP_IP=10.42.42.100

talosctl gen config nuc-talos https://$BOOTSTRAP_IP:6443
talosctl machineconfig patch controlplane.yaml --patch @controlplane.patch.yaml -o controlplane.yaml
talosctl config merge ./talosconfig
talosctl config endpoint cavnet.cloud

talosctl apply-config --insecure -n 192.168.100.10 --file controlplane.yaml

talosctl bootstrap -n $BOOTSTRAP_IP
talosctl kubeconfig -n $BOOTSTRAP_IP

====================================================================================

$ cat worker.patch.yaml
machine:
  install:
    disk: /dev/vda
  disks:
    - device: /dev/vdb
      partitions:
        - mountpoint: /var/mnt/data

====================================================================================

virt-install --name talos-worker1 \
     --ram 2048 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 --disk size=100,format=qcow2 \
     --location /usr/local/images/metal-amd64.iso,kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge=virbr2,mac=02:52:A7:0B:1D:89

virsh console talos-worker1

talosctl machineconfig patch worker.yaml --patch @worker.patch.yaml -o worker.yaml
talosctl apply-config --insecure -n 192.168.100.100 --file worker.yaml

====================================================================================

## Note on Tailscale + routing

# These routes are necessary on dpu-host in order for it to route Tailscale traffic
# properly (the bastion doesn't need these routes to route traffic through the Mikrotik).
sudo ip r add 172.16.42.0/24 via 10.42.42.100
sudo ip r add 10.96.0.0/12 via 10.42.42.100

====================================================================================

## Note on DNS

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

====================================================================================

certbot-dns-updater-role with certbot-dns-updater-policy:

```
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

aws sts assume-role --role-arn arn:aws:iam::484396241422:role/certbot-dns-updater-role --role-session-name certbot-cert-request

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
