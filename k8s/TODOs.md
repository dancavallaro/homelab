* Migrate heartbeats metrics/alarm from CloudWatch to LGTM+Pushover
* Get creds out of source to ESO (see https://dashboard.gitguardian.com/workspace/668916/incidents)
* More monitoring:
  * Node(VM) metrics
  * Cluster metrics
* Set up notifications for cron/job failures (and any other health events)
* One of the RPis should have a way to power cycle the NUC without using HA
* Set up Synology CSI
* Backup job:
  * Only back up directories for active PVs
  * Add support for skipping PVs somehow
* Test restoring a brand new cluster from a cluster etcd backup
