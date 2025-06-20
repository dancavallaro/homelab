* Storage/NAS:
  * Migrate (some? all?) local-path PVs to Synology iSCSI
  * Build tool to gracefully shut down NAS after shutting down active pods
  * Automatically shut down k8s cluster and NAS when UPS detects power loss
  * Root cause that "No records found" error after restart (related to dual NICs)
* Fix Stults/Terhune parsers to properly handle text updates
* Host curing calculator as static website (+ lime/lemon juice calc)
* Test restoring a brand new cluster from a cluster etcd backup
