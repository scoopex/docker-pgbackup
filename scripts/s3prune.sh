#!/bin/bash

S3_BUCKET="$1"
AGE="$2"
RE_MATCH="$3"

if [ -z "$3" ];then
   echo "$0 <bucket> <age in gnu date spec> <pcre regex>"
   echo
   echo "Example:"
   echo 's3://backup-lala/ "2 minutes ago" ".*/yolobanana-\d\d\d\d-\d\d-\d\d_\d\d-\d\d-\d\d_.*\.gpg"'
   exit 1
fi

s3cmd ls -r "${S3_BUCKET}" |awk '$4 ~ /s3:/ {print $0}'|grep -P "^$RE_MATCH\$"|while read -r line;
do
   createDate="$(echo "$line"|awk '{print $1" "$2}')"
   createDate="$(date '+%s' -d "$createDate")"
   olderThan="$(date -d "$AGE" "+%s")"
   fileName="$(echo "$line"|awk '{print $4}')"
   echo "$fileName"
   if [[ "$createDate" -lt "$olderThan" ]]
     then
       if [[ -n "$fileName" ]];
       then
           printf 'Deleting "%s"\n' "$fileName"
           s3cmd del "$fileName"
       fi
   fi
done;
