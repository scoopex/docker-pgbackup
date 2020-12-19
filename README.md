# docker-pgbackup

# Install it


# Launching manually for backup and restore

* Edit job description and set "MANUAL" to "true"
  ```
  kubectl edit cronjobs.batch postgresql-backup
  ```
* Launch job
  ```
  kubectl create job --from=cronjob/postgresql-backup postgresql-backup-manual
  ```
* Enter POD
  ```
  kubectl get pods|grep postgresql-backup-manual
  kubectl exec -ti postgresql-backup-manual-<id> -- /bin/bash
  unset MANUAL
  ```
