#!/bin/bash

FILE="$1"
DATABASE="$2"

abort_it(){
  local MSG="$1"
  echo
  echo "$MSG"
  read -r -p "Continue (y/n) : " ASK
  if [ "$ASK" = "y" ];then
     return
  fi
  exit 1
}

export PGUSER="${POSTGRESQL_USERNAME:?Postgres Username}"
export PGPORT="${POSTGRESQL_PORT:-5432}"
export PGHOST="${POSTGRESQL_HOST:?postgres host}"
export PGPASSWORD="${POSTGRESQL_PASSWORD:?postgres superuser password}"

if [ -z "$DATABASE" ];then
   echo "$0 <file> <database>"
   exit 1

fi

if ! [ -f "$FILE" ];then
    echo "ERROR: $FILE does not exist"
    exit 1
fi


if [[ -n "$CRYPT_PASSWORD"  ]];then
   CRYPT_FILE="$HOME/.crypt_password"
   echo -n "$CRYPT_PASSWORD" > "$CRYPT_FILE"
fi


CONN_COUNT="$(psql -c "SELECT count(*) FROM pg_stat_activity WHERE datname = '${DATABASE}';" -t|sed '~s, ,,g')"
if [ "$CONN_COUNT" -gt 0 ];then
  psql -c "SELECT * FROM pg_stat_activity WHERE datname = '${DATABASE}';" 
  abort_it "THERE ARE $CONN_COUNT OPEN CONNECTIONS TO DATABASE '${DATABASE}', TERMINATE CONNECTIONS?"
fi



echo "INFO: TERMINATING ALL DATABASE CONNECTIONS"
(
cat <<EOF
SELECT * FROM pg_stat_activity WHERE datname = '${DATABASE}';

UPDATE pg_database SET datallowconn = 'false' WHERE datname = '${DATABASE}';
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DATABASE}';
EOF
) | psql 


if ( echo "$FILE"|grep -P ".+\.gpg" );then
  DECRYPTED_FILE="${FILE%%.gpg}"
  if [ -f "$DECRYPTED_FILE" ];then
      abort_it "'$DECRYPTED_FILE' ALREADY EXISTS, USE THAT FILE?"
  else
      gpg -d --batch --passphrase-file "$CRYPT_FILE" -o "${DECRYPTED_FILE}" "$FILE"
      RET="$?"
      if [ "$RET" != "0" ];then
         echo "ERROR: DECRYPT OF '$FILE' TO '$DECRYPTED_FILE' FAILED"
         exit $RET
      else
         echo "INFO: DECRYPT OF '$FILE' TO '$DECRYPTED_FILE' SUCCESSFUL"
      fi
  fi
  FILE="$DECRYPTED_FILE"
fi

echo "INFO: ALLOWING CONNECTIONS AGAIN"

pg_restore -j8 --verbose --exit-on-error --clean --if-exists -Fc -d "${DATABASE}" "${FILE}"
RET="$?"

if [ "$RET" != "0" ];then
   echo "ERROR: RESTORE FAILED WITH CODE $RET AFTER $SECONDS SECONDS"
   exit $RET
else
   echo "INFO: RESTORE SUCCESSFUL AFTER $SECONDS SECONDS"
   psql -c "UPDATE pg_database SET datallowconn = 'true' WHERE datname = '${DATABASE}';"
   exit 0
fi

