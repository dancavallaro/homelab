```shell
virsh net-define talos-net-cillium.xml --validate
virsh net-start talos-net-cillium
virsh net-autostart talos-net-cillium

virt-install --name talos-cillium-cp1 \
     --ram 2048 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 \
     --location /usr/local/images/metal-amd64.iso,kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge=virbr3
```

Added a route on the Mikrotik to route 192.168.200.0/24 through 10.42.42.2 (the NUC), and a
raw firewall rule to disable conntrack for this traffic.

Added this iptables rule on the NUC to allow traffic to the VMs from my office network:

```
-A LIBVIRT_FWI -s 10.42.0.0/16 -d 192.168.200.0/24 -o virbr3 -j ACCEPT
```

Then:

```shell
BOOTSTRAP_IP=192.168.200.180

talosctl gen config cillium-poc https://$BOOTSTRAP_IP:6443 --config-patch @patch.yaml
talosctl config merge ./talosconfig
talosctl config endpoint $BOOTSTRAP_IP

talosctl apply-config --insecure -n $BOOTSTRAP_IP --file controlplane.yaml

talosctl bootstrap -n $BOOTSTRAP_IP

talosctl kubeconfig -n $BOOTSTRAP_IP
```

```shell
helm repo add cilium https://helm.cilium.io/
helm repo update
helm install cilium cilium/cilium --version 1.17.1 --namespace kube-system --values=cillium.yaml
```

To update:

```shell
kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart ds/cilium
```

Spin up a worker node:

```shell
virt-install --name talos-cillium-worker1 \
     --ram 2048 --vcpus 2 --os-variant ubuntu22.04 --graphics none \
     --disk size=20,format=qcow2 \
     --location /usr/local/images/metal-amd64.iso,kernel=boot/vmlinuz,initrd=boot/initramfs.xz \
     --extra-args='console=ttyS0 talos.platform=metal slab_nomerge pti=on' --noautoconsole \
     --network bridge=virbr3
     
talosctl apply-config --insecure -n 192.168.200.38 --file worker.yaml
```

Add another route and firewall rule for the LB subnet, then add a route on the NUC:

```shell
sudo ip r add 172.16.200.0/24 via 192.168.200.180
```

Add iptables rule:

```
-A LIBVIRT_FWI -d 172.16.200.0/24 -o virbr3 -j ACCEPT
-A LIBVIRT_FWO -s 172.16.200.0/24 -i virbr3 -j ACCEPT
```

Enabling Gateway API support:

```shell
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gatewayclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_gateways.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_httproutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_referencegrants.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/standard/gateway.networking.k8s.io_grpcroutes.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.2.0/config/crd/experimental/gateway.networking.k8s.io_tlsroutes.yaml
```

TLS termination: 

```shell
kubectl create secret tls any.o.cavnet.cloud-cert --cert tls.crt --key tls.key
```

To create cloudflare tunnel:

```shell
cloudflared tunnel create cilium-poc-tunnel
cloudflared tunnel route dns cilium-poc-tunnel '*.cilium-poc.cavnet.io'
kubectl -n internet create secret generic cloudflare-tunnel-creds \
    --from-file=credentials.json=/Users/dan/.cloudflared/98c3d230-928b-42d9-90f9-4e1469e79c0a.json
```

Test ArgoCD:

```shell
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
# Would need to also add the coredns annotation to assign a DNS name
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
kubectl -n argocd create secret tls argocd-server-tls --cert tls.crt --key tls.key
```
