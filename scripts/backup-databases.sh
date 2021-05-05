#!/bin/bash

set -eu 


#######################################################################################################################################
####
#### INIT

run_dir="$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
source "${run_dir}/functions.sh"

export PATH="/scripts/:$PATH"

env_file="${ENV_FILE:-/srv/conf/pgbackup.env}"

if [ -f "${env_file}" ];then
   echo "sourcing ${env_file}"
   # shellcheck source=/dev/null
   source "${env_file}"
else
   echo "environment file '${env_file}' does not exist"
fi

startime_backup="$SECONDS"
crypt_file="${CRYPT_FILE:-/srv/conf/pgbackup.passphrase}"
crypt_password="${CRYPT_PASSWORD:-}"

upload_type="${UPLOAD_TYPE:-off}"

s3_cfg="${S3_CFG:-/srv/conf/s3cfg}"

zabbix_port="${ZABBIX_SERVER_PORT:-10051}"
if [ -n "$ZABBIX_PROXY_SERVER_HOST" ];then
   zabbix_server="${ZABBIX_PROXY_SERVER_HOST}"
else
   zabbix_server="${ZABBIX_SERVER:-}"
fi
zabbix_host="${ZABBIX_HOST:-}"

backup_type="${BACKUP_TYPE:-custom}"
databases_to_backup="${DATABASES_OVERRIDE:-all}"
base_backup="${BASE_BACKUP:-false}"
bucket_name="${BUCKET_NAME:-backup}"

pg_ident="${PG_IDENT:-${PGHOST:-}}"

maxage_days_local="${MAXAGE_LOCAL:-3}"
maxage_days_remote="${MAXAGE_REMOTE:-30}"

# Environment variables for the postgres clients
PGUSER="${POSTGRESQL_USERNAME:?Postgres Username}"
PGPORT="${POSTGRESQL_PORT:-5432}"
PGHOST="${POSTGRESQL_HOST:?postgres host}"
PGPASSWORD="${POSTGRESQL_PASSWORD:?postgres superuser password}"

if [ "$base_backup" = "true" ];then
   base_backup_user="${POSTGRESQL_REPLICATION_USERNAME?Replication Username}"
   base_backup_password="${POSTGRESQL_REPLICATION_PASSWORD?Replication Password}"
fi

if [[ -n "$crypt_password"  ]];then
   crypt_file="$HOME/.crypt_password"
   echo -n "$crypt_password" > "$crypt_file"
fi



#######################################################################################################################################
####
#### HELPER FUNCTIONS



function upload_backup_setup(){
 echo "setup backup upload"
 if [ "$upload_type" = "s3" ];then
     ln -snf "$s3_cfg" /home/pgbackup/.s3cfg
     if ! s3cmd info "$bucket_name"; then
         s3cmd mb "$bucket_name"
         return $?
     fi
     return 0
 elif [ "$upload_type" = "az" ];then
    # todo: probably use --if-none-match for upload, that is probably faster, https://docs.microsoft.com/en-us/cli/azure/storage/blob?view=azure-cli-latest#az_storage_blob_upload
    if ( az storage container exists --name "${bucket_name}" --output table 2>&1|tail -1|grep -q -P '^False$' > /dev/null );then
      az storage container create --name "${bucket_name}"
      return $?
    fi
    return 0
 else
    echo "upload disabled"
    return 0
 fi
}

function upload_backup(){
 local upload_name="${1:?}"
 if [ "$upload_type" = "s3" ];then
     s3_address="${bucket_name}/${pg_ident}/${upload_name}"
     if ( s3cmd info "$s3_address" &> /dev/null );then
        return 2
     fi
     s3cmd put "$upload_name" "$s3_address"
     ret_upload="$?"
 elif [ "$upload_type" = "az" ];then
    az_address="${pg_ident}/${upload_name}"
    if az storage blob exists  --container "${bucket_name}" --name "$az_address" --output table|tail -1|grep -q -P '^True$'; then
        return 2
    fi
    az storage blob upload  --max-connections 8 --file "$upload_name" --name "$az_address" --container "${bucket_name}" --output table >/dev/null
    ret_upload="$?"
 fi

 if [ "$ret_upload" != "0" ];then
	return 1
 fi
 return 0
}

#######################################################################################################################################
####
#### MAIN


# stop here if script is launced in a manual pod to allow a interactive shell
if [ "$$" == "1" ];then
   if  [ "${MANUAL:-false}" == "true" ] || (hostname|grep -q -- "-manual-") ;then
      echo "manual mode, sleeping forever : $(date) - send me a sigterm to terminate"
      echo -n "Sleeping "
      while true; do
         echo -n "."
         sleep 2
      done
      exit 0
   fi
fi

dump_dir="/srv/dump"
backup_dir="/srv/backup"

export PGUSER
export PGPORT
export PGHOST
export PGPASSWORD

data="$(cat <<EOF
**********************************************************************************
** ENV_FILE            : $env_file
** CRYPT_FILE          : $crypt_file
** DUMP_DIR            : $dump_dir
** BACKUPDIR           : $backup_dir
** MAXAGE_LOCAL        : $maxage_days_local days
** MAXAGE_REMOTE       : $maxage_days_remote days
** UPLOAD_TYPE         : $upload_type
** BACKUP_TYPE         : $backup_type
** BASE_BACKUP         : $base_backup
** BASE_BACKUP_USER    : ${base_backup_user:-}
**
** PGUSER              : $PGUSER
** PGHOST              : $PGHOST
** PGPORT              : $PGPORT
**
** ZABBIX_SERVER       : $zabbix_server (alternatively ZABBIX_PROXY_SERVER_HOST)
** ZABBIX_HOST         : $zabbix_host
** ZABBIX_SERVER_PORT  : $zabbix_port
**
** BUCKET_NAME         : $bucket_name
*********************************************************************************************************
EOF
)"
log "$data"
echo


if [ -z "$backup_dir" ] || [ -z "$maxage_days_local" ];then
   echo "ERROR: missing config params"
	exit 1
fi

timestamp_isoish="$(date --date="today" "+%Y-%m-%d_%H-%M-%S")"


if [ -n "${1:-}" ];then
   exec "$@"
fi

if [ ! -d "$backup_dir" ];then
    mkdir -p "$backup_dir"
fi

if [ ! -d "$dump_dir" ];then
    mkdir -p "$dump_dir"
fi

if ! cd "${backup_dir}" ;then
   echo "Unable to change to dir '${backup_dir}'"
	exit 1 
fi

if ! echo "$upload_type" |grep -q  -P '^(s3|az|off)$'; then
   echo "Wrong backup type '$upload_type', use 's3', 'az' or 'off'"
   exit 1
fi

if ! echo "$backup_type" |grep -q -i -P '^(custom|sql|no)$'; then
   echo "Wrong backup type '$backup_type', use 'custom', 'sql' or 'no'"
   exit 1
fi

send_status "starting database backup"

failed=0
successful=0
database_count=0

if [ "$databases_to_backup" = "all" ];then
   databases="$(psql -q -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false;")"
else
   log "warn: override databases to backup '$databases_to_backup'"
   databases="$databases_to_backup"
fi

if [ -z "$databases" ];then
        send_status "error: no databases to backup"
        exit 1
fi

psql  << 'EOF'
SELECT d.datname AS Name,  pg_catalog.pg_get_userbyid(d.datdba) AS Owner,
    CASE WHEN pg_catalog.has_database_privilege(d.datname, 'CONNECT')
        THEN pg_catalog.pg_size_pretty(pg_catalog.pg_database_size(d.datname))
        ELSE 'No Access'
    END AS SIZE
FROM pg_catalog.pg_database d
    ORDER BY
    CASE WHEN pg_catalog.has_database_privilege(d.datname, 'CONNECT')
        THEN pg_catalog.pg_database_size(d.datname)
        ELSE NULL
    END DESC -- nulls first
    ;
EOF

for dbname in $databases;
do
   log "*** pg_dump $dbname ***************************************************************************"

   starttime="$SECONDS"
   if [ "$backup_type" = "no" ];then
      echo "per database backup disabled"
      continue 
   fi

   echo "=> backup schema"
   pg_dump -c "$dbname" -s -f "${dump_dir}/${dbname}-${timestamp_isoish}_schema.sql.gz" -Z 7
   exitcode1="$?"

   echo "=> backup database"
   if [ "$backup_type" = "custom" ];then
      pg_dump -Fc -c -f "${dump_dir}/${dbname}-${timestamp_isoish}_currently_dumping.custom.gz" -Z 7 --inserts "$dbname" && 
         mv "${dump_dir}/${dbname}-${timestamp_isoish}_currently_dumping.custom.gz" "${dump_dir}/${dbname}-${timestamp_isoish}.custom.gz"
      exitcode2="$?"
   else
      pg_dump -f "${dump_dir}/${dbname}-${timestamp_isoish}_currently_dumping.sql.gz" -Z 7 "$dbname" && 
         mv "${dump_dir}/${dbname}-${timestamp_isoish}_currently_dumping.sql.gz" "${dump_dir}/${dbname}-${timestamp_isoish}.sql.gz"
      exitcode2="$?"
   fi

   if [ "${dump_dir}" != "${backup_dir}" ];then
      echo "=> move backups to ${backup_dir}"
		mv -v "${dump_dir}/${dbname}-${timestamp_isoish}_schema.sql.gz" "${backup_dir}/${dbname}-${timestamp_isoish}_schema.sql.gz" &&
      if [ "$backup_type" = "custom" ];then
         mv -v "${dump_dir}/${dbname}-${timestamp_isoish}.custom.gz" "${backup_dir}/${dbname}-${timestamp_isoish}.custom.gz"
      else
         mv -v "${dump_dir}/${dbname}-${timestamp_isoish}.sql.gz" "${backup_dir}/${dbname}-${timestamp_isoish}.sql.gz"
      fi
      exitcode3="$?"
   else
	  exitcode3="0"
   fi

   database_count="$(( database_count + 1 ))"
   duration="$(( $(( SECONDS - starttime )) / 60 ))"
   if [ "$exitcode1" == "0" ] && [ "$exitcode2" == "0" ] && [ "$exitcode3" == "0" ];then
        send_status "successfully created backup for '$dbname' after $duration minutes"
        successful="$(( successful + 1))"
   else
     failed="$((failed + 1))"
        send_status "error: failed to backup '$dbname' after $duration minutes"
   fi
done

if [ "$base_backup" = "true" ];then
    log "*** pg_basebackup *****************************************************************************"
     starttime="$SECONDS"

     # Environment variables for the postgres clients
     export PGUSER="$base_backup_user"
     export PGPASSWORD="$base_backup_password"
     echo "performing base backup with user $PGUSER now"

     base_dump_dir="${dump_dir}/base_backup_${timestamp_isoish}"
     mkdir -p "${base_dump_dir}_currently_dumping" && \
      pg_basebackup -D "${base_dump_dir}_currently_dumping" --format=tar --gzip --progress --write-recovery-conf --verbose && \
      mv -v "${base_dump_dir}_currently_dumping" "${backup_dir}/$(basename "$base_dump_dir")"
     exitcode=$?
     duration="$(( $(( SECONDS - starttime )) / 60 ))"
     if [ "$exitcode" == "0" ];then
          send_status "successfully created base backup after $duration minutes"
          successful="$(( successful + 1))"
     else
       failed="$((failed + 1))"
          send_status "error: failed to create base backup after $duration minutes"
     fi
fi

sync_fs

duration="$(( $(( SECONDS - startime_backup )) / 60 ))"
if [ "$failed" -gt 0 ];then 
  send_status "error: failed ($failed failed backups,  $successful successful backup ($duration minutes)"
else
  send_status "$successful backups were successful ($duration minutes)"
fi



if [ -f "${crypt_file}" ];then
   log "*** encrypt backups ******************************************************************************"
   send_status "encrypting database backups now"
   while IFS= read -r -d $'\0' file;
   do
     starttime="$SECONDS"
     if [ -f "${file}.gpg" ];then
        continue
     fi
     echo "encryping $file"
	  gpg --symmetric --batch --cipher-algo aes256  --passphrase-file "$crypt_file" -o "${file}_currently_encrypting.gpg" "${file}" &&
          mv "${file}_currently_encrypting.gpg" "${file}.gpg"
     exitcode="$?"
     duration="$(( $(( SECONDS - starttime )) / 60 ))"
     if [ "$exitcode" == "0" ];then
          send_status "successfully encrypted file '$file' after $duration minutes"
          successful="$(( successful + 1))"
     else
       failed="$((failed + 1))"
          send_status "error: failed to encrypt file '$file' after $duration minutes"
     fi
  done < <( find "${backup_dir}" -type f \( -name "*.custom.gz" -or -name "*.sql.gz"  \) -print0 )

  send_status "encrypting base backups now"
  while IFS= read -r -d $'\0' base_backup_dir;
  do
     starttime="$SECONDS"
     if [ -f "${base_backup_dir}.tar.gpg" ];then
        continue
     fi
     echo "encryping $base_backup_dir"
     tar c "${base_backup_dir}" | \
           gpg --symmetric --batch --cipher-algo aes256  --passphrase-file "$crypt_file" -o "${base_backup_dir}_currently_encrypting.tar.gpg"  &&
        mv "${base_backup_dir}_currently_encrypting.tar.gpg" "${base_backup_dir}.tar.gpg"
     exitcode="$?"
     duration="$(( $(( SECONDS - starttime )) / 60 ))"
     if [ "$exitcode" == "0" ];then
          send_status "successfully encrypted base backup to file '${base_backup_dir}.tar.gpg' after $duration minutes"
          successful="$(( successful + 1))"
     else
       failed="$((failed + 1))"
          send_status "error: failed to encrypt base backup to file '${base_backup_dir}.tar.gpg' after $duration minutes"
     fi
  done < <( find "${backup_dir}" -type d -name "*_base_backup" -print0 )

fi

sync_fs

 
log "*** upload backups ******************************************************************************"
send_status "uploading encrypted files now"

upload_backup_setup

while IFS= read -r -d $'\0' file;
do
   starttime="$SECONDS"
   # todo: strace it :-) if upload_backup terminates with returncode 2, the script exists silently exits here, possible bash bug?
   set +e
   upload_backup "$(basename "$file")"
   exitcode="$?"
   set -e

   duration="$(( $(( SECONDS - starttime )) / 60 ))"
   if [ "$exitcode" == "0" ];then
	unencrypted_backup_file="${file%%.gpg}"
        echo "deleting unencrypted backup '$unencrypted_backup_file' file to save space"
	rm -f "$unencrypted_backup_file"

        send_status "successfully uploaded file '$file' after $duration minutes"
        successful="$(( successful + 1))"
   elif [ "$exitcode" == "2" ];then
        echo "already uploaded backup $file"
	continue
   else
        failed="$((failed + 1))"
        send_status "error: failed to upload file '$file' after $duration minutes"
   fi
done < <( find "${backup_dir}" -type f  -name "*.gpg" -print0)


log "*** remove outdated backups **********************************************************************"

if ( echo -n "$maxage_days_local"|grep -P -q '^\d+$' ) && [ "$maxage_days_local" != "0" ] ;then
   echo "deleting outdated backup on pv (older than $maxage_days_local days)"
   find "${backup_dir}" -type f -name "*.custom.gz*" -mtime "+${maxage_days_local}" -exec rm -fv {} \;
   find "${backup_dir}" -type f -name "*.sql.gz*" -mtime "+${maxage_days_local}" -exec rm -fv {} \;
   find "${backup_dir}" -name "*_base_backup*" -mtime "+${maxage_days_local}" -exec rm -frv {} \;
   find "${backup_dir}" -type f -name "*_currently_encrypting.gpg" -mtime +1 -exec rm -fv {} \;
   find "${dump_dir}" -type f -name "*_currently_dumping.sql.gz" -mtime +1 -exec rm -fv {} \;
   find "${dump_dir}" -type f -name "*_currently_dumping.custom.gz" -mtime +1 -exec rm -fv {} \;
   find "${dump_dir}" -type d -name "*_currently_dumping" -mtime +1 -exec rm -frv {} \;
   cd "${backup_dir}"
   send_status "total amount of backups on pv : $( du -scmh -- *.gz *.gpg 2>/dev/null|awk '/total/{print $1}')"
   sync_fs
else
   log "error: age not correctly defined, '$maxage_days_local'"
   exit 1 
fi

if [[ -n "$maxage_days_remote" ]] && [[ "$maxage_days_remote" = "0" ]] && [[ -n "$bucket_name" ]] && [[ "$upload_type" == "s3" ]];then
      echo "deleting outdated backup on s3 (older than $maxage_days_remote days)"
      for dbname in $databases;
      do
        echo "pruning outdated backups for database $dbname in $bucket_name"
        echo "+s3prune.sh \"$bucket_name\" \"${maxage_days_remote} days ago\" \".*/${pg_ident}/${dbname}-\d\d\d\d-\d\d-\d\d_\d\d-\d\d-\d\d_.*\.gpg\""
        s3prune.sh "$bucket_name" "${maxage_days_remote} days ago" ".*/${pg_ident}/${dbname}-\d\d\d\d-\d\d-\d\d_\d\d-\d\d-\d\d_.*\.gpg"
      done
fi

echo "*** overall status *******************************************************************************"

duration="$(( SECONDS  / 60 ))"
if [ "$failed" -gt "0" ];then
   send_status "error: backup failed after ${duration} minutes, there are $failed execution steps ($successful successful steps, $database_count databases)"
else
   send_status "ok: backup successful after ${duration} minutes, $successful successful steps with $database_count databases"
fi
