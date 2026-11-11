#!/usr/bin/env bash
# Guided Debian Server Setup Script
# Version 2.3 - Enhanced Edition
# Repository: https://github.com/Snake16547/debian-setup-script

set -Eeuo pipefail

DRYRUN=false
SCRIPT_LOG="/var/log/debian-setup.log"
BACKUP_DIR="/root/debian-setup-backups"
SSH_PORT="unknown"
SSH_PORT_CHANGED=false
LAST_BACKUP=
OPTIONAL_FAILURE=false

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
    ERROR) echo -e "${RED}[ERROR]${NC} $msg" >&2 ;;
    WARN) echo -e "${YELLOW}[WARN]${NC} $msg" ;;
    INFO) echo -e "${BLUE}[INFO]${NC} $msg" ;;
    SUCCESS) echo -e "${GREEN}[OK]${NC} $msg" ;;
    *) echo "$msg" ;;
  esac
}

run_cmd() {
  local cmd
  printf -v cmd '%q ' "$@"
  if [[ "$DRYRUN" == true ]]; then
    printf '%b %s\n' "${YELLOW}[DRY RUN]${NC}" "${cmd% }"
    return 0
  fi
  log INFO "Executing: ${cmd% }"
  "$@"
}

backup_file() {
  local file="$1"
  LAST_BACKUP=
  [[ -f "$file" ]] || return 0
  [[ "$DRYRUN" == true ]] && return 0
  mkdir -p "$BACKUP_DIR"
  LAST_BACKUP=$(mktemp "$BACKUP_DIR/$(basename "$file").backup.XXXXXXXX")
  cp -p -- "$file" "$LAST_BACKUP"
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  (( port <= 65535 ))
}

check_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    log ERROR "Run this script as root."
    exit 1
  fi
}

parse_args() {
  local arg show_help=false
  for arg in "$@"; do
    case "$arg" in
      --dry-run) DRYRUN=true; echo -e "${YELLOW}Dry run mode enabled.${NC}" ;;
      -h|--help) show_help=true ;;
      *) printf 'Unknown option: %s (see --help)\n' "$arg" >&2; exit 2 ;;
    esac
  done
  if [[ "$show_help" == true ]]; then
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
  fi
}

update_system() {
  log INFO "Updating package lists and upgrading installed packages..."
  run_cmd apt-get update
  run_cmd env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
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
  local search choice timezone timezones
  local -a matches
  timezones=$(timedatectl list-timezones)
  while true; do
    read -r -p "Enter part of your timezone (e.g. Europe or Berlin): " search
    [[ -n "$search" ]] || { log ERROR "Search term cannot be empty."; continue; }
    
    mapfile -t matches < <(awk -v term="$search" 'index(tolower($0), tolower(term)) { print; if (++n == 20) exit }' <<< "$timezones")
    (( ${#matches[@]} > 0 )) || { log ERROR "No matching timezones found."; continue; }
    
    echo "Matching timezones:"
    local i=1
    for timezone in "${matches[@]}"; do
      echo "$i) $timezone"
      ((i++))
    done
    
    read -r -p "Select timezone number: " choice
    if [[ "$choice" =~ ^[1-9][0-9]?$ ]] && (( choice >= 1 && choice <= ${#matches[@]} )); then
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
  local -a matches
  if [[ ! -r /usr/share/i18n/SUPPORTED ]]; then
    if [[ "$DRYRUN" == true ]]; then
      log WARN "Locale selection requires the locales package. A live run would install it."
      return 0
    fi
    run_cmd apt-get install -y locales
  fi
  if [[ ! -r /usr/share/i18n/SUPPORTED ]]; then
    log ERROR "Cannot read /usr/share/i18n/SUPPORTED."
    return 1
  fi
  while true; do
    read -r -p "Enter part of your preferred locale (e.g. en or de): " search
    [[ -n "$search" ]] || { log ERROR "Search term cannot be empty."; continue; }
    
    mapfile -t matches < <(awk -v term="$search" '$2 == "UTF-8" && index(tolower($1), tolower(term)) { print $1; if (++n == 20) exit }' /usr/share/i18n/SUPPORTED)
    (( ${#matches[@]} > 0 )) || { log ERROR "No matching UTF-8 locales found."; continue; }
    
    echo "Matching locales:"
    local i=1
    for locale in "${matches[@]}"; do
      echo "$i) $locale"
      ((i++))
    done
    
    read -r -p "Select locale number: " choice
    if [[ "$choice" =~ ^[1-9][0-9]?$ ]] && (( choice >= 1 && choice <= ${#matches[@]} )); then
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
  local config=/etc/ssh/sshd_config effective current_port new_port backup candidate staged sockets
  if ! command -v sshd >/dev/null || [[ ! -f "$config" ]]; then
    log WARN "OpenSSH server configuration unavailable. Skipping SSH changes."
    return 0
  fi

  effective=$(sshd -T)
  current_port=$(awk '$1 == "port" { print $2; exit }' <<< "$effective")
  SSH_PORT="$current_port"

  while true; do
    read -r -p "Add an SSH port [Enter to keep current ports]: " new_port
    [[ -n "$new_port" ]] || return 0
    validate_port "$new_port" && break
    log ERROR "Enter a decimal port from 1 to 65535 without leading zeros."
  done

  if grep -Fxq "port $new_port" <<< "$effective"; then
    log INFO "SSH already has port $new_port configured."
    return 0
  fi

  if [[ "$DRYRUN" == true ]]; then
    log INFO "Would add SSH port $new_port and retain all existing ports."
    return 0
  fi

  if systemctl is-active --quiet ssh.socket || systemctl is-enabled --quiet ssh.socket; then
    log ERROR "SSH uses socket activation. Configure the listener through ssh.socket."
    return 1
  fi
  if ! systemctl is-active --quiet ssh || [[ -L "$config" ]]; then
    log ERROR "An active ssh.service and a regular sshd_config are required."
    return 1
  fi

  # OpenSSH omits its implicit port 22 once any explicit Port is set.
  # Preserve every existing listener and keep directives above any Match block.
  backup_file "$config"
  backup="$LAST_BACKUP"
  candidate=$(mktemp "${config}.setup.XXXXXXXX")
  if ! {
    printf '# Port added by debian-setup; existing listeners retained\nPort %s\n' "$new_port"
    cat "$backup"
  } > "$candidate" || ! staged=$(sshd -T -f "$candidate"); then
    rm -f -- "$candidate"
    log ERROR "Could not validate the staged SSH configuration."
    return 1
  fi

  if grep -Fxq 'port 22' <<< "$effective" && ! grep -Fxq 'port 22' <<< "$staged"; then
    if ! {
      printf 'Port 22\nPort %s\n' "$new_port"
      cat "$backup"
    } > "$candidate" || ! staged=$(sshd -T -f "$candidate"); then
      rm -f -- "$candidate"
      log ERROR "Could not preserve the existing SSH port 22."
      return 1
    fi
  fi

  local listener
  while IFS= read -r listener; do
    if ! grep -Fxq "$listener" <<< "$staged"; then
      rm -f -- "$candidate"
      log ERROR "The staged configuration would remove an existing SSH listener."
      return 1
    fi
  done < <(awk '$1 == "listenaddress"' <<< "$effective")

  if ! awk -v port="$new_port" '$1 == "listenaddress" && $2 ~ (":" port "$") { found=1 } END { exit !found }' <<< "$staged" ||
     ! sshd -t -f "$candidate"; then
    rm -f -- "$candidate"
    log ERROR "SSH cannot listen on port $new_port with the current configuration."
    return 1
  fi
  if ! sockets=$(ss -H -ltn "sport = :$new_port") || [[ -n "$sockets" ]]; then
    rm -f -- "$candidate"
    log ERROR "Cannot confirm TCP port $new_port is available."
    return 1
  fi

  chmod --reference="$backup" "$candidate"
  chown --reference="$backup" "$candidate"
  mv -f -- "$candidate" "$config"
  if ! systemctl reload ssh || ! wait_for_ssh_listener "$new_port"; then
    log ERROR "SSH did not start listening on port $new_port. Restoring $backup."
    if ! cp -p -- "$backup" "$candidate" || ! mv -f -- "$candidate" "$config" ||
       ! systemctl reload ssh; then
      log ERROR "Automatic SSH recovery failed. Restore $backup from the server console."
    fi
    return 1
  fi

  SSH_PORT="$new_port"
  SSH_PORT_CHANGED=true
  log SUCCESS "SSH is listening on port $new_port. Existing listeners were retained."
  log WARN "Open a second session with ssh -p $new_port user@server before retiring any old port."
}

wait_for_ssh_listener() {
  local port="$1" attempt
  # Reload can return before sshd has reopened its listening sockets.
  for ((attempt=0; attempt<20; attempt++)); do
    if ss -H -ltnp "sport = :$port" | awk '/"sshd"/ { found=1 } END { exit !found }'; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

install_endlessh() {
  local answer
  echo -e "\n${BLUE}--- Endlessh SSH Honeypot ---${NC}"
  read -r -p "Install Endlessh honeypot on port 22? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { log INFO "Skipping Endlessh."; return 0; }

  local effective sockets
  if ! effective=$(sshd -T) || ! sockets=$(ss -H -ltn 'sport = :22'); then
    log WARN "Cannot verify the SSH configuration. Skipping Endlessh."
    return 0
  fi
  if grep -Fxq 'port 22' <<< "$effective" ||
     awk '$1 == "listenaddress" && $2 ~ /:22$/ { found=1 } END { exit !found }' <<< "$effective" ||
     [[ -n "$sockets" ]]; then
    log WARN "TCP port 22 is configured for SSH or already in use. Skipping Endlessh."
    return 0
  fi

  if ! run_cmd apt-get install -y endlessh; then
    log ERROR "Failed to install Endlessh."
    OPTIONAL_FAILURE=true
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
  
  run_cmd systemctl enable endlessh
  run_cmd systemctl restart endlessh
  log SUCCESS "Endlessh installed."
}

install_essential_packages() {
  local answer
  echo -e "\n${BLUE}--- Essential System Packages ---${NC}"
  read -r -p "Install essential packages? [Y/n]: " answer
  [[ "$answer" =~ ^[Nn]$ ]] && { log INFO "Skipping essential packages."; return 0; }

  if ! run_cmd apt-get install -y sudo curl wget htop unattended-upgrades systemd-timesyncd ca-certificates gnupg lsb-release apt-transport-https; then
    log ERROR "Failed to install packages."
    OPTIONAL_FAILURE=true
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

install_docker_key() (
  local key_dir fingerprints
  install -m 0755 -d /etc/apt/keyrings || return 1
  key_dir=$(mktemp -d /etc/apt/keyrings/.docker.XXXXXXXX) || return 1
  trap 'rm -rf -- "$key_dir"' EXIT
  mkdir -m 0700 "$key_dir/gnupg" || return 1

  curl -fsSL https://download.docker.com/linux/debian/gpg -o "$key_dir/docker.asc" || return 1
  fingerprints=$(gpg --no-options --batch --homedir "$key_dir/gnupg" --with-colons --show-keys "$key_dir/docker.asc" |
    awk -F: '$1 == "pub" { primary=1 } $1 == "fpr" && primary { print $10; primary=0 }') || return 1
  if [[ "$fingerprints" != "9DC858229FC7DD38854AE2D88D81803C0EBFCD88" ]]; then
    log ERROR "Docker GPG key verification failed."
    return 1
  fi

  gpg --no-options --batch --homedir "$key_dir/gnupg" --dearmor -o "$key_dir/docker.gpg" "$key_dir/docker.asc" &&
    chmod 0644 "$key_dir/docker.gpg" &&
    mv -f -- "$key_dir/docker.gpg" /etc/apt/keyrings/docker.gpg
)

install_docker() {
  local answer arch codename
  echo -e "\n${BLUE}--- Docker Container Platform ---${NC}"
  read -r -p "Install Docker? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || { log INFO "Skipping Docker."; return 0; }

  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64|arm64|armhf) ;;
    *) log ERROR "Unsupported architecture: $arch"; OPTIONAL_FAILURE=true; return 0 ;;
  esac

  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  
  if ! run_cmd apt-get install -y ca-certificates curl gnupg; then
    log ERROR "Failed to install prerequisites."
    OPTIONAL_FAILURE=true
    return 0
  fi
  
  if [[ "$DRYRUN" == false ]]; then
    if ! install_docker_key; then
      log ERROR "Could not install the verified Docker signing key."
      OPTIONAL_FAILURE=true
      return 0
    fi
    echo "deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian ${codename} stable" > /etc/apt/sources.list.d/docker.list
  fi
  
  run_cmd apt-get update
  
  if ! run_cmd apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
    log ERROR "Failed to install Docker."
    OPTIONAL_FAILURE=true
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
  if [[ "$DRYRUN" == true ]]; then
    echo -e "${GREEN}=== Dry Run Complete ===${NC}"
  elif [[ "$OPTIONAL_FAILURE" == true ]]; then
    echo -e "${YELLOW}=== Setup Finished with Errors ===${NC}"
  else
    echo -e "${GREEN}=== Setup Complete ===${NC}"
  fi
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
    echo -e "${YELLOW}SSH port ${SSH_PORT} added${NC}"
    echo -e "${YELLOW}From a second session: ssh -p ${SSH_PORT} user@server${NC}"
  fi
  
  if [[ "$DRYRUN" == false && "$OPTIONAL_FAILURE" == false ]]; then
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
  
  install_endlessh
  install_essential_packages
  install_docker
  install_motd
  install_update_helper
  
  show_summary
}

trap 'log ERROR "Interrupted"; exit 130' INT TERM
trap 'log ERROR "Failed at line $LINENO"; exit 1' ERR

parse_args "$@"
check_root
main

if [[ "$OPTIONAL_FAILURE" == true ]]; then
  exit 1
fi
log SUCCESS "Complete"
