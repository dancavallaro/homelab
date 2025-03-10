* Test restoring a brand new cluster from a cluster backup
* Use ArgoCD to fully automate cluster bootstrapping and deployments
* Automatic reboot recovery: make br0 persistent, restart VMs (in order?)
* Try using Cilium instead of Flannel, consider using it instead of:
  * kube-proxy (Cilium can do kube-proxy's job)
  * MetalLB (Cilium does LBs)
  * Traefik (Cilium does ingresses and gateways)
* Check out [OpenFaaS](https://github.com/openfaas/faas), consider migrating Terhune Updates to it
