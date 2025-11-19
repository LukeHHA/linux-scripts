#!/usr/bin/env bash

set -e

sudo apt update && sudo apt upgrade -y

sudo sed -i 's/^#\?DIR_MODE=.*/DIR_MODE=0750/' /etc/adduser.conf

sudo sed -i 's:^#\?DSHELL=.*:DSHELL=/usr/sbin/nologin:' /etc/adduser.conf

if ! getent group sshlogin >/dev/null; then
    sudo addgroup sshlogin
fi

sudo usermod -aG sshlogin $SUDO_USER

cat <<EOF | sudo tee /etc/ssh/sshd_config.d/00-initssh.conf > /dev/null
PasswordAuthentication no
PermitRootLogin no
X11Forwarding no
AllowGroups sshlogin
AllowUsers $SUDO_USER
EOF

if sudo grep -q "PubkeyAuthentication yes" /etc/ssh/sshd_config; then
    sudo systemctl reload ssh.service
else
    echo "WARNING: PubkeyAuthentication not enabled. Not restarting sshd."
fi

sudo ufw allow 22/tcp

if ! dpkg -s nginx >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y nginx
fi

sudo ufw allow 'Nginx Full'

sudo ufw enable
sudo ufw logging on

sudo apt install apparmor-profiles -y

sudo systemctl mask ctrl-alt-del.target
sudo systemctl daemon-reload

sudo apt install qemu-guest-agent
sudo systemctl start qemu-guest-agent
sudo systemctl enable qemu-guest-agent
