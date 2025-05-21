* Loki/Mimir/(lots of others) should be StatefulSets if they don't properly handle concurrency of data access
* More monitoring:
  * Migrate heartbeats metrics/alarm from CloudWatch to LGTM+Pushover
* Storage:
  * Migrate (some? all?) local-path PVs to Synology iSCSI
  * Metrics on PVs/PVCs
* Fix Stults/Terhune parsers to properly handle text updates
* Test restoring a brand new cluster from a cluster etcd backup
