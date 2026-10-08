#!/usr/bin/env bash
set -euo pipefail
# Packer installs the runtime once. Never invoke this from cloud-init.
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server iputils-ping
sudo systemctl enable ssh
sudo apt-get clean
