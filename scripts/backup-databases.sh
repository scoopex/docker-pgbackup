#!/bin/bash

set -eu 

#######################################################################################################################################
####
#### INIT

export PATH="/scripts/:$PATH"

ENV_FILE="${ENV_FILE:-/srv/conf/pgbackup.env}"

if [ -f "${ENV_FILE}" ];then
   echo "sourcing ${ENV_FILE}"
   # shellcheck source=/dev/null
   source "${ENV_FILE}"
else
   echo "environment file '${ENV_FILE}' does not exist"
fi

STARTTIME_GLOBAL="$SECONDS"
CRYPT_FILE="${CRYPT_FILE:-/srv/conf/pgbackup.passphrase}"
CRYPT_PASSWORD="${CRYPT_PASSWORD:-}"

UPLOAD_TYPE="${UPLOAD_TYPE:-off}"

S3_CFG="${S3_CFG:-/srv/conf/s3cfg}"

ZABBIX_SERVER="${ZABBIX_SERVER:-}"
ZABBIX_HOST="${ZABBIX_HOST:-}"
BACKUP_TYPE="${BACKUP_TYPE:-custom}"
BASE_BACKUP="${BASE_BACKUP:-false}"
BUCKET_NAME="${BUCKET_NAME:-backup}"

PG_IDENT="${PG_IDENT:-${PGHOST:-}}"

MAXAGE_LOCAL="${MAXAGE_LOCAL:-3}"
MAXAGE_REMOTE="${MAXAGE_REMOTE:-30}"
PGUSER="${POSTGRESQL_USERNAME:?Postgres Username}"
PGPORT="${POSTGRESQL_PORT:-5432}"
PGHOST="${POSTGRESQL_HOST:?postgres host}"
PGPASSWORD="${POSTGRESQL_PASSWORD:?postgres superuser password}"


if [[ -n "$CRYPT_PASSWORD"  ]];then
   CRYPT_FILE="$HOME/.crypt_password"
   echo -n "$CRYPT_PASSWORD" > "$CRYPT_FILE"
fi

ln -snf "$S3_CFG" /home/pgbackup/.s3cfg

if [ "$$" == "1" ];then
   if  [ "${MANUAL:-false}" == "true" ] || (hostname|grep -q -- "-manual-") ;then
      echo "MANUAL MODE, SLEEPING FOREVER : $(date) - SEND ME A SIGTERM TO TERMINATE"
      cat
      exit 0
   fi
fi

DUMPDIR="/srv/${PG_IDENT}/dump"
BACKUPDIR="/srv/${PG_IDENT}/backup"

export PGUSER
export PGPORT
export PGHOST
export PGPASSWORD

echo "**********************************************************************"
echo "** ENV_FILE       : $ENV_FILE"
echo "** CRYPT_FILE     : $CRYPT_FILE"
echo "** DUMPDIR        : $DUMPDIR"
echo "** BACKUPDIR      : $BACKUPDIR"
echo "** MAXAGE_LOCAL   : $MAXAGE_LOCAL days"
echo "** MAXAGE_REMOTE  : $MAXAGE_REMOTE days"
echo "** UPLOAD_TYPE    : $UPLOAD_TYPE"
echo "** BACKUP_TYPE    : $BACKUP_TYPE"
echo "** BASE_BACKUP    : $BASE_BACKUP"
echo "**"
echo "** PGUSER         : $PGUSER"
echo "**"
echo "** ZABBIX_SERVER  : $ZABBIX_SERVER" 
echo "** ZABBIX_HOST    : $ZABBIX_HOST"
echo "**"
echo "** BUCKET_NAME    : $BUCKET_NAME"
echo "**********************************************************************"


if [ -z "$BACKUPDIR" ] || [ -z "$MAXAGE_LOCAL" ];then
   echo "ERROR: missing config params"
	exit 1
fi

TIMESTAMP="$(date --date="today" "+%Y-%m-%d_%H-%M-%S")"

#######################################################################################################################################
####
#### HELPER FUNCTIONS

sendStatus(){
    local STATUS="$1"
    echo ">>>>$STATUS<<<<"
    if [ -n "${ZABBIX_SERVER}" ];then
      zabbix_sender -s "${ZABBIX_HOST}" -c /etc/zabbix/zabbix_agentd.conf \
		-k postgresql.backup.globalstatus -o "$STATUS" > /dev/null || true
    fi
}

sync_fs(){
   echo "INFO: PERFORMING FS SYNC NOW"
   sync
}

upload_backup_setup(){
 echo "INFO: setup backup upload"
 if [ "$UPLOAD_TYPE" = "s3" ];then
     if ! s3cmd info "$BUCKET_NAME"; then
         s3cmd mb "$BUCKET_NAME"
         return $?
     fi
     return 0
 elif [ "$UPLOAD_TYPE" = "az" ];then
    if ( az storage container exists --name "${BUCKET_NAME}" --output table 2>&1|tail -1|grep -q -P '^False$' > /dev/null );then
      az storage container create --name "${BUCKET_NAME}"
    fi
 else
    echo "INFO: UPLOAD DISABLED"
    return 0
 fi

}
upload_backup(){
 local UPLOAD_NAME="${1:?}"

 if [ "$UPLOAD_TYPE" = "s3" ];then
     S3_ADDRESS="${BUCKET_NAME}/${PG_IDENT}/${UPLOAD_NAME}"
     if ( s3cmd info "$S3_ADDRESS" &> /dev/null );then
        return 0
     fi
     s3cmd put "$FILE" "$S3_ADDRESS"
     RET_UPLOAD="$?"
 elif [ "$UPLOAD_TYPE" = "az" ];then
    AZ_ADDRESS="${PG_IDENT}/${UPLOAD_NAME}"
    if az storage blob exists  --container "${BUCKET_NAME}" --name "$AZ_ADDRESS" --output table|tail -1|grep -q -P '^True$'; then
        return 0
    fi
    az storage blob upload  --file "$UPLOAD_NAME" --name "$AZ_ADDRESS" --container "${BUCKET_NAME}" --output table >/dev/null
    RET_UPLOAD="$?"
 else
    echo "INFO: UPLOAD DISABLED"
    return 0
 fi

 if [ "$RET_UPLOAD" = "0" ];then
    echo "trimming '$FILE' to 0 bytes to save filesystem space"
    echo -n > "$FILE"
 fi
 return "$RET_UPLOAD"
}

#######################################################################################################################################
####
#### MAIN

if [ -n "${1:-}" ];then
   exec "$@"
fi

if [ ! -d "$BACKUPDIR" ];then
    mkdir -p "$BACKUPDIR"
fi

if [ ! -d "$DUMPDIR" ];then
    mkdir -p "$DUMPDIR"
fi

if ! cd "${BACKUPDIR}" ;then
   echo "Unable to change to dir '${BACKUPDIR}'"
	exit 1 
fi

if ! echo "$UPLOAD_TYPE" |grep -q  -P '^(s3|az|off)$'; then
   echo "Wrong backup type '$UPLOAD_TYPE', use 's3', 'az' or 'off'"
   exit 1
fi

if ! echo "$BACKUP_TYPE" |grep -q -i -P '^(custom|sql|no)$'; then
   echo "Wrong backup type '$BACKUP_TYPE', use 'custom', 'sql' or 'no'"
   exit 1
fi

sendStatus "INFO: STARTING DATABASE BACKUP"

FAILED=0
SUCCESSFUL=0
DBS=0

DATABASES="$(psql -q -t -A -c "SELECT datname FROM pg_database WHERE datistemplate = false;")"
if [ -z "$DATABASES" ];then
        sendStatus "ERROR: NO DATABASES TO BACKUP"
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

for DBNAME in $DATABASES;
do
   echo "*** BACKUP $DBNAME ****************************************************************************"
   STARTTIME="$SECONDS"

   echo "=> backup schema"
   pg_dump -c "$DBNAME" -s -f "${DUMPDIR}/${DBNAME}-${TIMESTAMP}_schema.sql.gz" -Z 7
   RET1="$?"

   echo "=> backup database"

   if [ "$BACKUP_TYPE" = "custom" ];then
      pg_dump -Fc -c -f "${DUMPDIR}/${DBNAME}-${TIMESTAMP}_currently_dumping.custom.gz" -Z 7 --inserts "$DBNAME" && 
         mv "${DUMPDIR}/${DBNAME}-${TIMESTAMP}_currently_dumping.custom.gz" "${DUMPDIR}/${DBNAME}-${TIMESTAMP}.custom.gz"
      RET2="$?"
   elif [ "$BACKUP_TYPE" = "no" ];then
      echo "INFO: PER DATABASE BACKUP DISABLED"
   else
      pg_dump -f "${DUMPDIR}/${DBNAME}-${TIMESTAMP}_currently_dumping.sql.gz" -Z 7 "$DBNAME" && 
         mv "${DUMPDIR}/${DBNAME}-${TIMESTAMP}_currently_dumping.sql.gz" "${DUMPDIR}/${DBNAME}-${TIMESTAMP}.sql.gz"
      RET2="$?"
   fi

   if [ "${DUMPDIR}" != "${BACKUPDIR}" ];then
      echo "=> move backups to ${BACKUPDIR}"
		mv -v "${DUMPDIR}/${DBNAME}-${TIMESTAMP}_schema.sql.gz" "${BACKUPDIR}/${DBNAME}-${TIMESTAMP}_schema.sql.gz" &&
      if [ "$BACKUP_TYPE" = "custom" ];then
         mv -v "${DUMPDIR}/${DBNAME}-${TIMESTAMP}.custom.gz" "${BACKUPDIR}/${DBNAME}-${TIMESTAMP}.custom.gz"
      else
         mv -v "${DUMPDIR}/${DBNAME}-${TIMESTAMP}.sql.gz" "${BACKUPDIR}/${DBNAME}-${TIMESTAMP}.sql.gz"
      fi
      RET3="$?"
   else
	  RET3="0"
   fi

   DBS="$(( DBS + 1 ))"
   DURATION="$(( $(( SECONDS - STARTTIME )) / 60 ))"
   if [ "$RET1" == "0" ] && [ "$RET2" == "0" ] && [ "$RET3" == "0" ];then
        sendStatus "INFO: SUCESSFULLY CREATED BACKUP FOR '$DBNAME' after $DURATION minutes"
        SUCCESSFUL="$(( SUCCESSFUL + 1))"
   else
     FAILED="$((FAILED + 1))"
        sendStatus "ERROR: FAILED TO BACKUP '$DBNAME' after $DURATION minutes"
   fi
done

if [ "$BASE_BACKUP" = "true" ];then
   echo "*** BASE BACKUP *******************************************************************************"
     BASE_DUMPDIR="${DUMPDIR}/base_backup_${TIMESTAMP}"
     mkdir -p "${BASE_DUMPDIR}_currently_dumping" && \
      pg_basebackup -D "${BASE_DUMPDIR}_currently_dumping" --format=tar --gzip --progress --write-recovery-conf --verbose && \
      mv -v "${BASE_DUMPDIR}_currently_dumping" "${BACKUPDIR}/$(basename "$BASE_DUMPDIR")"
     RET=$?
     DURATION="$(( $(( SECONDS - STARTTIME )) / 60 ))"
     if [ "$RET1" == "0" ] && [ "$RET2" == "0" ] && [ "$RET3" == "0" ];then
          sendStatus "INFO: SUCESSFULLY CREATED BASE BACKUP after $DURATION minutes"
          SUCCESSFUL="$(( SUCCESSFUL + 1))"
     else
       FAILED="$((FAILED + 1))"
          sendStatus "ERROR: FAILED TO CREATE BASE BACKUP after $DURATION minutes"
     fi
fi

sync_fs

DURATION="$(( $(( SECONDS - STARTTIME_GLOBAL )) / 60 ))"
if [ "$FAILED" -gt 0 ];then 
  sendStatus "ERROR: FAILED ($FAILED failed backups,  $SUCCESSFUL successful backup ($DURATION minutes)"
else
  sendStatus "INFO: $SUCCESSFUL BACKUPS WERE SUCCESSFUL ($DURATION minutes)"
fi



if [ -f "${CRYPT_FILE}" ];then
   echo "*** ENCRYPT BACKUPS ******************************************************************************"
   sendStatus "INFO: ENCRYPTING DATABASE BACKUPS NOW"
   while IFS= read -r -d $'\0' FILE;
   do
     STARTTIME="$SECONDS"
     if [ -f "${FILE}.gpg" ];then
        continue
     fi
     echo "encryping $FILE"
	  gpg --symmetric --batch --cipher-algo aes256  --passphrase-file "$CRYPT_FILE" -o "${FILE}_currently_encrypting.gpg" "${FILE}" &&
          mv "${FILE}_currently_encrypting.gpg" "${FILE}.gpg"
     RET="$?"
     DURATION="$(( $(( SECONDS - STARTTIME )) / 60 ))"
     if [ "$RET" == "0" ];then
          sendStatus "INFO: SUCESSFULLY ENCRYPTED FILE '$FILE' after $DURATION minutes"
          SUCCESSFUL="$(( SUCCESSFUL + 1))"
     else
       FAILED="$((FAILED + 1))"
          sendStatus "ERROR: FAILED TO ENCRYPT FILE '$FILE' after $DURATION minutes"
     fi
  done < <( find "${BACKUPDIR}" -type f \( -name "*.custom.gz" -or -name "*.sql.gz"  \) -print0 )

  sendStatus "INFO: ENCRYPTING BASE BACKUPS NOW"
  while IFS= read -r -d $'\0' BASE_BACKUP_DIR;
  do
     STARTTIME="$SECONDS"
     if [ -f "${BASE_BACKUP_DIR}.tar.gpg" ];then
        continue
     fi
     echo "encryping $BASE_BACKUP_DIR"
     tar c "${BASE_BACKUP_DIR}" | \
           gpg --symmetric --batch --cipher-algo aes256  --passphrase-file "$CRYPT_FILE" -o "${BASE_BACKUP_DIR}_currently_encrypting.tar.gpg"  &&
        mv "${BASE_BACKUP_DIR}_currently_encrypting.tar.gpg" "${BASE_BACKUP_DIR}.tar.gpg"
     RET="$?"
     DURATION="$(( $(( SECONDS - STARTTIME )) / 60 ))"
     if [ "$RET" == "0" ];then
          sendStatus "INFO: SUCESSFULLY ENCRYPTED BASE BACKUP TO FILE '${BASE_BACKUP_DIR}.tar.gpg' after $DURATION minutes"
          SUCCESSFUL="$(( SUCCESSFUL + 1))"
     else
       FAILED="$((FAILED + 1))"
          sendStatus "ERROR: FAILED TO ENCRYPT BASE BACKUP TO FILE '${BASE_BACKUP_DIR}.tar.gpg' after $DURATION minutes"
     fi
  done < <( find "${BACKUPDIR}" -type d -name "*_base_backup" -print0 )

fi

sync_fs

 
echo "*** UPLOAD BACKUPS ******************************************************************************"
sendStatus "INFO: UPLOADING ENCRYPTED FILES NOW"

upload_backup_setup

while IFS= read -r -d $'\0' FILE;
do
   STARTTIME="$SECONDS"

   upload_backup "$(basename "$FILE")"
   RET="$?"

   DURATION="$(( $(( SECONDS - STARTTIME )) / 60 ))"
   if [ "$RET" == "0" ];then
        sendStatus "INFO: SUCESSFULLY UPLOADED FILE '$FILE' after $DURATION minutes"
        SUCCESSFUL="$(( SUCCESSFUL + 1))"

   else
        FAILED="$((FAILED + 1))"
        sendStatus "ERROR: FAILED TO UPLOAD FILE '$FILE' after $DURATION minutes"
   fi
done < <( find "${BACKUPDIR}" -type f  -name "*.gpg" -print0)


echo "*** REMOVE OUTDATED BACKUPS **********************************************************************"

if ( echo -n "$MAXAGE_LOCAL"|grep -P -q '^\d+$' ) && [ "$MAXAGE_LOCAL" != "0" ] ;then
   echo "INFO: DELETING OUTDATED BACKUP ON PV (OLDER THAN $MAXAGE_LOCAL DAYS)"
   find "${BACKUPDIR}" -type f -name "*.uploaded" -mtime "+${MAXAGE_LOCAL}" -exec rm -fv {} \;
   find "${BACKUPDIR}" -type f -name "*.custom.gz*" -mtime "+${MAXAGE_LOCAL}" -exec rm -fv {} \;
   find "${BACKUPDIR}" -type f -name "*.sql.gz*" -mtime "+${MAXAGE_LOCAL}" -exec rm -fv {} \;
   find "${BACKUPDIR}" -name "*_base_backup*" -mtime "+${MAXAGE_LOCAL}" -exec rm -frv {} \;
   find "${BACKUPDIR}" -type f -name "*_currently_encrypting.gpg" -mtime +1 -exec rm -fv {} \;
   find "${DUMPDIR}" -type f -name "*_currently_dumping.sql.gz" -mtime +1 -exec rm -fv {} \;
   find "${DUMPDIR}" -type f -name "*_currently_dumping.custom.gz" -mtime +1 -exec rm -fv {} \;
   find "${DUMPDIR}" -type d -name "*_currently_dumping" -mtime +1 -exec rm -frv {} \;
   echo "TOTAL AMOUNT OF BACKUPS ON PV : $( du -scmh -- *.gz *.gpg|awk '/total/{print $1}')"
   sync_fs
else
	echo "Age not correctly defined, '$MAXAGE_LOCAL'"
	exit 1 
fi

if [[ -n "$MAXAGE_REMOTE" ]] && [[ "$MAXAGE_REMOTE" = "0" ]] && [[ -n "$BUCKET_NAME" ]] && [[ "$UPLOAD_TYPE" == "s3" ]];then
      echo "INFO: DELETING OUTDATED BACKUP ON S3 (OLDER THAN $MAXAGE_REMOTE DAYS)"
      for DBNAME in $DATABASES;
      do
        echo "INFO: PRUNING OUTDATED BACKUPS FOR DATABASE $DBNAME IN $BUCKET_NAME"
        echo "+s3prune.sh \"$BUCKET_NAME\" \"${MAXAGE_REMOTE} days ago\" \".*/${PG_IDENT}/${DBNAME}-\d\d\d\d-\d\d-\d\d_\d\d-\d\d-\d\d_.*\.gpg\""
        s3prune.sh "$BUCKET_NAME" "${MAXAGE_REMOTE} days ago" ".*/${PG_IDENT}/${DBNAME}-\d\d\d\d-\d\d-\d\d_\d\d-\d\d-\d\d_.*\.gpg"
      done
fi

echo "*** OVERALL STATUS *******************************************************************************"

if [ "$FAILED" -gt "0" ];then
   sendStatus "ERROR: THERE ARE $FAILED EXECUTION STEPS ($SUCCESSFUL SUCCESSFUL STEPS, $DBS DATABASES)"
else
   sendStatus "OK: BACKUP SUCCESSFUL, $SUCCESSFUL SUCCESSFUL STEPS WITH $DBS DATABASES"
fi

