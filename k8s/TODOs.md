* Get creds out of source to ESO (see https://dashboard.gitguardian.com/workspace/668916/incidents)
* More monitoring:
  * Cluster metrics
  * Talos logs
  * Pod metrics
  * Node(VM) metrics
  * Host(NUC) metrics/logs
* Set up notifications for cron/job failures (and any other health events)
* Backup job:
  * Only back up directories for active PVs
  * Add support for skipping PVs somehow
* Test restoring a brand new cluster from a cluster etcd backup
