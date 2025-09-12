#!/bin/bash

# Improved Guided Debian Server Setup Script with Enhanced Security and Error Handling
# Version: 2.0

set -euo pipefail  # Exit on error, undefined vars, and pipe failures

# Global variables
DRY_RUN=false
SCRIPT_LOG="/var/log/debian-setup.log"
BACKUP_DIR="/root/debian-setup-backups"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    if ! $DRY_RUN; then
        echo "[$timestamp] [$level] $message" | tee -a "$SCRIPT_LOG"
    fi
    
    case $level in
        "ERROR") echo -e "${RED}[ERROR]${NC} $message" ;;
        "WARN")  echo -e "${YELLOW}[WARN]${NC} $message" ;;
        "INFO")  echo -e "${BLUE}[INFO]${NC} $message" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $message" ;;
    esac
}

# Enhanced command execution with error handling
run_cmd() {
    local cmd="$*"
    
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY RUN]${NC} $cmd"
        return 0
    fi
    
    log "INFO" "Executing: $cmd"
    
    if eval "$cmd"; then
        log "SUCCESS" "Command executed successfully: $cmd"
        return 0
    else
        local exit_code=$?
        log "ERROR" "Command failed with exit code $exit_code: $cmd"
        return $exit_code
    fi
}

# Safe file backup function
backup_file() {
    local file="$1"
    local backup_name="${file##*/}.backup.$(date +%s)"
    
    if [[ -f "$file" ]] && ! $DRY_RUN; then
        mkdir -p "$BACKUP_DIR"
        cp "$file" "$BACKUP_DIR/$backup_name"
        log "INFO" "Backed up $file to $BACKUP_DIR/$backup_name"
    fi
}

# Validate port number
validate_port() {
    local port="$1"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        return 1
    fi
    # Warn about well-known ports
    if [ "$port" -lt 1024 ] && [ "$port" -ne 22 ]; then
        echo -e "${YELLOW}Warning: Port $port is a well-known port and may conflict with other services.${NC}"
    fi
    return 0
}

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log "ERROR" "This script must be run as root."
        exit 1
    fi
}

# Parse command line arguments
parse_args() {
    for arg in "$@"; do
        case "$arg" in
            --dry-run)
                DRY_RUN=true
                echo -e "${YELLOW}Dry run mode enabled. No commands will be executed.${NC}"
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
        esac
    done
}

show_help() {
    cat << EOF
Debian Server Setup Script v2.0

Usage: $0 [OPTIONS]

Options:
  --dry-run    Show what would be executed without making changes
  --help, -h   Show this help message

Features:
  - Interactive hostname, timezone, locale, and SSH port configuration
  - Optional Endlessh SSH honeypot installation
  - Essential packages installation with unattended upgrades
  - Optional Docker installation with architecture detection
  - System status MOTD script
  - Comprehensive logging and error handling
  - Configuration file backups

EOF
}

# System update with error handling
update_system() {
    log "INFO" "Updating package lists and upgrading installed packages..."
    
    run_cmd "apt-get update" || {
        log "ERROR" "Failed to update package lists"
        return 1
    }
    
    run_cmd "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y" || {
        log "ERROR" "Failed to upgrade packages"
        return 1
    }
    
    log "SUCCESS" "System update and upgrade complete"
}

# Configure hostname
configure_hostname() {
    local hostname
    
    while true; do
        read -p "Enter the desired hostname: " hostname
        
        # Validate hostname format
        if [[ -n "$hostname" ]] && [[ "$hostname" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]]; then
            backup_file "/etc/hostname"
            backup_file "/etc/hosts"
            
            run_cmd "hostnamectl set-hostname '$hostname'"
            
            # Update /etc/hosts more safely
            if ! $DRY_RUN; then
                if grep -q "^127.0.1.1" /etc/hosts; then
                    sed -i "s/^127.0.1.1.*/127.0.1.1 $hostname/" /etc/hosts
                else
                    echo "127.0.1.1 $hostname" >> /etc/hosts
                fi
            else
                echo -e "${YELLOW}[DRY RUN]${NC} Would update /etc/hosts with hostname $hostname"
            fi
            
            log "SUCCESS" "Hostname set to $hostname"
            break
        else
            log "ERROR" "Invalid hostname. Must be 1-63 characters, alphanumeric and hyphens only, cannot start/end with hyphen."
        fi
    done
}

# Configure timezone
configure_timezone() {
    local tz_search matching_timezones timezone tz_number
    
    while true; do
        read -p "Enter part of your timezone (e.g., 'Europe' or 'Berlin'): " tz_search
        
        if [[ -z "$tz_search" ]]; then
            log "ERROR" "Timezone search term cannot be empty"
            continue
        fi
        
        mapfile -t matching_timezones < <(timedatectl list-timezones | grep -i "$tz_search")
        
        if [ ${#matching_timezones[@]} -eq 0 ]; then
            log "ERROR" "No matching timezones found for '$tz_search'. Try again."
            continue
        fi

        echo "Matching timezones:"
        for i in "${!matching_timezones[@]}"; do
            echo "$((i+1))) ${matching_timezones[i]}"
        done

        read -p "Enter the number of your desired timezone: " tz_number
        
        if [[ "$tz_number" =~ ^[0-9]+$ ]] && [ "$tz_number" -ge 1 ] && [ "$tz_number" -le "${#matching_timezones[@]}" ]; then
            timezone="${matching_timezones[$((tz_number-1))]}"
            run_cmd "timedatectl set-timezone '$timezone'"
            log "SUCCESS" "Timezone set to $timezone"
            break
        else
            log "ERROR" "Invalid selection. Please enter a number between 1 and ${#matching_timezones[@]}"
        fi
    done
}

# Configure locale
configure_locale() {
    local locale_search matching_locales locale locale_number
    
    while true; do
        read -p "Enter part of your preferred locale (e.g., 'en' or 'de'): " locale_search
        
        if [[ -z "$locale_search" ]]; then
            log "ERROR" "Locale search term cannot be empty"
            continue
        fi
        
        # Get available locales from /usr/share/i18n/SUPPORTED instead of locale -a
        if [[ -f "/usr/share/i18n/SUPPORTED" ]]; then
            mapfile -t matching_locales < <(grep -i "$locale_search" /usr/share/i18n/SUPPORTED | grep -E 'UTF-8' | cut -d' ' -f1)
        else
            mapfile -t matching_locales < <(locale -a | grep -i "$locale_search" | grep -E 'utf8|UTF-8')
        fi

        if [ ${#matching_locales[@]} -eq 0 ]; then
            log "ERROR" "No matching UTF-8 locales found for '$locale_search'. Try again."
            continue
        fi

        echo "Matching locales:"
        for i in "${!matching_locales[@]}"; do
            echo "$((i+1))) ${matching_locales[i]}"
        done

        read -p "Enter the number of your desired locale: " locale_number
        
        if [[ "$locale_number" =~ ^[0-9]+$ ]] && [ "$locale_number" -ge 1 ] && [ "$locale_number" -le "${#matching_locales[@]}" ]; then
            locale="${matching_locales[$((locale_number-1))]}"
            
            backup_file "/etc/locale.gen"
            
            # Ensure locale exists in locale.gen and uncomment it
            if ! $DRY_RUN; then
                if ! grep -q "^$locale" /etc/locale.gen; then
                    if grep -q "^# *$locale" /etc/locale.gen; then
                        sed -i "s/^# *$locale UTF-8/$locale UTF-8/" /etc/locale.gen
                    else
                        echo "$locale UTF-8" >> /etc/locale.gen
                    fi
                fi
            fi
            
            run_cmd "locale-gen"
            run_cmd "update-locale LANG=$locale"
            log "SUCCESS" "Locale set to $locale"
            break
        else
            log "ERROR" "Invalid selection. Please enter a number between 1 and ${#matching_locales[@]}"
        fi
    done
}

# Configure SSH
configure_ssh() {
    local ssh_port current_port connection_check
    
    # Detect if we're running over SSH
    if [[ -n "${SSH_CONNECTION:-}" ]] || [[ -n "${SSH_CLIENT:-}" ]] || [[ "$XDG_SESSION_TYPE" == "tty" && -n "$(who am i | grep pts)" ]]; then
        connection_check=true
        log "WARN" "SSH connection detected. SSH service restart will be deferred to prevent disconnection."
    else
        connection_check=false
    fi
    
    current_port=$(grep -E '^Port|^#Port' /etc/ssh/sshd_config | head -1 | awk '{print $2}' 2>/dev/null || echo '22')
    
    while true; do
        read -p "Enter new SSH port (default: 22, current: $current_port): " ssh_port
        ssh_port=${ssh_port:-22}
        
        if validate_port "$ssh_port"; then
            break
        else
            log "ERROR" "Invalid port number. Please enter a number between 1 and 65535."
        fi
    done
    
    # If port unchanged, skip configuration
    if [[ "$ssh_port" == "$current_port" ]]; then
        log "INFO" "SSH port unchanged ($ssh_port). Skipping SSH configuration."
        return 0
    fi
    
    backup_file "/etc/ssh/sshd_config"
    
    if ! $DRY_RUN; then
        # Handle both commented and uncommented Port lines
        if grep -q "^Port " /etc/ssh/sshd_config; then
            sed -i "s/^Port .*/Port $ssh_port/" /etc/ssh/sshd_config
        elif grep -q "^#Port " /etc/ssh/sshd_config; then
            sed -i "s/^#Port .*/Port $ssh_port/" /etc/ssh/sshd_config
        else
            echo "Port $ssh_port" >> /etc/ssh/sshd_config
        fi
        
        # Test SSH configuration
        if ! sshd -t; then
            log "ERROR" "SSH configuration test failed. Restoring backup."
            if [[ -f "$BACKUP_DIR/sshd_config.backup."* ]]; then
                cp "$BACKUP_DIR"/sshd_config.backup.* /etc/ssh/sshd_config
            fi
            return 1
        fi
        
        if $connection_check; then
            log "WARN" "SSH configuration updated but service restart deferred."
            log "WARN" "After reboot, SSH will be available on port $ssh_port"
            log "WARN" "To apply immediately: run 'systemctl restart ssh' (may disconnect you)"
        else
            # Safe to restart SSH service
            if systemctl is-active --quiet ssh; then
                log "INFO" "Restarting SSH service to apply port change..."
                systemctl restart ssh
                sleep 2
                
                # Verify SSH is running on new port
                if ss -tlnp | grep -q ":$ssh_port "; then
                    log "SUCCESS" "SSH service restarted successfully on port $ssh_port"
                else
                    log "ERROR" "SSH service may not be listening on port $ssh_port"
                fi
            fi
        fi
    else
        echo -e "${YELLOW}[DRY RUN]${NC} Would set SSH port to $ssh_port"
        if $connection_check; then
            echo -e "${YELLOW}[DRY RUN]${NC} SSH restart would be deferred due to active SSH connection"
        else
            echo -e "${YELLOW}[DRY RUN]${NC} Would restart SSH service immediately"
        fi
    fi
    
    log "SUCCESS" "SSH port configured to $ssh_port"
}

# Install Endlessh
install_endlessh() {
    local install_endlessh
    
    read -p "Would you like to install Endlessh as SSH honeypot on port 22? (y/n): " install_endlessh
    
    if [[ "$install_endlessh" =~ ^[Yy]$ ]]; then
        log "INFO" "Installing Endlessh..."
        
        run_cmd "apt install -y endlessh" || {
            log "ERROR" "Failed to install Endlessh"
            return 1
        }

        # Create config directory if it doesn't exist
        run_cmd "mkdir -p /etc/endlessh"
        
        if ! $DRY_RUN; then
            cat > /etc/endlessh/config <<EOF
# Endlessh SSH honeypot configuration
Port 22
Delay 10000
MaxLineLength 32
MaxClients 4096
LogLevel 1
KeepaliveTime 3600
EOF
        else
            echo -e "${YELLOW}[DRY RUN]${NC} Would write Endlessh config to /etc/endlessh/config"
        fi

        run_cmd "systemctl enable endlessh"
        run_cmd "systemctl start endlessh"
        log "SUCCESS" "Endlessh installed and configured"
        return 0
    fi
    
    return 1
}

# Install essential packages
install_essential_packages() {
    local install_packages
    
    read -p "Install essential system packages (sudo, curl, wget, ntp, htop, unattended-upgrades)? (y/n): " install_packages
    
    if [[ "$install_packages" =~ ^[Yy]$ ]]; then
        log "INFO" "Installing essential packages..."
        
        run_cmd "DEBIAN_FRONTEND=noninteractive apt install -y sudo curl wget ntp htop unattended-upgrades apt-transport-https ca-certificates gnupg lsb-release" || {
            log "ERROR" "Failed to install essential packages"
            return 1
        }
        
        # Configure unattended upgrades
        if ! $DRY_RUN; then
            if [[ ! -f "/etc/apt/apt.conf.d/20auto-upgrades" ]]; then
                cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
            fi
        else
            echo -e "${YELLOW}[DRY RUN]${NC} Would configure unattended upgrades"
        fi
        
        log "SUCCESS" "Essential packages installed and configured"
        return 0
    fi
    
    return 1
}

# Install Docker
install_docker() {
    local install_docker arch
    
    read -p "Would you like to install Docker? (y/n): " install_docker
    
    if [[ ! "$install_docker" =~ ^[Yy]$ ]]; then
        return 1
    fi
    
    arch=$(dpkg --print-architecture)
    
    if [[ ! "$arch" =~ ^(amd64|arm64|armhf)$ ]]; then
        log "ERROR" "Unsupported architecture: $arch. Docker installation skipped."
        return 1
    fi
    
    log "INFO" "Installing Docker for architecture: $arch"
    
    # Add Docker's official GPG key with verification
    if ! $DRY_RUN; then
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
        
        # Verify GPG key fingerprint (Docker's official fingerprint)
        if ! gpg --dry-run --quiet --import --import-options import-show /usr/share/keyrings/docker-archive-keyring.gpg | grep -q "9DC8 5822 9FC7 DD38 854A  E2D8 8D81 803C 0EBF CD88"; then
            log "ERROR" "Docker GPG key verification failed"
            return 1
        fi
    else
        echo -e "${YELLOW}[DRY RUN]${NC} Would download and verify Docker GPG key"
    fi

    # Add Docker repository
    if ! $DRY_RUN; then
        echo "deb [arch=$arch signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt update
    else
        echo -e "${YELLOW}[DRY RUN]${NC} Would add Docker repository and update package lists"
    fi

    run_cmd "apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin" || {
        log "ERROR" "Failed to install Docker"
        return 1
    }
    
    run_cmd "systemctl enable docker"
    run_cmd "systemctl start docker"
    
    log "SUCCESS" "Docker installed and started"
    return 0
}

# Install MOTD script
install_motd() {
    local install_motd
    
    echo -e "${BLUE}--- System Status MOTD Script ---${NC}"
    read -p "Would you like to install a system status MOTD script? (y/n): " install_motd
    
    if [[ "$install_motd" =~ ^[Yy]$ ]]; then
        if ! $DRY_RUN; then
            cat > /etc/profile.d/motd.sh <<'EOF'
#!/bin/bash

# Check if running interactively
[[ $- == *i* ]] || return

# Get system information
hostname=$(hostname)
debian_version=$(cat /etc/debian_version 2>/dev/null || echo "Unknown")
ip_address=$(hostname -I 2>/dev/null | cut -d ' ' -f 1 || echo "Unknown")
uptime=$(uptime -p 2>/dev/null || echo "Unknown")
current_time=$(date +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "Unknown")
load_avg=$(uptime | awk -F'load average:' '{print $2}' | xargs 2>/dev/null || echo "Unknown")

# Disk usage with error handling
if command -v df >/dev/null 2>&1; then
    disk_usage=$(df -h / 2>/dev/null | awk 'NR==2 {print "Used: "$3"/"$2" ("$5")"}' || echo "Unknown")
else
    disk_usage="Unknown"
fi

# Memory usage
if command -v free >/dev/null 2>&1; then
    memory_usage=$(free -h | awk '/^Mem:/ {print "Used: "$3"/"$2" ("int($3/$2*100)"%)"}' 2>/dev/null || echo "Unknown")
else
    memory_usage="Unknown"
fi

echo -e "\033[1;32m=== System Status ===\033[0m"
echo -e "\033[1;34mHostname:\033[0m $hostname (Debian $debian_version)"
echo -e "\033[1;34mIP Address:\033[0m $ip_address"
echo -e "\033[1;34mUptime:\033[0m $uptime"
echo -e "\033[1;34mLoad Average:\033[0m $load_avg"
echo -e "\033[1;34mCurrent Time:\033[0m $current_time"
echo -e "\033[1;34mDisk Usage:\033[0m $disk_usage"
echo -e "\033[1;34mMemory Usage:\033[0m $memory_usage"

# Show last login
if command -v last >/dev/null 2>&1; then
    last_login=$(last -n 2 -w | head -2 | tail -1 | awk '{print $1" from "$3" on "$4" "$5" "$6}' 2>/dev/null || echo "Unknown")
    echo -e "\033[1;34mLast Login:\033[0m $last_login"
fi

echo ""
EOF
            chmod +x /etc/profile.d/motd.sh
            
            # Disable default Debian MOTD
            if [[ -f "/etc/motd" ]]; then
                mv /etc/motd /etc/motd.disabled
            fi
        else
            echo -e "${YELLOW}[DRY RUN]${NC} Would install enhanced MOTD script"
        fi
        
        log "SUCCESS" "MOTD script installed"
    else
        log "INFO" "Skipping MOTD script installation"
    fi
}

# Display final summary
show_summary() {
    local hostname timezone locale ssh_port endlessh_status docker_status
    
    hostname=$(hostname 2>/dev/null || echo "Unknown")
    timezone=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Unknown")
    locale=$(locale | grep LANG= | cut -d= -f2 2>/dev/null || echo "Unknown")
    ssh_port=$(grep -E '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    
    if ! $DRY_RUN; then
        endlessh_status=$(systemctl is-active endlessh 2>/dev/null && echo "Active" || echo "Inactive")
        docker_status=$(systemctl is-active docker 2>/dev/null && echo "Active" || echo "Inactive")
    else
        endlessh_status="N/A (Dry Run)"
        docker_status="N/A (Dry Run)"
    fi
    
    echo -e "\n${GREEN}=== Setup Complete ===${NC}"
    echo -e "${BLUE}Hostname:${NC} $hostname"
    echo -e "${BLUE}Timezone:${NC} $timezone"
    echo -e "${BLUE}Locale:${NC} $locale"
    echo -e "${BLUE}SSH Port:${NC} $ssh_port"
    echo -e "${BLUE}Endlessh Status:${NC} $endlessh_status"
    echo -e "${BLUE}Docker Status:${NC} $docker_status"
    echo -e "${BLUE}Log File:${NC} $SCRIPT_LOG"
    echo -e "${BLUE}Backup Directory:${NC} $BACKUP_DIR"
}

# Main execution flow
main() {
    echo -e "${GREEN}Welcome to the Enhanced Debian Server Setup Script v2.0${NC}"
    echo "This script will configure your Debian server with improved security and error handling."
    echo ""
    
    # Initialize logging
    if ! $DRY_RUN; then
        mkdir -p "$(dirname "$SCRIPT_LOG")"
        mkdir -p "$BACKUP_DIR"
        log "INFO" "Script started by user: $(whoami)"
    fi
    
    # Main setup sequence
    update_system
    configure_hostname
    configure_timezone
    configure_locale
    configure_ssh
    install_endlessh
    install_essential_packages
    install_docker
    install_motd
    
    show_summary
    
    # SSH and reboot guidance
    local ssh_port_changed=false
    local current_ssh_port=$(grep -E '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' || echo "22")
    
    if [[ "$current_ssh_port" != "22" ]] && [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]; then
        ssh_port_changed=true
    fi
    
    if ! $DRY_RUN; then
        echo ""
        if $ssh_port_changed; then
            echo -e "${YELLOW}⚠️  IMPORTANT SSH NOTICE ⚠️${NC}"
            echo -e "${YELLOW}SSH port has been changed to $current_ssh_port but service hasn't been restarted.${NC}"
            echo -e "${YELLOW}After reboot, connect using: ssh -p $current_ssh_port user@server${NC}"
            echo -e "${YELLOW}Make sure port $current_ssh_port is open in your firewall!${NC}"
            echo ""
        fi
        
        read -p "Setup is complete. A reboot is recommended to ensure all changes take effect. Reboot now? (y/n): " reboot_now
        if [[ "$reboot_now" =~ ^[Yy]$ ]]; then
            log "INFO" "Rebooting system as requested by user"
            if $ssh_port_changed; then
                echo -e "${YELLOW}System will reboot in 10 seconds...${NC}"
                echo -e "${YELLOW}Remember to reconnect on port $current_ssh_port after reboot!${NC}"
                sleep 10
            else
                echo "Rebooting system..."
                sleep 3
            fi
            reboot
        else
            log "INFO" "Setup complete. Manual reboot recommended."
            echo -e "${YELLOW}Setup complete. Please reboot manually when convenient.${NC}"
            if $ssh_port_changed; then
                echo -e "${YELLOW}Don't forget: SSH will be on port $current_ssh_port after reboot.${NC}"
            fi
        fi
    else
        echo -e "\n${YELLOW}[DRY RUN] Setup simulation complete. No reboot needed.${NC}"
    fi
}

# Script entry point
parse_args "$@"
check_root

# Set up error handling
trap 'log "ERROR" "Script interrupted"; exit 1' INT TERM

# Run main function
main

log "SUCCESS" "Script execution completed successfully"