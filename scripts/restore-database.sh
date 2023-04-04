#!/bin/bash

set -eu
run_dir="$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
source "${run_dir}/functions.sh"

file="$1"
database="$2"
crypt_password="${CRYPT_PASSWORD:?}"


export PGUSER="${POSTGRESQL_USERNAME:?Postgres Username}"
export PGPORT="${POSTGRESQL_PORT:-5432}"
export PGHOST="${POSTGRESQL_HOST:?postgres host}"
export PGPASSWORD="${POSTGRESQL_PASSWORD:?postgres superuser password}"
set +eu

if [ -z "$database" ];then
   echo "$0 <file> <database>"
   exit 1

fi

if ! [ -f "$file" ];then
   log "error: $file does not exist"
   exit 1
fi


if [[ -n "$crypt_password"  ]];then
   crypt_file="${HOME}/.crypt_password"
   echo -n "$crypt_password" > "$crypt_file"
fi


conn_count="$(psql -c "select count(*) from pg_stat_activity where datname = '${database}';" -t|sed '~s, ,,g')"
if [ "$conn_count" -gt 0 ];then
   psql -c "select * from pg_stat_activity where datname = '${database}';" 
   abort_it "there are $conn_count open connections to database '${database}', terminate connections?"
fi



log "terminating all database connections"
(
cat <<EOF
select * from pg_stat_activity where datname = '${database}';

   update pg_database set datallowconn = 'false' where datname = '${database}';
   select pg_terminate_backend(pid) from pg_stat_activity where datname = '${database}';
EOF
) | psql 


if ( echo "$file"|grep -P ".+\.gpg" );then
   decrypted_file="${file%%.gpg}"
   if [ -f "$decrypted_file" ];then
      abort_it "'$decrypted_file' already exists, use that file?"
   else
      gpg -d --batch --passphrase-file "$crypt_file" -o "${decrypted_file}" "$file"
      ret="$?"
      if [ "$ret" != "0" ];then
         log "error: decrypt of '$file' to '$decrypted_file' failed"
         exit $ret
      else
         log "info: decrypt of '$file' to '$decrypted_file' successful"
      fi
   fi
   file="$decrypted_file"
fi

log "info: allowing connections again"
psql -c "update pg_database set datallowconn = 'true' where datname = '${database}';"

case $file in 
   *.sql.gz)
      log "performing sql backup restore"
      psql --set ON_ERROR_STOP="${ON_ERROR_STOP:-on}"  < <(zcat "${file}")
      ret="$?"
      ;;
   *)
      log "performing custom backup restore"
      if [ "${ON_ERROR_STOP:-on}" == "on" ];then
	      ON_ERROR_STOP="--exit-on-error"
      else
	      ON_ERROR_STOP=""
      fi
      set -x
      pg_restore -j8 --verbose $ON_ERROR_STOP --clean --if-exists -Fc -d "${database}" ${EXTRA_ARGS:-} "${file}"
      ret="$?"
      set +x
      ;;
esac

if [ "$ret" != "0" ];then
   log "error: restore failed with code $ret after $(( SECONDS / 60 )) minutes"
   exit $ret
else
   log "ok: restore successful after $SECONDS seconds"
   exit 0
fi

