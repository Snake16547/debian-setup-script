#!/usr/bin/env bash
# Guided Debian Server Setup Script
# Version 2.3 - Enhanced Edition
# Repository: https://github.com/Snake16547/debian-setup-script

set -Eeuo pipefail

DRYRUN=false
SCRIPT_LOG="/var/log/debian-setup.log"
BACKUP_DIR="/root/debian-setup-backups"
SSH_PORT="22"
SSH_PORT_CHANGED=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

log() {
  local level="$1"
  shift
  local msg="$*"
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  [[ "$DRYRUN" == true ]] || echo "[$ts] [$level] $msg" | tee -a "$SCRIPT_LOG" >/dev/null
  case "$level" in
    ERROR) echo -e "${RED}[ERROR]${NC} $msg" ;;
    WARN) echo -e "${YELLOW}[WARN]${NC} $msg" ;;
    INFO) echo -e "${BLUE}[INFO]${NC} $msg" ;;
    SUCCESS) echo -e "${GREEN}[OK]${NC} $msg" ;;
    *) echo "$msg" ;;
  esac
}

run_cmd() {
  local cmd="$*"
  if [[ "$DRYRUN" == true ]]; then
    echo -e "${YELLOW}[DRY RUN]${NC} $cmd"
    return 0
  fi
  log INFO "Executing: $cmd"
  eval "$cmd"
}

backup_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  [[ "$DRYRUN" == true ]] && return 0
  mkdir -p "$BACKUP_DIR"
  cp -a "$file" "$BACKUP_DIR/$(basename "$file").backup.$(date +%s)"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  (( port >= 1 && port <= 65535 ))
}

check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log ERROR "Run this script as root."
    exit 1
  fi
}

parse_args() {
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRYRUN=true; echo -e "${YELLOW}Dry run mode enabled.${NC}" ;;
      -h|--help)
        cat <<'EOH'
Usage: ./debian-setup.sh [--dry-run]

Interactive Debian setup with optional components:
- Hostname / timezone / locale / SSH port
- Optional Endlessh honeypot
- Essential packages with unattended-upgrades  
- Optional Docker from official repository
- Optional custom MOTD script
- Optional system update helper utility

Options:
  --dry-run    Show what would be done without making changes
  -h, --help   Show this help message

EOH
        exit 0
        ;;
    esac
  done
}

update_system() {
  log INFO "Updating package lists and upgrading installed packages..."
  run_cmd apt-get update
  run_cmd DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  log SUCCESS "System packages updated."
}

configure_hostname() {
  local new_hostname
  while true; do
    read -r -p "Enter the desired hostname: " new_hostname
    if [[ "$new_hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
      backup_file /etc/hostname
      backup_file /etc/hosts
      run_cmd hostnamectl set-hostname "$new_hostname"
      if [[ "$DRYRUN" == false ]]; then
        printf '%s\n' "$new_hostname" > /etc/hostname
        if grep -qE '^127\.0\.1\.1\s+' /etc/hosts; then
          sed -i "s/^127\.0\.1\.1\s\+.*/127.0.1.1 ${new_hostname}/" /etc/hosts
        else
          printf '127.0.1.1 %s\n' "$new_hostname" >> /etc/hosts
        fi
      fi
      log SUCCESS "Hostname set to $new_hostname."
      return 0
    fi
    log ERROR "Invalid hostname format."
  done
}

configure_timezone() {
  local search choice timezone
  while true; do
    read -r -p "Enter part of your timezone (e.g. Europe or Berlin): " search
    [[ -n "$search" ]] || { log ERROR "Search term cannot be empty."; continue; }
    
    mapfile -t matches < <(timedatectl list-timezones | grep -i -- "$search" | head -n 20)
    (( ${#matches[@]} > 0 )) || { log ERROR "No matching timezones found."; continue; }
    
    echo "Matching timezones:"
    local i=1
    for timezone in "${matches[@]}"; do
      echo "$i) $timezone"
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
  done
}

configure_locale() {
  local search choice locale escaped_locale
  while true; do
    read -r -p "Enter part of your preferred locale (e.g. en or de): " search
    [[ -n "$search" ]] || { log ERROR "Search term cannot be empty."; continue; }
    
    mapfile -t matches < <(grep -i -- "$search" /usr/share/i18n/SUPPORTED | awk '/UTF-8/{print $1}' | head -n 20)
    (( ${#matches[@]} > 0 )) || { log ERROR "No matching UTF-8 locales found."; continue; }
    
    echo "Matching locales:"
    local i=1
    for locale in "${matches[@]}"; do
      echo "$i) $locale"
      ((i++))
    done
    
    read -r -p "Select locale number: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#matches[@]} )); then
      locale="${matches[$((choice-1))]}"
      backup_file /etc/locale.gen
      
      if [[ "$DRYRUN" == false ]]; then
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
  done
}

configure_ssh() {
  local new_port current_port ssh_connection=false
  [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]] && ssh_connection=true
  current_port="$(awk '/^#?Port /{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
  current_port="${current_port:-22}"

  while true; do
    read -r -p "Enter new SSH port [${current_port}]: " new_port
    new_port="${new_port:-$current_port}"
    validate_port "$new_port" && break
    log ERROR "Invalid port number."
  done

  SSH_PORT="$new_port"
  if [[ "$new_port" == "$current_port" ]]; then
    log INFO "SSH port unchanged."
    return 0
  fi

  backup_file /etc/ssh/sshd_config
  if [[ "$DRYRUN" == false ]]; then
    if grep -qE '^#?Port ' /etc/ssh/sshd_config; then
      sed -i "s/^#\?Port .*/Port ${new_port}/" /etc/ssh/sshd_config
    else
      printf '\nPort %s\n' "$new_port" >> /etc/ssh/sshd_config
    fi
    
    if ! sshd -t; then
      log ERROR "SSH configuration test failed. Restoring backup."
      cp "$BACKUP_DIR"/sshd_config.backup.* /etc/ssh/sshd_config
      return 1
    fi
  fi

  SSH_PORT_CHANGED=true
  if [[ "$ssh_connection" == true ]]; then
    log WARN "SSH connection detected. Service restart deferred until reboot."
    log WARN "After reboot, connect using: ssh -p ${new_port} user@server"
  else
    run_cmd systemctl restart ssh
    log SUCCESS "SSH service restarted on port $new_port."
  fi
  log SUCCESS "SSH configured to port $new_port."
}

install_endlessh() {
  local answer
  echo -e "\n${BLUE}--- Endlessh SSH Honeypot ---${NC}"
  read -r -p "Install Endlessh honeypot on port 22? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { log INFO "Skipping Endlessh."; return 0; }

  if [[ "$SSH_PORT" == "22" ]]; then
    log WARN "Cannot install Endlessh: SSH is still on port 22."
    return 0
  fi

  if ! run_cmd apt-get install -y endlessh; then
    log ERROR "Failed to install Endlessh."
    return 0
  fi
  
  if [[ "$DRYRUN" == false ]]; then
    mkdir -p /etc/endlessh
    cat > /etc/endlessh/config <<'EOF'
Port 22
Delay 10000
MaxLineLength 32
MaxClients 4096
LogLevel 1
KeepaliveTime 600
EOF
  fi
  
  run_cmd systemctl enable --now endlessh
  log SUCCESS "Endlessh installed."
}

install_essential_packages() {
  local answer
  echo -e "\n${BLUE}--- Essential System Packages ---${NC}"
  read -r -p "Install essential packages? [Y/n]: " answer
  [[ "$answer" =~ ^[Nn]$ ]] && { log INFO "Skipping essential packages."; return 0; }

  if ! run_cmd apt-get install -y sudo curl wget htop unattended-upgrades systemd-timesyncd ca-certificates gnupg lsb-release apt-transport-https; then
    log ERROR "Failed to install packages."
    return 0
  fi
  
  if [[ "$DRYRUN" == false ]]; then
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    systemctl enable --now systemd-timesyncd 2>/dev/null || true
  fi
  
  log SUCCESS "Essential packages installed."
}

install_docker() {
  local answer arch codename
  echo -e "\n${BLUE}--- Docker Container Platform ---${NC}"
  read -r -p "Install Docker? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { log INFO "Skipping Docker."; return 0; }

  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64|arm64|armhf) ;;
    *) log ERROR "Unsupported architecture: $arch"; return 0 ;;
  esac

  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  
  if ! run_cmd apt-get install -y ca-certificates curl gnupg; then
    log ERROR "Failed to install prerequisites."
    return 0
  fi
  
  if [[ "$DRYRUN" == false ]]; then
    install -m 0755 -d /etc/apt/keyrings
    
    if ! curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg; then
      log ERROR "Failed to download Docker GPG key."
      return 0
    fi
    
    if ! gpg --dry-run --quiet --import --import-options import-show /etc/apt/keyrings/docker.gpg | grep -q "9DC8 5822 9FC7 DD38 854A  E2D8 8D81 803C 0EBF CD88"; then
      log ERROR "Docker GPG key verification failed!"
      rm -f /etc/apt/keyrings/docker.gpg
      return 0
    fi
    
    chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable" > /etc/apt/sources.list.d/docker.list
  fi
  
  run_cmd apt-get update
  
  if ! run_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    log ERROR "Failed to install Docker."
    return 0
  fi
  
  run_cmd systemctl enable --now docker
  log SUCCESS "Docker installed."
}

install_motd() {
  local answer
  echo -e "\n${BLUE}--- Custom MOTD ---${NC}"
  read -r -p "Install custom MOTD? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { log INFO "Skipping MOTD."; return 0; }

  if [[ "$DRYRUN" == false ]]; then
    chmod -x /etc/update-motd.d/* 2>/dev/null || true
    
    cat > /etc/update-motd.d/99-custom-status <<'EOF'
#!/usr/bin/env bash
h="$(hostname 2>/dev/null || echo Unknown)"
v="$(cat /etc/debian_version 2>/dev/null || echo Unknown)"
ip="$(hostname -I 2>/dev/null | awk '{print $1}' || echo Unknown)"
up="$(uptime -p 2>/dev/null || echo Unknown)"
load="$(uptime 2>/dev/null | awk -F'load average: ' '{print $2}' | xargs || echo Unknown)"
disk="$(df -h / 2>/dev/null | awk 'NR==2{print $3" / "$2" ("$5")"}' || echo Unknown)"
mem="$(free -h 2>/dev/null | awk '/^Mem:/{print $3" / "$2}' || echo Unknown)"

printf '\n\033[1;32m=== System Status ===\033[0m\n'
printf '\033[1;34mHostname:\033[0m %s (Debian %s)\n' "$h" "$v"
printf '\033[1;34mIP:\033[0m %s\n' "$ip"
printf '\033[1;34mUptime:\033[0m %s\n' "$up"
printf '\033[1;34mLoad:\033[0m %s\n' "$load"
printf '\033[1;34mDisk:\033[0m %s\n' "$disk"
printf '\033[1;34mMemory:\033[0m %s\n\n' "$mem"
EOF
    chmod 0755 /etc/update-motd.d/99-custom-status
  fi
  
  log SUCCESS "MOTD installed."
}

install_update_helper() {
  local answer
  echo -e "\n${BLUE}--- Update Helper ---${NC}"
  read -r -p "Install update helper? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { log INFO "Skipping update helper."; return 0; }

  if [[ "$DRYRUN" == false ]]; then
    cat > /usr/local/bin/update.sh <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> Updating packages"
apt-get update
apt-get full-upgrade -y
apt-get autoremove -y
apt-get autoclean -y

if command -v flatpak >/dev/null 2>&1; then
  echo "==> Flatpak update"
  flatpak update -y 2>/dev/null || true
fi

if command -v docker >/dev/null 2>&1; then
  echo "==> Docker cleanup"
  docker image prune -f 2>/dev/null || true
fi

if [[ -f /var/run/reboot-required ]]; then
  echo ""
  echo "Reboot required"
fi
EOF
    chmod 0755 /usr/local/bin/update.sh
    ln -sf /usr/local/bin/update.sh /usr/local/bin/up
    ln -sf /usr/local/bin/update.sh /usr/local/bin/debian-update
  fi
  
  log SUCCESS "Update helper installed."
}

show_summary() {
  local h t l es ds
  
  h="$(hostname 2>/dev/null || echo Unknown)"
  t="$(timedatectl show --property=Timezone --value 2>/dev/null || echo Unknown)"
  l="$(locale | grep '^LANG=' | cut -d= -f2 2>/dev/null || echo Unknown)"
  
  if [[ "$DRYRUN" == false ]]; then
    es="$(systemctl is-active endlessh 2>/dev/null || echo inactive)"
    ds="$(systemctl is-active docker 2>/dev/null || echo inactive)"
  else
    es="N/A"
    ds="N/A"
  fi
  
  echo
  echo -e "${GREEN}=== Setup Complete ===${NC}"
  echo -e "${BLUE}Hostname:${NC} $h"
  echo -e "${BLUE}Timezone:${NC} $t"
  echo -e "${BLUE}Locale:${NC} $l"
  echo -e "${BLUE}SSH Port:${NC} $SSH_PORT"
  echo -e "${BLUE}Endlessh:${NC} $es"
  echo -e "${BLUE}Docker:${NC} $ds"
  echo -e "${BLUE}Log:${NC} $SCRIPT_LOG"
  echo -e "${BLUE}Backups:${NC} $BACKUP_DIR"
  
  if [[ "$SSH_PORT_CHANGED" == true ]]; then
    echo
    echo -e "${YELLOW}SSH port changed to ${SSH_PORT}${NC}"
    echo -e "${YELLOW}After reboot: ssh -p ${SSH_PORT} user@server${NC}"
  fi
  
  if [[ "$DRYRUN" == false ]]; then
    echo
    read -r -p "Reboot now? [y/N]: " rb
    if [[ "$rb" =~ ^[Yy]$ ]]; then
      log INFO "Rebooting..."
      sleep 3
      reboot
    fi
  fi
}

main() {
  echo -e "${GREEN}Debian Setup Script v2.3${NC}"
  echo
  
  [[ "$DRYRUN" == false ]] && { 
    mkdir -p "$(dirname "$SCRIPT_LOG")" "$BACKUP_DIR"
    touch "$SCRIPT_LOG"
    log INFO "Script started"
  }
  
  update_system
  configure_hostname
  configure_timezone
  configure_locale
  configure_ssh
  
  set +e
  install_endlessh
  install_essential_packages
  install_docker
  install_motd
  install_update_helper
  set -e
  
  show_summary
}

trap 'log ERROR "Interrupted"; exit 130' INT TERM
trap 'log ERROR "Failed at line $LINENO"; exit 1' ERR

parse_args "$@"
check_root
main

log SUCCESS "Complete"
