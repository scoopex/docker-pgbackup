#!/bin/bash


STARTTIME_GLOBAL="$SECONDS"

if [ -n "$1" ];then
   exec "$@"
fi

ENV_FILE="${ENV_FILE:-/srv/pgbackup.env}"
CRYPT_FILE="${CRYPT_FILE:-/srv/gpg-passphrase}"

if [ -f "${ENV_FILE}" ];then
   echo "sourcing ${ENV_FILE}"
   source "${ENV_FILE}"
fi

MAXAGE="${MAXAGE:?MAXAGE IN DAYS}"
ZABBIX_SERVER="${ZABBIX_SERVER:-}"
ZABBIX_HOST="${ZABBIX_HOST:-}"
BACKUP_TYPE="${BACKUP_TYPE:-custom}"

PGUSER="${PG_USER:?Postgres Username}"
PGPORT="${PG_PORT:-5432}"
PGHOST="${PG_HOST:?postgres host}"
PGPASSWORD="${PG_PASS:?postgres superuser password}"

PG_IDENT="${PG_IDENT:-$PGHOST}"

DUMPDIR="/srv/${PG_IDENT}/dump"
BACKUPDIR="/srv/${PG_IDENT}/backup"
AZ_CONTAINER=""

export PGUSER
export PGPORT
export PGHOST
export PGPASSWORD

echo "**********************************************************************"
echo "** ENV_FILE      : $ENV_FILE"
echo "** CRYPT_FILE    : $CRYPT_FILE"
echo "** DUMPDIR       : $DUMPDIR"
echo "** BACKUPDIR     : $BACKUPDIR"
echo "** MAXAGE        : $MAXAGE days"
echo "** BACKUP_TYPE   : $BACKUP_TYPE"
echo "**"
echo "** PGUSER        : $PGUSER"
echo "** AZ_CONTAINER  : $AZ_CONTAINER"
echo "**"
echo "** ZABBIX_SERVER : $ZABBIX_SERVER" 
echo "** ZABBIX_HOST   : $ZABBIX_HOST"
echo "**********************************************************************"


if [ -z "$BACKUPDIR" ] || [ -z "$MAXAGE" ];then
   echo "ERROR: missing config params"
	exit 1
fi

TIMESTAMP="$(date --date="today" "+%Y-%m-%d_%H-%M-%S")"

sendStatus(){
    local STATUS="$1"
    echo ">>>>$STATUS<<<<"
    if [ -n "${ZABBIX_SERVER}" ];then
      zabbix_sender -s "${ZABBIX_HOST}" -c /etc/zabbix/zabbix_agentd.conf -k postgresql.backup.globalstatus -o "$STATUS" > /dev/null
    fi
}

if [ ! -d "$BACKUPDIR" ];then
    mkdir -p "$BACKUPDIR"
fi

if [ ! -d "$DUMPDIR" ];then
    mkdir -p "$DUMPDIR"
fi

cd "${BACKUPDIR}"
if ! cd "${BACKUPDIR}" ;then
   echo "Unable to change to dir '${BACKUPDIR}'"
	exit 1 
fi

if ( ! ( echo "$BACKUP_TYPE" |grep -q -P "custom|sql" ) );then
   echo "Wrong backup type '$BACKUP_TYPE', use 'cusom' or 'sql'"
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

DURATION="$(( $(( SECONDS - STARTTIME_GLOBAL )) / 60 ))"
if [ "$FAILED" -gt 0 ];then 
  sendStatus "ERROR: FAILED ($FAILED failed backups,  $SUCCESSFUL successful backup ($DURATION minutes)"
else
  sendStatus "INFO: $SUCCESSFUL BACKUPS WERE SUCCESSFUL ($DURATION minutes)"
fi



if [ -f "${CRYPT_FILE}" ];then
   echo "*** ENCRYPT BACKUPS ******************************************************************************"
   sendStatus "INFO: ENCRYPTING BACKUPS NOW"
   while IFS= read -r -d $'\n' FILE;
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
  done < <( find "${BACKUPDIR}" -type f \( -name "*.custom.gz" -or -name "*.sql.gz" \) -print0)
fi


if [ -n "$AZ_CONTAINER" ];then
   echo "*** UPLOAD BACKUPS ******************************************************************************"
   sendStatus "INFO: UPLOADING ENCRYPTED FILES NOW"

   while IFS= read -r -d $'\n' FILE;
   do
     STARTTIME="$SECONDS"
     if [ -f "${FILE}.uploaded" ];then
         continue
     fi
     echo "uploading $FILE"
     az storage blob upload-batch \
         --source "$FILE" \
         --destination "$AZ_CONTAINER" \
         --output none
     RET="$?"
     DURATION="$(( $(( SECONDS - STARTTIME )) / 60 ))"
     if [ "$RET" == "0" ];then
          touch "${FILE}.uploaded"
          sendStatus "INFO: SUCESSFULLY ENCRYPTED FILE '$FILE' after $DURATION minutes"
          SUCCESSFUL="$(( SUCCESSFUL + 1))"
     else
          FAILED="$((FAILED + 1))"
          sendStatus "ERROR: FAILED TO ENCRYPT FILE '$FILE' after $DURATION minutes"
     fi
  done < <( find "${BACKUPDIR}" -type f  -name "*.gpg" -print0)
fi


echo "*** REMOVE OUTDATED BACKUPS **********************************************************************"
if ( echo -n "$MAXAGE"|grep -P -q '^\d+$' );then
	find "${BACKUPDIR}" -type f -name "*.uploaded" -mtime "+${MAXAGE}" -exec rm -fv {} \;
	find "${BACKUPDIR}" -type f -name "*.custom.gz*" -mtime "+${MAXAGE}" -exec rm -fv {} \;
	find "${BACKUPDIR}" -type f -name "*.sql.gz*" -mtime "+${MAXAGE}" -exec rm -fv {} \;
	find "${BACKUPDIR}" -type f -name "*_currently_encrypting.gpg" -mtime +1 -exec rm -fv {} \;
	find "${BACKUPDIR}" -type f -name "*_currently_dumping.sql.gz" -mtime +1 -exec rm -fv {} \;
	find "${BACKUPDIR}" -type f -name "*_currently_dumping.custom.gz" -mtime +1 -exec rm -fv {} \;
else
	echo "Age not correctly defined, '$MAXAGE'"
	exit 1 
fi

echo "*** OVERALL STATUS *******************************************************************************"

if [ "$FAILED" -gt "0" ];then
   sendStatus "ERROR: THERE ARE $FAILED EXECUTION STEPS ($SUCCESSFUL SUCCESSFUL STEPS, $DBS DATABASES)"
else
   sendStatus "OK: BACKUP SUCCESSFUL, $SUCCESSFUL SUCCESSFUL STEPS WITH $DBS DATABASES"
fi

echo "TOTAL AMOUNT OF BACKUPS $( du -scmh -- *.gz *.gpg|awk '/total/{print $1}')"
