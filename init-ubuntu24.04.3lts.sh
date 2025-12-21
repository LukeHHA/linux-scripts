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
echo "=== DOCKER / service setup ==="
echo

echo 
read -rp "Will this server run docker? (y/n): " DOCKER_CHOICE
if [[ "$DOCKER_CHOICE" =~ ^[Yy]$ ]]; then
  echo "→ Installing Docker"
  sudo apt install ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the repository to Apt sources:
sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  VERSION_STRING="5:28.5.2~ubuntu.24.04~noble"
  
  sudo apt install \
      docker-ce="$VERSION_STRING" \
      docker-ce-cli="$VERSION_STRING" \
      containerd.io \
      docker-buildx-plugin \
      docker-compose-plugin
  
  sudo docker run hello-world
else
  echo "→ Not installing Docker"
fi


echo
echo "=== Tailscale / service setup ==="
echo

read -rp "Do you want to install Tailscale? (y/n): " TAILSCALE_CHOICE
if [[ "$TAILSCALE_CHOICE" =~ ^[Yy]$ ]]; then
  echo "→ Installing Tailscale for VM"
  curl -fsSL https://tailscale.com/install.sh | sh
  tailscale up --advertise-tags=tag:dev --ssh 

else
  echo "→ Skipping install of Tailscale"
fi

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
