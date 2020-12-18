# docker-pgbackup


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
  kubectl exec -ti postgresql-backup-manual -- /bin/bash
  unset MANUAL
  ```
