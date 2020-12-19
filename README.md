# docker-pgbackup

# Install it

 * Modify settings
   ```
   vi kubernetes-cronjob.yaml
   ```
 * Apply config
   ```
   kubectl apply -n "<namespace>" kubernetes-cronjob.yaml
   ```

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
  /scripts/backup-databases.sh
  exit
  ```
* Delete job
  ```
  kubectl delete jobs.batch postgresql-backup-manual
  ```
