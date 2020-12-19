#!/bin/sh

set -eux

apt-get autoremove -y
apt-get update 
source /etc/lsb-release
apt-get install curl gnupg2 -y
echo "deb http://apt.postgresql.org/pub/repos/apt ${DISTRIB_CODENAME}-pgdg main" > /etc/apt/sources.list.d/pgdg.list
curl https://www.postgresql.org/media/keys/ACCC4CF8.asc | apt-key add -
apt-get install openssh-client postgresql-client zabbix-agent curl netcat-openbsd azure-cli s3cmd -y
apt-get update 
apt-get upgrade -y
apt-get dist-upgrade -y
apt-get autoremove -y
apt-get clean

groupadd -g 1001 pgbackup
ROOTPW="$RANDOM$RANDOM$RANDOM"
( set +x;
  sleep 0.5;
  echo "$ROOTPW";
  sleep 0.5;
  echo "$ROOTPW";
  echo
)|passwd root
echo "ROOT PASSWORD : $ROOTPW" >&2

useradd -u 1000 --no-user-group -g pgbackup -m -s /bin/bash --home-dir /srv/conf/ pgbackup
chown -R pgbackup:pgbackup /srv/conf/

chmod 755 /scripts
chmod 644 /scripts/*
chmod 755 /scripts/*.sh
ls -l /scripts/*
chown -R root:root /scripts
chown pgbackup:pgbackup /srv


apt-get autoremove -y
rm -rf /var/lib/apt/lists/*
rm "$0"
