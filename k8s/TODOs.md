* Test restoring a brand new cluster from a cluster backup
* Migrate all apps to ArgoCD w/ Helm/Kustomize
* Automatic reboot recovery: make br0 persistent, restart VMs (in order?)
* Try using Cilium instead of Flannel, consider using it instead of:
  * kube-proxy (Cilium can do kube-proxy's job)
  * MetalLB (Cilium does LBs)
  * Traefik (Cilium does ingresses and gateways)
* Check out [OpenFaaS](https://github.com/openfaas/faas), consider migrating Terhune Updates to it
* Set up notifications for backup job failures (and any other health events)
* Avoid using Traefik TLS gateway for cloudflare tunnel backend, either disable the HTTP->HTTPS redirect or
  use a different ingress controller for the public gateway or something.
