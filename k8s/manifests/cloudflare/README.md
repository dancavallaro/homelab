```shell
cloudflared tunnel create cavnet-k8s-tunnel
cloudflared tunnel route dns cavnet-k8s-tunnel '*.cavnet.io'
kubectl -n internet create secret generic cloudflare-tunnel-creds \
    --from-file=credentials.json=/Users/dan/.cloudflared/be69e948-537e-490b-9f41-b2dc01c267f3.json
```
