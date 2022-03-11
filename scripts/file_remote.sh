#!/bin/bash


run_dir="$(dirname "$(readlink -f "$0")")"
# shellcheck source=/dev/null
source "${run_dir}/functions.sh"

if [ "$1" = "ls" ];then
   az storage blob list  --container "${2:-$BUCKET_NAME}" --output table
   exit $?
elif [ "$1" = "get" ];then
   file_name="${2?remote file name}"
   target_file="$(basename "$file_name")"
   if [ -f "$target_file" ];then
      echo "error: target file '$target_file' already exits"
      exit 1
   fi
   az storage blob download  --name "${file_name}" --container "${3:-$BUCKET_NAME}" --file "${target_file}"
   ret="$?"
   if [ "$ret" = "0" ];then
      log "info: download successful"
      exit 0
   else
      log "error: download failed"
      exit 1
   fi
   exit $?
else
  echo "$0 ls <optional:bucket-name>"
  echo "$0 get <file> <optional:bucket-name>"
  exit 1
fi

