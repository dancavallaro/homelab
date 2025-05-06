* More monitoring:
  * Migrate heartbeats metrics/alarm from CloudWatch to LGTM+Pushover
  * Metrics on PVs/PVCs
* One of the RPis should have a way to power cycle the NUC without using HA
* Set up Synology CSI
* Backup job:
  * Only back up directories for active PVs
  * Add support for skipping PVs somehow
* Test restoring a brand new cluster from a cluster etcd backup
* Set up some kind of pastebin and URL shortener
