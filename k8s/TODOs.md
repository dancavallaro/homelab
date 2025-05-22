* More monitoring:
  * Migrate heartbeats metrics/alarm from CloudWatch to LGTM+Pushover
  * One top-level "canary" metric to CloudWatch
  * Alarm on loss of Tailscale connectivity (monitor from RPi)
  * Alarm on ArgoCD sync disabled for too long
* Storage:
  * Why are Volsync syncs happening at weird delayed times?
  * Migrate (some? all?) local-path PVs to Synology iSCSI
  * Metrics on PVs/PVCs
* Fix Stults/Terhune parsers to properly handle text updates
* Test restoring a brand new cluster from a cluster etcd backup
