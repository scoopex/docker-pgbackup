#!/bin/bash

set -eux
export DEBIAN_FRONTEND=noninteractive

chmod 755 /scripts
chmod 644 /scripts/*
chmod 755 /scripts/*.sh
chown -R root:root /scripts
chown pgbackup:pgbackup /srv

