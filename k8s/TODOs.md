* Storage/NAS:
  * Migrate (some? all?) local-path PVs to Synology iSCSI
  * Build tool to prep NAS for shutdown by scaling down active pods (kubectl-unmount-pvs)
  * Automatically scale down k8s cluster and shut down NAS when UPS loses power
  * Those transient Volsync PVs should (probably?) be on local-path instead of iSCSI
* Fix Stults/Terhune parsers to properly handle text updates
* Host curing calculator as static website (+ lime/lemon juice calc)
* Test restoring a brand new cluster from a cluster etcd backup
