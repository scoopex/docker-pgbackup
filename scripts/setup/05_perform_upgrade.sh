#!/bin/bash

set -eux
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade
apt-get dist-upgrade

apt-get autoremove -y
rm -rf /var/lib/apt/lists/*

