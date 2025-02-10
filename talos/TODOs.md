* Automatic backups of etcd, machineconfig, persistent volumes (use CronJob?)
  * And test restoring a brand new cluster from a backup!
* Use ArgoCD or Flux, fully automate cluster bootstrapping and deployments
* Automatic reboot recovery: make br0 persistent, restart VMs (in order?)