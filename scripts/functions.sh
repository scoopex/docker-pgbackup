function log(){
    local text="$(date --iso-8601=minutes) $1"
    if (echo "$text" |grep -q -P "failed|error:" );then
    	printf '\e[1;31m%-6s\e[m\n' "$text"
    elif (echo "$text" |grep -q -P "successfully|ok:" );then
    	printf '\e[1;32m%-6s\e[m\n' "$text"
    else
    	printf '\e[1;34m%-6s\e[m\n' "$text"
    fi
}

function send_status(){
    local status="$1"
    log "$status" 
    if [ -n "${zabbix_server}" ] && [ -n "${zabbix_host}" ];then
      zabbix_sender -s "${zabbix_host}" -c /etc/zabbix/zabbix_agentd.conf \
		-k postgresql.backup.globalstatus -o "$status" > /dev/null || true
    fi
}

function sync_fs(){
   echo "performing fs sync now"
   sync
}


function abort_it(){
  local msg="$1"
  echo
  echo "$msg"
  read -r -p "continue (y/n) : " ask
  if [ "$ask" = "y" ];then
     return
  fi
  exit 1
}

