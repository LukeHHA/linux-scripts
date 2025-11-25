#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Please run this script as root (e.g. sudo $0)"
  exit 1
fi

echo "=== Base system update ==="
apt update && apt upgrade -y

echo "=== Hardening adduser defaults ==="
sed -i 's/^#\?DIR_MODE=.*/DIR_MODE=0750/' /etc/adduser.conf
# Optional, only if you really want nologin as default:
# sed -i 's:^#\?DSHELL=.*:DSHELL=/usr/sbin/nologin:' /etc/adduser.conf

echo "=== SSH group & user setup ==="

if ! getent group sshlogin >/dev/null; then
  addgroup sshlogin
fi

TARGET_USER=${SUDO_USER:-}

if [[ -z "${TARGET_USER}" ]]; then
  read -rp "Enter the username that should be allowed SSH access: " TARGET_USER
fi

if ! id "${TARGET_USER}" >/dev/null 2>&1; then
  echo "User '${TARGET_USER}' does not exist. Create it first, then rerun this script."
  exit 1
fi

usermod -aG sshlogin "${TARGET_USER}"

cat <<EOF > /etc/ssh/sshd_config.d/00-initssh.conf
PasswordAuthentication no
PermitRootLogin no
X11Forwarding no
AllowGroups sshlogin
AllowUsers ${TARGET_USER}
EOF

echo "→ Reloading SSH daemon (make sure your SSH keys work before logging out!)"
sshd -t && systemctl reload ssh.service

read -rp "Do you want to add an SSH public key for ${TARGET_USER}? (y/n): " ADDKEY
if [[ "$ADDKEY" =~ ^[Yy]$ ]]; then
  echo "Paste the SSH public key for ${TARGET_USER}, then press Ctrl-D:"
  
  user_home=$(getent passwd "$TARGET_USER" | cut -d: -f6)
  mkdir -p "${user_home}/.ssh"
  chmod 700 "${user_home}/.ssh"

  # Append pasted key
  cat >> "${user_home}/.ssh/authorized_keys"

  chown -R "${TARGET_USER}:${TARGET_USER}" "${user_home}/.ssh"
  chmod 600 "${user_home}/.ssh/authorized_keys"

  echo "→ Public key added for ${TARGET_USER}."
else
  echo "→ Skipping SSH public key setup."
fi

echo
echo "=== UFW / service profile setup ==="
echo

read -rp "Will this be an SSH-accessible server? (y/n): " SSH_CHOICE
if [[ "$SSH_CHOICE" =~ ^[Yy]$ ]]; then
  echo "→ Allowing SSH (22/tcp)"
  ufw allow 22/tcp
else
  echo "→ Not opening port 22"
fi

echo
read -rp "Will this server run a web server (Nginx)? (y/n): " NGINX_CHOICE
if [[ "$NGINX_CHOICE" =~ ^[Yy]$ ]]; then
  echo "→ Installing Nginx"
  if ! dpkg -s nginx >/dev/null 2>&1; then
    apt install -y nginx
  fi
  echo "→ Allowing 'Nginx Full' firewall profile"
  ufw allow 'Nginx Full'
else
  echo "→ Not installing Nginx"
fi

echo
echo "→ Enabling UFW (you may be prompted to confirm)"
ufw logging on
ufw enable

echo
echo "=== Misc hardening / tooling ==="

apt install -y apparmor-profiles

echo "→ Masking ctrl-alt-del.target (may already be overridden)..."
if ! systemctl mask ctrl-alt-del.target 2>/dev/null; then
  echo "   Skipping: ctrl-alt-del.target is already overridden."
fi

systemctl daemon-reload

read -rp "Do you want to install qemu-guest-agent? (y/n): " QEMU_CHOICE
if [[ "$QEMU_CHOICE" =~ ^[Yy]$ ]]; then
  echo "→ Installing qemu-guest-agent for VM"
  apt install -y qemu-guest-agent
else
  echo "→ Skipping install of qemu-guest-agent"
fi

echo
echo "Setup complete."
