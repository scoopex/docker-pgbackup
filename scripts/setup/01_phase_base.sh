#!/bin/bash

set -eux

apt-get autoremove -y
source /etc/lsb-release

apt-get update 
apt-get install curl gnupg2 -y
echo "deb http://apt.postgresql.org/pub/repos/apt ${DISTRIB_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list
curl https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
apt-get update 

apt-get install postgresql-client-11 zabbix-agent curl vim-tiny s3cmd pv azure-cli screen pgtop pg-activity pgcli openssh-client less -y
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get autoremove -y
apt-get clean
apt-get autoremove -y
rm -rf /var/lib/apt/lists/*


ROOTPW="$RANDOM$RANDOM$RANDOM"
( set +x;
  sleep 0.5;
  echo "$ROOTPW";
  sleep 0.5;
  echo "$ROOTPW";
  echo
)|passwd root
echo "ROOT PASSWORD : $ROOTPW" >&2

groupadd -g 1001 pgbackup
useradd -g pgbackup -G pgbackup -u 1001 -m -s /bin/bash pgbackup

chown -R pgbackup:pgbackup /home/pgbackup

echo "set nocompatible" > /home/pgbackup/.vimrc

cat >>/home/pgbackup/.bashrc <<'EOF'
export PATH="/scripts:$PATH"
export PGUSER="${POSTGRESQL_USERNAME:?Postgres Username}"
export PGPORT="${POSTGRESQL_PORT:-5432}"
export PGHOST="${POSTGRESQL_HOST:?postgres host}"
export PGPASSWORD="${POSTGRESQL_PASSWORD:?postgres superuser password}"
EOF

