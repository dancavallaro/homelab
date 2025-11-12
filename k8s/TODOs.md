In-progress:
* Migrating curing/superjuice calculators to static k8s-hosted website

TODOs:
* Submit kubectl-unmount to Krew index (need to rename first)
* Storage/NAS:
  * Migrate (some? all?) local-path PVs to Synology iSCSI
  * Those transient Volsync PVs should (probably?) be on local-path instead of iSCSI
* When on UPS power w/o Internet, Pocket-ID breaks because DNS is broken (ArgoCD for example)
* Fix Stults/Terhune parsers to properly handle text updates
* Host curing calculator as static website (+ lime/lemon juice calc)
* Test restoring a brand new cluster from a cluster etcd backup
* Set up an IPv6-only test cluster
