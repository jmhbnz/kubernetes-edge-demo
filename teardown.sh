!/usr/bin/env bash
set -e -o pipefail

# Stop microshift service
sudo systemctl stop microshift

# Uninstall and remove cloudflare serivce
sudo systemctl stop cloudflared
sudo cloudflared service uninstall
