#!/bin/bash

run_dir="$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
source "${run_dir}/functions.sh"

file="$1"
crypt_password="${CRYPT_PASSWORD:?}"


if ! [ -f "$file" ];then
    log "error: $file does not exist"
    exit 1
fi


if [[ -n "$crypt_password"  ]];then
   crypt_file="${HOME}/.crypt_password"
   echo -n "$crypt_password" > "$crypt_file"
fi


if ( echo "$file"|grep -P ".+\.gpg" );then
  decrypted_file="${file%%.gpg}"
  if [ -f "$decrypted_file" ];then
      abort_it "'$decrypted_file' already exists, overwrite that file?"
  fi
  rm -f "$decrypted_file"
  gpg -d --batch --passphrase-file "$crypt_file" -o "${decrypted_file}" "$file"
  ret="$?"
  if [ "$ret" != "0" ];then
     log "error: decrypt of '$file' to '$decrypted_file' failed"
     exit $ret
  else
     log "info: decrypt of '$file' to '$decrypted_file' successful"
  fi
else
   log "info: $file is not crypted"
fi

