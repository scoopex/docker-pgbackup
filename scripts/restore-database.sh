#!/bin/bash

FILE="$1"
DATABASE="$2"

if [ -z "$DATABASE" ];then
   echo "$0 <file> <database>"
   exit 1

fi

if ! [ -f "$FILE" ];then
    echo "ERROR: $FILE does not exist"
    exit 1
fi


if [[ -n "$CRYPT_PASSWORD"  ]];then
   CRYPT_FILE="$HOME/.crypt_password_$$"
   trap "rm -f '$CRYPT_FILE'" TERM INT EXIT
   echo -n "$CRYPT_PASSWORD" > "$CRYPT_FILE"
fi

(
cat <<EOF
SELECT * FROM pg_stat_activity WHERE datname = '${DATABASE}';

UPDATE pg_database SET datallowconn = 'false' WHERE datname = '${DATABASE}';
SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DATABASE}';
EOF
) | psql 


if ( echo "$FILE"|grep -P ".+\.gpg" );then
  pv -e "$FILE" | gpg -d --batch --passphrase-file "$CRYPT_FILE" -o - | zcat -c | \
   pg_restore -j8 --verbose --exit-on-error --clean --if-exists -Fc -d "${DATABASE}"
  RET="$?"
else
  pv -e "$FILE" | zcat -c | \
   pg_restore -j8 --verbose --exit-on-error --clean --if-exists -Fc -d "${DATABASE}"
  RET="$?"
fi

if [ "$RET" != "0" ];then
   echo "ERROR: RESTORE FAILED WITH CODE $RET AFTER $SECONDS SECONDS"
else
   echo "INFO: RESTORE SUCCESSFUL AFTER $SECONDS SECONDS"
fi




