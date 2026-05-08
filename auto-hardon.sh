#!/bin/bash

set -e

echo "=== Kali Hardening Script ==="

# --- Update system ---
read -p "Update system packages? (y/n): " update_choice
if [[ "$update_choice" =~ ^[Yy]$ ]]; then
    apt update && apt full-upgrade -y
fi

# --- Password update ---
read -p "Update current user password? (y/n): " pass_choice
if [[ "$pass_choice" =~ ^[Yy]$ ]]; then
    passwd
fi

# --- Install security tools ---
read -p "Install basic hardening tools (ufw, fail2ban, unattended-upgrades)? (y/n): " tools_choice
if [[ "$tools_choice" =~ ^[Yy]$ ]]; then
    apt install -y ufw fail2ban unattended-upgrades
fi

# --- Firewall setup ---
read -p "Enable UFW firewall with default deny incoming? (y/n): " ufw_choice
if [[ "$ufw_choice" =~ ^[Yy]$ ]]; then
    ufw default deny incoming
    ufw default allow outgoing
    ufw enable
fi

# --- SSH handling ---
read -p "Do you need SSH on this system? (y/n): " ssh_needed
if [[ "$ssh_needed" =~ ^[Yy]$ ]]; then
    echo "Hardening SSH..."

    # Backup config
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak

    # Disable root login
    sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

    # Disable password auth (optional prompt)
    read -p "Disable SSH password auth (key-only)? (y/n): " key_only
    if [[ "$key_only" =~ ^[Yy]$ ]]; then
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    fi

    systemctl restart ssh
    systemctl enable ssh

else
    echo "Removing SSH completely..."
    systemctl stop ssh || true
    apt purge -y openssh-server
    apt autoremove -y
fi

# --- Disable unnecessary services ---
read -p "Disable unnecessary services (avahi, cups, etc.)? (y/n): " svc_choice
if [[ "$svc_choice" =~ ^[Yy]$ ]]; then
    systemctl disable avahi-daemon 2>/dev/null || true
    systemctl disable cups 2>/dev/null || true
    systemctl disable bluetooth 2>/dev/null || true
fi

# --- Fail2ban ---
if systemctl list-unit-files | grep -q fail2ban; then
    read -p "Enable fail2ban? (y/n): " f2b_choice
    if [[ "$f2b_choice" =~ ^[Yy]$ ]]; then
        systemctl enable fail2ban
        systemctl start fail2ban
    fi
fi

# --- Auto updates ---
if systemctl list-unit-files | grep -q unattended-upgrades; then
    read -p "Enable automatic security updates? (y/n): " auto_choice
    if [[ "$auto_choice" =~ ^[Yy]$ ]]; then
        dpkg-reconfigure --priority=low unattended-upgrades
    fi
fi

echo "=== Hardening Complete ==="
