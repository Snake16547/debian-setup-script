# 🚀 Debian Server Setup Script

[![License: GPL-3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](https://opensource.org/licenses/GPL-3.0)
[![Shell Script](https://img.shields.io/badge/Shell-Bash-green.svg)](https://www.gnu.org/software/bash/)
[![Debian](https://img.shields.io/badge/OS-Debian%2011%2B-red.svg)](https://www.debian.org/)

A comprehensive, interactive Debian server setup script with enhanced security, error handling, and safety features. Perfect for quickly configuring new servers with essential packages, security hardening, and Docker installation.

## ✨ Features

**Core Configuration**
- ✅ Interactive hostname setup with `/etc/hosts` management
- ✅ Timezone configuration with intelligent filtering
- ✅ Locale setup with UTF-8 validation
- ✅ Add an SSH listener while retaining existing ports

**Security & Hardening**
- ✅ Endlessh SSH honeypot installation (optional)
- ✅ SSH configuration validation before applying changes
- ✅ Automatic security updates via unattended-upgrades
- ✅ SSH configuration rollback if the new listener fails

**Package Management**
- ✅ Essential packages (sudo, curl, wget, htop, systemd-timesyncd)
- ✅ Docker CE with official repository and GPG verification
- ✅ Architecture detection (amd64, arm64, armhf)
- ✅ Modern Docker Compose plugin included

**Safety & Reliability**
- ✅ Comprehensive logging to `/var/log/debian-setup.log`
- ✅ Automatic backups of modified configuration files
- ✅ Dry run mode for testing without changes
- ✅ Error handling with graceful failure recovery
- ✅ Existing SSH listeners retained during port migration

**User Experience**
- ✅ Color-coded output for better readability
- ✅ Enhanced MOTD script with system status
- ✅ Update helper utility (commands: `up`, `update.sh`, `debian-update`)
- ✅ Progress indicators and clear status messages

## 🚀 Usage

### One-Line Installation

```bash
wget https://raw.githubusercontent.com/Snake16547/debian-setup-script/main/debian-setup.sh && chmod +x debian-setup.sh && ./debian-setup.sh
```

### Test First (Recommended)

```bash
wget https://raw.githubusercontent.com/Snake16547/debian-setup-script/main/debian-setup.sh && chmod +x debian-setup.sh && ./debian-setup.sh --dry-run
```

## 📋 Options

```bash
./debian-setup.sh [--dry-run]

Options:
  --dry-run    Preview changes. Locale selection is skipped if locales is missing.
  --help, -h   Show help message and exit
```

## 🔧 What Gets Configured

**System Settings**
- Hostname and `/etc/hosts` configuration
- Timezone setup with interactive selection
- Locale configuration (UTF-8 locales only)
- System package updates and upgrades

**Security Configuration**
- Optional additional SSH listening port
- Optional Endlessh honeypot on port 22
- Automatic security updates configuration
- Essential security packages installation

**Optional Components**
- Docker CE with official repository setup
- Docker Compose plugin and build tools
- Enhanced system status MOTD script
- System update helper utility

## 🛡️ Safety Features

### SSH Protection

The script adds the requested port while keeping existing SSH listeners. It validates the staged configuration, reloads `ssh.service`, and restores the exact backup if the new listener fails to start. It leaves socket-activated SSH configurations for manual setup.

Open the new TCP port in your host and provider firewalls, keep your current session open, and test a second connection from your client:

```bash
ssh -p 2222 user@server
```

After verifying the second connection, you can retire the old SSH listener manually. Endlessh is skipped while port 22 is configured for SSH or another process is listening there. You can rerun setup after freeing port 22.

### Error Handling

- **Strict error checking**: Script stops on critical failures
- **Comprehensive logging**: All operations logged with timestamps
- **File backups**: Original configurations saved to `/root/debian-setup-backups`
- **Graceful degradation**: Continues when possible, fails safely when not

## 📊 Example Output

```bash
Debian Setup Script v2.3

[INFO] Updating package lists and upgrading installed packages...
[OK] System packages updated.

Enter the desired hostname: myserver
[OK] Hostname set to myserver.

Enter part of your timezone (e.g. Europe or Berlin): europe
Matching timezones:
1) Europe/London
2) Europe/Berlin
3) Europe/Paris
Select timezone number: 2
[OK] Timezone set to Europe/Berlin.

[OK] SSH is listening on port 2222. Existing listeners were retained.
[WARN] Open a second session with ssh -p 2222 user@server before retiring any old port.

=== Setup Complete ===
Hostname: myserver
Timezone: Europe/Berlin
SSH Port: 2222
Docker: active
Log: /var/log/debian-setup.log
```

## 📝 Interactive Prompts

The script will ask for your preferences on:

1. **Hostname**: Server identification
2. **Timezone**: Geographic location for time settings
3. **Locale**: Language and character encoding
4. **SSH Port**: Add a listener and retain the existing ports
5. **Endlessh**: SSH honeypot installation when TCP port 22 is free
6. **Packages**: Essential system tools
7. **Docker**: Container platform installation
8. **MOTD**: System status display script
9. **Update Helper**: Convenient update commands

## 🗂️ File Locations

```bash
/var/log/debian-setup.log              # Execution log
/root/debian-setup-backups/            # Configuration backups
/etc/update-motd.d/99-custom-status    # MOTD script
/etc/endlessh/config                   # Endlessh configuration
/etc/apt/apt.conf.d/20auto-upgrades    # Auto-update settings
/usr/local/bin/update.sh               # Update helper (also: up, debian-update)
```

## 🐛 Troubleshooting

### Common Issues

**Script fails with permission error**
```bash
# Solution: Run as root
sudo ./debian-setup.sh
```

**Docker installation fails**

Docker publishes its own list of [supported Debian versions](https://docs.docker.com/engine/install/debian/#os-requirements). The base setup and the optional Docker repository have separate version requirements.
```bash
# Check architecture support
dpkg --print-architecture
# Supported: amd64, arm64, armhf
```

**Locale not found**
```bash
# Check available locales
cat /usr/share/i18n/SUPPORTED | grep -i en_US
```

### Log Analysis

```bash
# View full execution log
sudo tail -f /var/log/debian-setup.log

# Check for errors
sudo grep ERROR /var/log/debian-setup.log

# View configuration backups
ls -la /root/debian-setup-backups/
```

## 🤝 Contributing

Contributions are welcome! Here's how:

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Test your changes with `--dry-run`
4. Commit your changes (`git commit -m 'Add amazing feature'`)
5. Push to the branch (`git push origin feature/amazing-feature`)
6. Open a Pull Request

## 📄 License

This project is licensed under the GPL-3.0 License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- Original concept and development by [Snake16547](https://github.com/Snake16547)
- Enhanced with security improvements and error handling
- Inspired by best practices from the Debian community
- Built for system administrators who value reliability and security

## 🔗 Links

- [Docker Official Documentation](https://docs.docker.com/)
- [Debian Administrator's Handbook](https://debian-handbook.info/)
- [SSH Security Best Practices](https://www.ssh.com/academy/ssh/security)
- [Endlessh - SSH Tarpit](https://github.com/skeeto/endlessh)

---

**Made with ❤️ for the Debian community**

> 💡 **Pro Tip**: Always test with `--dry-run` first, especially on production servers!
