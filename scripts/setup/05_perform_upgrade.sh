#!/bin/bash

set -eux
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get upgrade -y
apt-get dist-upgrade -y

apt-get autoremove -y
rm -rf /var/lib/apt/lists/*

