#!/bin/bash

set -eux

chmod 755 /scripts
chmod 644 /scripts/*
chmod 755 /scripts/*.sh
chown -R root:root /scripts
chown pgbackup:pgbackup /srv

