* More monitoring:
  * Migrate heartbeats metrics/alarm from CloudWatch to LGTM+Pushover
  * One top-level "canary" metric to CloudWatch
* Storage:
  * Migrate (some? all?) local-path PVs to Synology iSCSI
* Fix Stults/Terhune parsers to properly handle text updates
* Test restoring a brand new cluster from a cluster etcd backup
