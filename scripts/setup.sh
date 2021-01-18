#!/bin/sh

set -eux

apt-get autoremove -y
source /etc/lsb-release
apt-get update 
apt-get install curl gnupg2 -y
echo "deb http://apt.postgresql.org/pub/repos/apt ${DISTRIB_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list
curl https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
apt-get update 
apt-get install openssh-client postgresql-client-11 zabbix-agent curl netcat-openbsd vim-tiny s3cmd pv azure-cli -y
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get autoremove -y
apt-get clean

ROOTPW="$RANDOM$RANDOM$RANDOM"
( set +x;
  sleep 0.5;
  echo "$ROOTPW";
  sleep 0.5;
  echo "$ROOTPW";
  echo
)|passwd root
echo "ROOT PASSWORD : $ROOTPW" >&2

groupadd -g 1000 pgbackup
useradd -g pgbackup -G pgbackup -u 1000 -m -s /bin/bash pgbackup

echo 'export PATH="/scripts:$PATH"' >> /home/pgbackup/.bashrc
echo 'cd /srv' >> /home/pgbackup/.bashrc
chown -R pgbackup:pgbackup /home/pgbackup

echo "set nocompatible" > /home/pgbackup/.vimrc

cat >/home/pgbackup/.bashrc <<'EOF'
export PGUSER="${POSTGRESQL_USERNAME:?Postgres Username}"
export PGPORT="${POSTGRESQL_PORT:-5432}"
export PGHOST="${POSTGRESQL_HOST:?postgres host}"
export PGPASSWORD="${POSTGRESQL_PASSWORD:?postgres superuser password}"
EOF


chmod 755 /scripts
chmod 644 /scripts/*
chmod 755 /scripts/*.sh
ls -l /scripts/*
chown -R root:root /scripts
chown pgbackup:pgbackup /srv

apt-get autoremove -y
rm -rf /var/lib/apt/lists/*
rm "$0"
