#!/usr/bin/env bash

# Guided Debian Server Setup Script

# Version 2.3 - Improved

set -Eeuo pipefail

DRYRUN=false
SCRIPT_LOG=”/var/log/debian-setup.log”
BACKUP_DIR=”/root/debian-setup-backups”
SSH_PORT=“22”
SSH_PORT_CHANGED=false
SCRIPT_DIR=”$(cd – “$(dirname – “${BASH_SOURCE[0]}”)” && pwd)”

RED=’\033[0;31m’
GREEN=’\033[0;32m’
YELLOW=’\033[1;33m’
BLUE=’\033[1;34m’
NC=’\033[0m’

log() {
local level=”$1”
shift
local msg=”$*”
local ts
ts=”$(date ‘+%Y-%m-%d %H:%M:%S’)”
[[ “$DRYRUN” == true ]] || echo “[$ts] [$level] $msg” | tee -a “$SCRIPT_LOG” >/dev/null
case “$level” in
ERROR) echo -e “${RED}[ERROR]${NC} $msg” ;;
WARN) echo -e “${YELLOW}[WARN]${NC} $msg” ;;
INFO) echo -e “${BLUE}[INFO]${NC} $msg” ;;
SUCCESS) echo -e “${GREEN}[OK]${NC} $msg” ;;
*) echo “$msg” ;;
esac
}

run_cmd() {
local cmd=”$*”
if [[ “$DRYRUN” == true ]]; then
echo -e “${YELLOW}[DRY RUN]${NC} $cmd”
return 0
fi
log INFO “Executing: $cmd”
eval “$cmd”
}

backup_file() {
local file=”$1”
[[ -f “$file” ]] || return 0
[[ “$DRYRUN” == true ]] && return 0
mkdir -p “$BACKUP_DIR”
cp -a “$file” “$BACKUP_DIR/$(basename “$file”).backup.$(date +%s)”
}

validate_port() {
local port=”$1”
[[ “$port” =~ ^[0-9]+$ ]] || return 1
(( port >= 1 && port <= 65535 ))
}

check_root() {
if [[ “$(id -u)” -ne 0 ]]; then
log ERROR “Run this script as root.”
exit 1
fi
}

parse_args() {
for arg in “$@”; do
case “$arg” in
–dry-run) DRYRUN=true; echo -e “${YELLOW}Dry run mode enabled.${NC}” ;;
-h|–help)
cat <<‘EOH’
Usage: ./debian-setup.sh [–dry-run]

Interactive Debian setup with optional components:

- Hostname / timezone / locale / SSH port
- Optional Endlessh honeypot (only if SSH moved from port 22)
- Essential packages with unattended-upgrades
- Optional Docker from official repository
- Optional custom MOTD script
- Optional system update helper utility

Options:
–dry-run    Show what would be done without making changes
-h, –help   Show this help message

EOH
exit 0
;;
esac
done
}

update_system() {
log INFO “Updating package lists and upgrading installed packages…”
run_cmd apt-get update
run_cmd DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
log SUCCESS “System packages updated.”
}

configure_hostname() {
local new_hostname
while true; do
read -r -p “Enter the desired hostname: “ new_hostname
if [[ “$new_hostname” =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
backup_file /etc/hostname
backup_file /etc/hosts
run_cmd hostnamectl set-hostname “$new_hostname”
if [[ “$DRYRUN” == false ]]; then
printf ‘%s\n’ “$new_hostname” > /etc/hostname
if grep -qE ‘^127.0.1.1\s+’ /etc/hosts; then
sed -i “s/^127.0.1.1\s+.*/127.0.1.1 ${new_hostname}/” /etc/hosts
else
printf ‘127.0.1.1 %s\n’ “$new_hostname” >> /etc/hosts
fi
fi
log SUCCESS “Hostname set to $new_hostname.”
return 0
fi
log ERROR “Invalid hostname format. Use alphanumeric and hyphens only, 1-63 chars.”
done
}

configure_timezone() {
local search choice timezone
while true; do
read -r -p “Enter part of your timezone (e.g. Europe or Berlin): “ search
[[ -n “$search” ]] || { log ERROR “Search term cannot be empty.”; continue; }

```
mapfile -t matches < <(timedatectl list-timezones | grep -i -- "$search" | head -n 20)
(( ${#matches[@]} > 0 )) || { log ERROR "No matching timezones found."; continue; }

printf '%s\n' "Matching timezones:"
local i=1
for timezone in "${matches[@]}"; do
  printf '%d) %s\n' "$i" "$timezone"
  ((i++))
done

read -r -p "Select timezone number: " choice
if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#matches[@]} )); then
  timezone="${matches[$((choice-1))]}"
  run_cmd timedatectl set-timezone "$timezone"
  log SUCCESS "Timezone set to $timezone."
  return 0
fi
log ERROR "Invalid selection."
```

done
}

configure_locale() {
local search choice locale escaped_locale
while true; do
read -r -p “Enter part of your preferred locale (e.g. en or de): “ search
[[ -n “$search” ]] || { log ERROR “Search term cannot be empty.”; continue; }

```
mapfile -t matches < <(grep -i -- "$search" /usr/share/i18n/SUPPORTED | awk '/UTF-8/{print $1}' | head -n 20)
(( ${#matches[@]} > 0 )) || { log ERROR "No matching UTF-8 locales found."; continue; }

printf '%s\n' "Matching locales:"
local i=1
for locale in "${matches[@]}"; do
  printf '%d) %s\n' "$i" "$locale"
  ((i++))
done

read -r -p "Select locale number: " choice
if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#matches[@]} )); then
  locale="${matches[$((choice-1))]}"
  backup_file /etc/locale.gen
  
  if [[ "$DRYRUN" == false ]]; then
    # Escape special characters in locale for sed
    escaped_locale=$(printf '%s\n' "$locale" | sed 's/[.[\*^$()+?{|]/\\&/g')
    
    if grep -qE "^#?${escaped_locale}[[:space:]]+UTF-8" /etc/locale.gen; then
      sed -i "s/^#\?${escaped_locale}[[:space:]]\+UTF-8/${locale} UTF-8/" /etc/locale.gen
    else
      printf '%s UTF-8\n' "$locale" >> /etc/locale.gen
    fi
  fi
  
  run_cmd locale-gen
  run_cmd update-locale LANG="$locale"
  log SUCCESS "Locale set to $locale."
  return 0
fi
log ERROR "Invalid selection."
```

done
}

configure_ssh() {
local new_port current_port ssh_connection=false
[[ -n “${SSH_CONNECTION:-}” || -n “${SSH_CLIENT:-}” ]] && ssh_connection=true
current_port=”$(awk ‘/^#?Port /{print $2; exit}’ /etc/ssh/sshd_config 2>/dev/null || true)”
current_port=”${current_port:-22}”

while true; do
read -r -p “Enter new SSH port [${current_port}]: “ new_port
new_port=”${new_port:-$current_port}”
validate_port “$new_port” && break
log ERROR “Invalid port number (1-65535).”
done

SSH_PORT=”$new_port”
if [[ “$new_port” == “$current_port” ]]; then
log INFO “SSH port unchanged.”
return 0
fi

backup_file /etc/ssh/sshd_config
if [[ “$DRYRUN” == false ]]; then
if grep -qE ’^#?Port ’ /etc/ssh/sshd_config; then
sed -i “s/^#?Port .*/Port ${new_port}/” /etc/ssh/sshd_config
else
printf ‘\nPort %s\n’ “$new_port” >> /etc/ssh/sshd_config
fi

```
# Test SSH configuration before applying
if ! sshd -t; then
  log ERROR "SSH configuration test failed. Restoring backup."
  cp "$BACKUP_DIR"/sshd_config.backup.* /etc/ssh/sshd_config
  return 1
fi
```

fi

SSH_PORT_CHANGED=true
if [[ “$ssh_connection” == true ]]; then
log WARN “SSH connection detected. Service restart deferred until reboot.”
log WARN “After reboot, connect using: ssh -p ${new_port} user@server”
else
run_cmd systemctl restart ssh
log SUCCESS “SSH service restarted on port $new_port.”
fi
log SUCCESS “SSH configured to port $new_port.”
}

install_endlessh() {
local answer
echo -e “\n${BLUE}— Endlessh SSH Honeypot —${NC}”
read -r -p “Install Endlessh honeypot on port 22? [y/N]: “ answer
[[ “$answer” =~ ^[Yy]$ ]] || { log INFO “Skipping Endlessh.”; return 0; }

if [[ “$SSH_PORT” == “22” ]]; then
log WARN “Cannot install Endlessh: SSH is still on port 22. Move SSH first.”
return 0
fi

if ! run_cmd apt-get install -y endlessh; then
log ERROR “Failed to install Endlessh package.”
return 0
fi

if [[ “$DRYRUN” == false ]]; then
mkdir -p /etc/endlessh
cat > /etc/endlessh/config <<‘EOF’

# Endlessh SSH honeypot configuration

Port 22
Delay 10000
MaxLineLength 32
MaxClients 4096
LogLevel 1
KeepaliveTime 600
EOF
fi

run_cmd systemctl enable –now endlessh
log SUCCESS “Endlessh installed and running on port 22.”
}

install_essential_packages() {
local answer
echo -e “\n${BLUE}— Essential System Packages —${NC}”
read -r -p “Install essential packages (curl, htop, unattended-upgrades, etc.)? [Y/n]: “ answer
[[ “$answer” =~ ^[Nn]$ ]] && { log INFO “Skipping essential packages.”; return 0; }

if ! run_cmd apt-get install -y sudo curl wget htop unattended-upgrades systemd-timesyncd ca-certificates gnupg lsb-release apt-transport-https; then
log ERROR “Failed to install some essential packages.”
return 0
fi

if [[ “$DRYRUN” == false ]]; then
cat > /etc/apt/apt.conf.d/20auto-upgrades <<‘EOF’
APT::Periodic::Update-Package-Lists “1”;
APT::Periodic::Unattended-Upgrade “1”;
APT::Periodic::AutocleanInterval “7”;
EOF

```
# Enable time synchronization
systemctl enable --now systemd-timesyncd 2>/dev/null || true
```

fi

log SUCCESS “Essential packages installed and auto-updates configured.”
}

install_docker() {
local answer arch codename
echo -e “\n${BLUE}— Docker Container Platform —${NC}”
read -r -p “Install Docker from official repository? [y/N]: “ answer
[[ “$answer” =~ ^[Yy]$ ]] || { log INFO “Skipping Docker.”; return 0; }

arch=”$(dpkg –print-architecture)”
case “$arch” in
amd64|arm64|armhf) ;;
*) log ERROR “Unsupported architecture for Docker: $arch”; return 0 ;;
esac

codename=”$(. /etc/os-release && echo “$VERSION_CODENAME”)”

if ! run_cmd apt-get install -y ca-certificates curl gnupg; then
log ERROR “Failed to install prerequisites for Docker.”
return 0
fi

if [[ “$DRYRUN” == false ]]; then
install -m 0755 -d /etc/apt/keyrings

```
# Download and verify Docker GPG key
if ! curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
  log ERROR "Failed to download Docker GPG key."
  return 0
fi

# Verify GPG key fingerprint
if ! gpg --dry-run --quiet --import --import-options import-show /etc/apt/keyrings/docker.gpg | grep -q "9DC8 5822 9FC7 DD38 854A  E2D8 8D81 803C 0EBF CD88"; then
  log ERROR "Docker GPG key verification failed!"
  rm -f /etc/apt/keyrings/docker.gpg
  return 0
fi

chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable" > /etc/apt/sources.list.d/docker.list
```

fi

run_cmd apt-get update

if ! run_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
log ERROR “Failed to install Docker packages.”
return 0
fi

run_cmd systemctl enable –now docker
log SUCCESS “Docker installed and started.”
}

install_motd() {
local answer
echo -e “\n${BLUE}— Custom MOTD Status Script —${NC}”
read -r -p “Install custom MOTD (Message of the Day) status display? [y/N]: “ answer
[[ “$answer” =~ ^[Yy]$ ]] || { log INFO “Skipping MOTD.”; return 0; }

if [[ “$DRYRUN” == false ]]; then
# Disable default Debian MOTD messages
chmod -x /etc/update-motd.d/* 2>/dev/null || true

```
cat > /etc/update-motd.d/99-custom-status <<'EOF'
```

#!/usr/bin/env bash
hostname_val=”$(hostname 2>/dev/null || echo Unknown)”
debian_version=”$(cat /etc/debian_version 2>/dev/null || echo Unknown)”
ip_address=”$(hostname -I 2>/dev/null | awk ‘{print $1}’ || echo Unknown)”
uptime_val=”$(uptime -p 2>/dev/null || echo Unknown)”
load_avg=”$(uptime 2>/dev/null | awk -F’load average: ’ ‘{print $2}’ | xargs || echo Unknown)”
disk_usage=”$(df -h / 2>/dev/null | awk ‘NR==2{print $3” / “$2” (”$5”)”}’ || echo Unknown)”
mem_usage=”$(free -h 2>/dev/null | awk ‘/^Mem:/{print $3” / “$2}’ || echo Unknown)”

printf ‘\n\033[1;32m=== System Status ===\033[0m\n’
printf ‘\033[1;34mHostname:\033[0m %s (Debian %s)\n’ “$hostname_val” “$debian_version”
printf ‘\033[1;34mIP Address:\033[0m %s\n’ “$ip_address”
printf ‘\033[1;34mUptime:\033[0m %s\n’ “$uptime_val”
printf ‘\033[1;34mLoad Average:\033[0m %s\n’ “$load_avg”
printf ‘\033[1;34mDisk Usage:\033[0m %s\n’ “$disk_usage”
printf ‘\033[1;34mMemory:\033[0m %s\n\n’ “$mem_usage”
EOF
chmod 0755 /etc/update-motd.d/99-custom-status
fi

log SUCCESS “Custom MOTD installed.”
}

install_update_helper() {
local answer target_file=”/usr/local/bin/update.sh”
echo -e “\n${BLUE}— System Update Helper Utility —${NC}”
read -r -p “Install standalone update helper (update.sh, up, debian-update)? [y/N]: “ answer
[[ “$answer” =~ ^[Yy]$ ]] || { log INFO “Skipping update helper.”; return 0; }

if [[ “$DRYRUN” == false ]]; then
cat > “$target_file” <<‘EOF’
#!/usr/bin/env bash

# Debian System Update Helper

set -Eeuo pipefail

export DEBIAN_FRONTEND=noninteractive

echo “==> Updating package lists”
apt-get update

echo “==> Upgrading packages”
apt-get full-upgrade -y

echo “==> Removing unused packages”
apt-get autoremove -y

echo “==> Cleaning package cache”
apt-get autoclean -y

# Optional: Flatpak updates

if command -v flatpak >/dev/null 2>&1; then
echo “==> Updating Flatpak packages”
flatpak update -y 2>/dev/null || true
fi

# Optional: Docker cleanup

if command -v docker >/dev/null 2>&1; then
echo “==> Pruning unused Docker images”
docker image prune -f 2>/dev/null || true
fi

echo “==> Update complete”

# Check if reboot required

if [[ -f /var/run/reboot-required ]]; then
echo “”
echo “⚠️  System reboot required to complete updates”
cat /var/run/reboot-required.pkgs 2>/dev/null || true
fi
EOF
chmod 0755 “$target_file”

```
# Create convenient aliases
ln -sf "$target_file" /usr/local/bin/up
ln -sf "$target_file" /usr/local/bin/debian-update
```

fi

log SUCCESS “Update helper installed: update.sh, up, debian-update”
}

show_summary() {
local hostname timezone locale endlessh_status docker_status

hostname=”$(hostname 2>/dev/null || echo Unknown)”
timezone=”$(timedatectl show –property=Timezone –value 2>/dev/null || echo Unknown)”
locale=”$(locale | grep ‘^LANG=’ | cut -d= -f2 2>/dev/null || echo Unknown)”

if [[ “$DRYRUN” == false ]]; then
endlessh_status=”$(systemctl is-active endlessh 2>/dev/null || echo inactive)”
docker_status=”$(systemctl is-active docker 2>/dev/null || echo inactive)”
else
endlessh_status=“N/A (dry run)”
docker_status=“N/A (dry run)”
fi

echo
echo -e “${GREEN}=== Setup Complete ===${NC}”
echo -e “${BLUE}Hostname:${NC} $hostname”
echo -e “${BLUE}Timezone:${NC} $timezone”
echo -e “${BLUE}Locale:${NC} $locale”
echo -e “${BLUE}SSH Port:${NC} $SSH_PORT”
echo -e “${BLUE}Endlessh:${NC} $endlessh_status”
echo -e “${BLUE}Docker:${NC} $docker_status”
echo -e “${BLUE}Log File:${NC} $SCRIPT_LOG”
echo -e “${BLUE}Backups:${NC} $BACKUP_DIR”

if [[ “$SSH_PORT_CHANGED” == true ]]; then
echo
echo -e “${YELLOW}⚠️  IMPORTANT: SSH Port Changed${NC}”
echo -e “${YELLOW}After reboot, connect using: ssh -p ${SSH_PORT} user@server${NC}”
echo -e “${YELLOW}Make sure port ${SSH_PORT} is open in your firewall!${NC}”
fi

if [[ “$DRYRUN” == false ]]; then
echo
read -r -p “Reboot now to apply all changes? [y/N]: “ reboot_answer
if [[ “$reboot_answer” =~ ^[Yy]$ ]]; then
log INFO “Rebooting system…”
sleep 3
reboot
else
echo -e “${YELLOW}Remember to reboot manually when convenient.${NC}”
fi
fi
}

main() {
echo -e “${GREEN}Welcome to the Debian Setup Script v2.3${NC}”
echo

[[ “$DRYRUN” == false ]] && {
mkdir -p “$(dirname “$SCRIPT_LOG”)” “$BACKUP_DIR”
touch “$SCRIPT_LOG”
log INFO “Script started by $(whoami)”
}

# Required configuration

update_system
configure_hostname
configure_timezone
configure_locale
configure_ssh

# Optional components - disable strict error checking

set +e
install_endlessh
install_essential_packages
install_docker
install_motd
install_update_helper
set -e

show_summary
}

# Error handling

trap ‘log ERROR “Script interrupted by user.”; exit 130’ INT TERM
trap ‘log ERROR “Script failed at line $LINENO. Check $SCRIPT_LOG for details.”; exit 1’ ERR

parse_args “$@”
check_root
main

log SUCCESS “Script completed successfully.”