* Automatic periodic cluster (etcd) and machineconfig backups (use a k8s CronJob?)
* Add a second CP node, do CP backups w/ --preserve=false
* Use ArgoCD or Flux, fully automate cluster bootstrapping and deployments
* Automatic reboot recovery: make br0 persistent, restart VMs (in order?)
* Figure out how to make VMs' consoles log to a file
