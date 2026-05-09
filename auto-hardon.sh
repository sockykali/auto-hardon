#!/usr/bin/env bash
# =============================================================================
#  auto-hardon.sh  —  Interactive hardening script for Kali / Debian Linux
#  Run as root. Prompts before anything potentially disruptive.
# =============================================================================

# ── Strict mode ───────────────────────────────────────────────────────────────
set -euo pipefail
trap '_err_handler "${BASH_COMMAND}" $LINENO' ERR

# ── Colors (disabled if stdout is not a TTY) ──────────────────────────────────
if [[ -t 1 ]]; then
    R='\033[0;31m'   G='\033[0;32m'   Y='\033[1;33m'  B='\033[0;34m'
    C='\033[0;36m'   M='\033[0;35m'   W='\033[1;37m'  DIM='\033[2m'
    HG='\033[1;32m'  NC='\033[0m'
else
    R='' G='' Y='' B='' C='' M='' W='' DIM='' HG='' NC=''
fi

# ── Runtime state ─────────────────────────────────────────────────────────────
DRY_RUN=false
AUTO_YES=false
SECTION_SKIP=false
LOG_FILE="/var/log/auto-hardon-$(date +%Y%m%d_%H%M%S).log"
declare -a APPLIED=()
declare -a SKIPPED=()
declare -a WARNINGS_LIST=()

# ── Help / usage ──────────────────────────────────────────────────────────────
usage() {
    cat <<EOF

${W}╔══════════════════════════════════════════════════════════════════╗
║          auto-hardon.sh  —  Linux / Kali Hardening Script        ║
╚══════════════════════════════════════════════════════════════════╝${NC}

${W}USAGE${NC}
  sudo ./auto-hardon.sh [OPTIONS]

${W}OPTIONS${NC}
  ${C}-h, --help${NC}          Show this help menu and exit
  ${C}-y, --paranoid${NC}      Auto-accept ALL prompts (non-interactive — use carefully)
  ${C}-n, --dry-run${NC}       Preview every action without making any changes
  ${C}-l, --log FILE${NC}      Write log to FILE  (default: /var/log/auto-hardon-<ts>.log)

${W}WHAT IT DOES${NC}
  ${Y}Prompts before anything potentially disruptive:${NC}
    • System package update
    • Password changes
    • Firewall enable / port rules
    • SSH removal or key-only lockdown
    • Per-service disable
    • IPv6 disable
    • Login banner
    • Optional tool installs

  ${G}Applies automatically (safe / non-destructive):${NC}
    • Kernel parameter hardening via sysctl
    • Secure default umask (027)
    • Timestamped audit log of every change

${W}OPTIONAL INSTALLS (prompted)${NC}
  ufw · fail2ban · unattended-upgrades · rkhunter · lynis · clamav

${W}EXAMPLES${NC}
  ${DIM}sudo ./auto-hardon.sh${NC}                 # Recommended — fully interactive
  ${DIM}sudo ./auto-hardon.sh --dry-run${NC}        # Preview what would change
  ${DIM}sudo ./auto-hardon.sh --paranoid${NC}        # Full auto, no prompts
  ${DIM}sudo ./auto-hardon.sh -l /tmp/audit.log${NC} # Custom log path

EOF
    exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)             usage ;;
        -y|--paranoid)         AUTO_YES=true; shift ;;
        -n|--dry-run)          DRY_RUN=true;  shift ;;
        -l|--log)     [[ -n "${2:-}" ]] || { echo "ERROR: -l requires a file path"; exit 1; }
                      LOG_FILE="$2"; shift 2 ;;
        *)            echo -e "${R}Unknown option: $1${NC}  Use -h for help."; exit 1 ;;
    esac
done

# ── Root check ────────────────────────────────────────────────────────────────
[[ "$EUID" -ne 0 ]] && { echo -e "${R}✘  This script must be run as root (sudo).${NC}"; exit 1; }

# ── Init log file ─────────────────────────────────────────────────────────────
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/auto-hardon-$(date +%Y%m%d_%H%M%S).log"
    touch "$LOG_FILE"
fi

# ── Core helpers ──────────────────────────────────────────────────────────────

_log()     { echo -e "$*" | tee -a "$LOG_FILE"; }
_info()    { _log "${C}  ℹ  $*${NC}"; }
_ok()      { _log "${G}  ✔  $*${NC}"; APPLIED+=("$*"); }
_skip()    { _log "${DIM}  ─  Skipped: $*${NC}"; SKIPPED+=("$*"); }
_warn()    { _log "${Y}  ⚠  $*${NC}"; WARNINGS_LIST+=("$*"); }
_err()     { _log "${R}  ✘  $*${NC}"; }
_section() {
    [[ "$SECTION_SKIP" == true ]] && _log "${Y}  ⚡  (section interrupted — skipped)${NC}"
    SECTION_SKIP=false
    _log "\n${B}${W}  ┌─  $*${NC}${B}  $(printf '─%.0s' {1..50})${NC}"; _log ""
}

_err_handler() {
    # Ignore failures caused by a CTRL+C interrupt — the section will be skipped.
    [[ "$SECTION_SKIP" == true ]] && return 0
    _err "Command failed: '${1:-unknown}' at line ${2:-?}"
    _err "See $LOG_FILE for details. Exiting."
    exit 1
}

_RUN_PID=""   # PID of the current background command started by run()

_sigint_handler() {
    if [[ "$SECTION_SKIP" == true ]]; then
        echo -e "\n${R}  ✘  CTRL+C — exiting.${NC}"
        exit 130
    fi
    SECTION_SKIP=true
    # Kill the current background command so wait returns immediately
    [[ -n "$_RUN_PID" ]] && kill "$_RUN_PID" 2>/dev/null || true
    echo -e "\n${Y}  ⚡  CTRL+C — skipping to next section... (press again to exit)${NC}"
}
trap '_sigint_handler' INT

# run CMD [args…]  — respects dry-run, always logs
run() {
    [[ "$SECTION_SKIP" == true ]] && return 0
    if [[ "$DRY_RUN" == true ]]; then
        _log "${DIM}    [dry-run] $*${NC}"
        return 0
    fi
    # Run in background + wait so that SIGINT always fires the INT trap
    # before bash can check the exit status and trigger the ERR trap.
    "$@" >> "$LOG_FILE" 2>&1 &
    _RUN_PID=$!
    wait "$_RUN_PID" || {
        _RUN_PID=""
        [[ "$SECTION_SKIP" == true ]] && return 0
        return 1   # real failure — ERR trap will fire
    }
    _RUN_PID=""
}

# ask "Question"  — returns 0=yes / 1=no. Respects AUTO_YES and DRY_RUN.
ask() {
    local prompt="$1"
    [[ "$SECTION_SKIP" == true ]] && return 1
    if [[ "$DRY_RUN" == true ]]; then
        _log "${DIM}  ? [dry-run]  $prompt  → skip${NC}"
        return 1
    fi
    if [[ "$AUTO_YES" == true ]]; then
        _log "${DIM}  ? [auto-yes] $prompt  → yes${NC}"
        return 0
    fi
    local yn
    while true; do
        echo -en "  ${Y}?${NC} ${W}${prompt}${NC} ${DIM}[y/N]${NC} "
        read -r yn </dev/tty || { echo; return 1; }
        case "$yn" in
            [Yy]*) return 0 ;;
            [Nn]*|"") return 1 ;;
            *) echo -e "    ${R}Please enter y or n.${NC}" ;;
        esac
    done
}

# ── Apply a sshd_config key=value safely ─────────────────────────────────────
_ssh_set() {
    local key="$1" val="$2"
    if [[ "$DRY_RUN" == true ]]; then
        _log "${DIM}    [dry-run] sshd_config: ${key} ${val}${NC}"; return
    fi
    local cfg="/etc/ssh/sshd_config"
    if grep -qP "^#?\s*${key}\b" "$cfg" 2>/dev/null; then
        sed -i "s|^#\?\s*${key}.*|${key} ${val}|" "$cfg"
    else
        echo "${key} ${val}" >> "$cfg"
    fi
    echo "    sshd_config: set ${key} = ${val}" >> "$LOG_FILE"
}

# ─────────────────────────────────────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────────────────────────────────────
     clear
     _log "${G}   ______   __  __ ______ ______       __  __ ______  ______ ______ ______  __   __  ${NC}"
     _log "${G}  /\\  __ \\ /\\ \\/\\ \\__  _/\\  __ \\     /\\ \\_\\ \\  __ \\/\\  == /\\  __ /\\  __ \\/\\ \"-.\\  \\  ${NC}"
     _log "${G}  \\ \\  __ \\\\ \\ \\_\\ \\/_/\\ \\\\ \\ \\/\\ \\   \\ \\  __ \\ \\  __ \\ \\  __\\ \\ \\/\\ \\ \\ \\/\\ \\ \\ \\-.  \\ ${NC}"
     _log "${G}   \\ \\_\\ \\_\\\\ \\_____\\ \\ \\_\\\\ \\_____\\   \\ \\_\\ \\_\\ \\_\\ \\_\\ \\_\\  \\ \\_____\\ \\_____\\ \\_\\\\\"\\_\\ ${NC}"
     _log "${G}    \\/_/\\/_/ \\/_____/  \\/_/ \\/_____/    \\/_/\\/_/\\/_/\\/_/\\/_/   \\/_____/\\/_____/\\/_/ \\/_/ ${NC}"
     _log ""
     _log "${DIM}                      Kali Linux Hardening Tool${NC}"
     _log ""

[[ "$DRY_RUN"  == true ]] && _warn "DRY-RUN mode — no changes will be made to your system"
[[ "$AUTO_YES" == true ]] && _warn "PARANOID MODE — all prompts will be accepted automatically"
_log ""

# ─────────────────────────────────────────────────────────────────────────────
#  1. SYSTEM UPDATE
# ─────────────────────────────────────────────────────────────────────────────
_section "1 / SYSTEM UPDATE"

if ask "Update system packages? (apt update && full-upgrade)"; then
    _info "Running apt update && full-upgrade..."
    run apt-get update -q
    run apt-get full-upgrade -y
    run apt-get autoremove -y
    _ok "System packages updated"
else
    _skip "System update"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  2. USER PASSWORD
# ─────────────────────────────────────────────────────────────────────────────
_section "2 / USER PASSWORD"

TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
if [[ "$AUTO_YES" == true ]]; then
    _skip "Password change (skipped in auto-yes mode — must be set manually)"
elif ask "Change password for '${TARGET_USER}'?"; then
    passwd "$TARGET_USER"
    _ok "Password updated for ${TARGET_USER}"
else
    _skip "Password change"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  3. INSTALL HARDENING TOOLS
# ─────────────────────────────────────────────────────────────────────────────
_section "3 / INSTALL TOOLS"

tools_to_install=()

ask "Install UFW (firewall)?"                                              && tools_to_install+=(ufw)
ask "Install fail2ban (brute-force protection)?"                           && tools_to_install+=(fail2ban)
ask "Install unattended-upgrades (automatic security updates)?"            && tools_to_install+=(unattended-upgrades)
ask "Install rkhunter (rootkit scanner)?"                                  && tools_to_install+=(rkhunter)
ask "Install lynis (comprehensive security audit tool)?"                   && tools_to_install+=(lynis)
ask "Install ClamAV (antivirus scanner)?"                                  && tools_to_install+=(clamav clamav-freshclam)
ask "Install auditd (kernel audit logging)?"                               && tools_to_install+=(auditd audispd-plugins)

if [[ ${#tools_to_install[@]} -gt 0 ]]; then
    _info "Installing: ${tools_to_install[*]}"
    run apt-get install -y "${tools_to_install[@]}"
    _ok "Installed: ${tools_to_install[*]}"
else
    _skip "No additional tools installed"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  4. FIREWALL (UFW)
# ─────────────────────────────────────────────────────────────────────────────
_section "4 / FIREWALL (UFW)"

if command -v ufw &>/dev/null; then
    if ask "Enable UFW with default deny-incoming / allow-outgoing?"; then
        run ufw --force reset
        run ufw default deny incoming
        run ufw default allow outgoing
        run ufw --force enable
        _ok "UFW enabled (default deny incoming)"

        if [[ "$AUTO_YES" == true ]]; then
            # Paranoid mode — no ports opened. SSH is being purged anyway,
            # and a Kali box shouldn't be listening on server ports by default.
            _info "Paranoid mode — no inbound ports opened"
        else
            ask "Allow SSH (port 22) through firewall?"    && { run ufw allow ssh;     _ok "UFW: SSH allowed"; }
            ask "Allow HTTP (port 80) through firewall?"   && { run ufw allow 80/tcp;  _ok "UFW: HTTP allowed"; }
            ask "Allow HTTPS (port 443) through firewall?" && { run ufw allow 443/tcp; _ok "UFW: HTTPS allowed"; }
        fi

        if [[ "$DRY_RUN" == false ]]; then
            _info "Current UFW status:"
            ufw status verbose | tee -a "$LOG_FILE"
        fi
    else
        _skip "UFW firewall"
    fi
else
    _info "UFW not installed — skipping firewall configuration"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  5. SSH HARDENING
# ─────────────────────────────────────────────────────────────────────────────
_section "5 / SSH CONFIGURATION"

SSH_CONFIG="/etc/ssh/sshd_config"

# Resolve the correct service name (ssh vs sshd distro differences)
_ssh_svc() {
    if systemctl list-unit-files 2>/dev/null | grep -q "^sshd\.service"; then
        echo "sshd"
    else
        echo "ssh"
    fi
}

if [[ "$AUTO_YES" == true ]]; then
    _warn "Paranoid mode — removing SSH entirely"
    SSH_SERVICE="$(_ssh_svc)"
    run systemctl stop    "$SSH_SERVICE" 2>/dev/null || true
    run systemctl disable "$SSH_SERVICE" 2>/dev/null || true
    run apt-get purge -y openssh-server
    run apt-get autoremove -y
    _ok "SSH removed (paranoid mode)"
elif ask "Is SSH needed on this machine?"; then
    if ! dpkg -l openssh-server &>/dev/null 2>&1; then
        ask "openssh-server is not installed. Install it now?" \
            && run apt-get install -y openssh-server \
            || { _skip "SSH hardening (not installed)"; }
    fi

    if [[ -f "$SSH_CONFIG" ]]; then
        run cp "$SSH_CONFIG" "${SSH_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
        _info "Backed up sshd_config"
    fi

    _info "Applying automatic SSH hardening..."
    _ssh_set "PermitRootLogin"          "no"
    _ssh_set "X11Forwarding"            "no"
    _ssh_set "MaxAuthTries"             "3"
    _ssh_set "LoginGraceTime"           "30"
    _ssh_set "ClientAliveInterval"      "300"
    _ssh_set "ClientAliveCountMax"      "2"
    _ssh_set "AllowTcpForwarding"       "no"
    _ssh_set "PermitEmptyPasswords"     "no"
    _ssh_set "UseDNS"                   "no"
    _ssh_set "PrintLastLog"             "yes"
    # Protocol directive removed in OpenSSH 7.6+, only set on older systems
    if sshd -T 2>/dev/null | grep -q "^protocol"; then
        _ssh_set "Protocol" "2"
    fi
    _ok "SSH hardened: root login off, X11 off, empty passwords off, timeouts set"

    if ask "Disable SSH password auth (key-only)? WARNING: Verify your key is installed first!"; then
        _warn "Make sure your SSH public key is in ~/.ssh/authorized_keys before logging out!"
        _ssh_set "PasswordAuthentication" "no"
        _ssh_set "ChallengeResponseAuthentication" "no"
        _ok "SSH password auth disabled (key-only)"
    fi

    if ask "Change SSH port from default 22? (reduces automated scan noise)"; then
        local_port=""
        echo -en "  ${Y}?${NC} ${W}Enter new SSH port (1024–65534):${NC} "
        read -r local_port </dev/tty || true
        if [[ "$local_port" =~ ^[0-9]+$ ]] && (( local_port >= 1024 && local_port <= 65534 )); then
            _ssh_set "Port" "$local_port"
            if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
                run ufw allow "${local_port}/tcp"
                run ufw delete allow ssh 2>/dev/null || true
            fi
            _ok "SSH port changed to ${local_port}"
        else
            _warn "Invalid port '${local_port}' — keeping port 22"
        fi
    fi

    SSH_SERVICE="$(_ssh_svc)"
    run systemctl enable  "$SSH_SERVICE"
    run systemctl restart "$SSH_SERVICE"
    _ok "SSH service ($SSH_SERVICE) restarted and enabled"

else
    _warn "SSH will be removed from this system."
    if ask "Confirm: permanently remove openssh-server?"; then
        SSH_SERVICE="$(_ssh_svc)"
        run systemctl stop    "$SSH_SERVICE" 2>/dev/null || true
        run systemctl disable "$SSH_SERVICE" 2>/dev/null || true
        run apt-get purge -y openssh-server
        run apt-get autoremove -y
        _ok "SSH removed"
    else
        _skip "SSH removal (keeping as-is)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
#  6. UNNECESSARY SERVICES
# ─────────────────────────────────────────────────────────────────────────────
_section "6 / UNNECESSARY SERVICES"

declare -A SVC_DESC=(
    [avahi-daemon]="mDNS / Bonjour network discovery"
    [cups]="Printer spooler"
    [cups-browsed]="CUPS network printer browsing"
    [bluetooth]="Bluetooth daemon"
    [exim4]="Mail transfer agent"
    [rpcbind]="RPC portmapper (needed for NFS)"
    [nfs-server]="NFS file server"
    [vsftpd]="FTP server"
    [telnet]="Telnet daemon (insecure — disable this!)"
)

for svc in "${!SVC_DESC[@]}"; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\.service"; then
        if ask "Disable ${svc} — ${SVC_DESC[$svc]}?"; then
            run systemctl disable --now "$svc" || true
            _ok "Disabled: ${svc}"
        else
            _skip "Service: ${svc}"
        fi
    fi
done

# ─────────────────────────────────────────────────────────────────────────────
#  7. KERNEL HARDENING (sysctl) — applied automatically
# ─────────────────────────────────────────────────────────────────────────────
_section "7 / KERNEL HARDENING (sysctl) — automatic"

_info "Writing kernel security parameters to /etc/sysctl.d/99-harden.conf ..."

SYSCTL_FILE="/etc/sysctl.d/99-harden.conf"

if [[ "$DRY_RUN" == false ]]; then
    cat > "$SYSCTL_FILE" <<'SYSCTL'
# ── auto-hardon.sh — kernel security parameters ──────────────────────────────

# ── Network: disable IP forwarding (this host is not a router) ───────────────
net.ipv4.ip_forward                     = 0
net.ipv6.conf.all.forwarding            = 0

# ── Network: source routing (used in spoofing attacks) ───────────────────────
net.ipv4.conf.all.accept_source_route   = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route   = 0

# ── Network: SYN flood protection (TCP SYN cookies) ─────────────────────────
net.ipv4.tcp_syncookies                 = 1

# ── Network: disable ICMP redirect acceptance / sending ──────────────────────
net.ipv4.conf.all.accept_redirects      = 0
net.ipv4.conf.default.accept_redirects  = 0
net.ipv6.conf.all.accept_redirects      = 0
net.ipv4.conf.all.send_redirects        = 0
net.ipv4.conf.default.send_redirects    = 0

# ── Network: ignore ICMP broadcast pings + bogus error responses ─────────────
net.ipv4.icmp_echo_ignore_broadcasts    = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ── Network: log packets with impossible source addresses (martians) ──────────
net.ipv4.conf.all.log_martians          = 1
net.ipv4.conf.default.log_martians      = 1

# ── Network: disable IPv6 router advertisements ──────────────────────────────
net.ipv6.conf.all.accept_ra             = 0
net.ipv6.conf.default.accept_ra         = 0

# ── Network: enable reverse path filtering ───────────────────────────────────
net.ipv4.conf.all.rp_filter             = 1
net.ipv4.conf.default.rp_filter         = 1

# ── Memory: ASLR — randomise virtual address space ───────────────────────────
kernel.randomize_va_space               = 2

# ── Memory: restrict /proc/kallsyms, dmesg to root ───────────────────────────
kernel.kptr_restrict                    = 2
kernel.dmesg_restrict                   = 1

# ── Process: restrict ptrace to direct parent only ───────────────────────────
kernel.yama.ptrace_scope                = 1

# ── File: protect hardlinks and symlinks against TOCTOU attacks ──────────────
fs.protected_hardlinks                  = 1
fs.protected_symlinks                   = 1
SYSCTL

    sysctl -p "$SYSCTL_FILE" >> "$LOG_FILE" 2>&1 \
        || _warn "Some sysctl params may not apply on this kernel — check $LOG_FILE"
fi

_ok "Kernel hardening applied ($SYSCTL_FILE)"

# ─────────────────────────────────────────────────────────────────────────────
#  8. FAIL2BAN
# ─────────────────────────────────────────────────────────────────────────────
_section "8 / FAIL2BAN"

if command -v fail2ban-server &>/dev/null; then
    if ask "Enable and configure fail2ban?"; then
        JAIL_LOCAL="/etc/fail2ban/jail.local"
        if [[ ! -f "$JAIL_LOCAL" ]] && [[ "$DRY_RUN" == false ]]; then
            cat > "$JAIL_LOCAL" <<'JAIL'
[DEFAULT]
# Ban IPs for 1 hour after 5 failures within 10 minutes
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
JAIL
        fi
        run systemctl enable  fail2ban
        run systemctl restart fail2ban
        _ok "fail2ban enabled (5 retries / 10 min window / 1 h ban)"
    else
        _skip "fail2ban"
    fi
else
    _info "fail2ban not installed — skipping"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  9. AUDITD
# ─────────────────────────────────────────────────────────────────────────────
_section "9 / AUDIT DAEMON"

if command -v auditctl &>/dev/null; then
    if ask "Enable auditd (kernel audit logging)?"; then
        run systemctl enable  auditd
        run systemctl restart auditd
        _ok "auditd enabled — logs at /var/log/audit/audit.log"
    else
        _skip "auditd"
    fi
else
    _info "auditd not installed — skipping"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  10. AUTOMATIC SECURITY UPDATES
# ─────────────────────────────────────────────────────────────────────────────
_section "10 / AUTOMATIC UPDATES"

if command -v unattended-upgrades &>/dev/null; then
    if ask "Enable automatic security updates?"; then
        if [[ "$DRY_RUN" == false ]]; then
            cat > /etc/apt/apt.conf.d/20auto-upgrades <<'AUTOUPGRADE'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
AUTOUPGRADE
        fi
        _ok "Automatic security updates enabled"
    else
        _skip "Automatic updates"
    fi
else
    _info "unattended-upgrades not installed — skipping"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  11. SECURE UMASK — automatic
# ─────────────────────────────────────────────────────────────────────────────
_section "11 / UMASK HARDENING — automatic"

UMASK_FILE="/etc/profile.d/99-harden-umask.sh"
_info "Setting default umask to 027 (owner=rwx, group=rx, others=none)..."

if [[ "$DRY_RUN" == false ]]; then
    cat > "$UMASK_FILE" <<'UMASK'
# auto-hardon.sh — restrictive default umask
# owner: rwx (7), group: r-x (5), others: --- (0)
umask 027
UMASK
    chmod 644 "$UMASK_FILE"
fi
_ok "Secure umask (027) set via $UMASK_FILE"

# ─────────────────────────────────────────────────────────────────────────────
#  12. LOGIN BANNER
# ─────────────────────────────────────────────────────────────────────────────
_section "12 / LOGIN BANNER"

if ask "Set a legal warning banner (/etc/issue, /etc/motd)?"; then
    if [[ "$DRY_RUN" == false ]]; then
        cat > /etc/issue <<'BANNER'

  ╔══════════════════════════════════════════════════════════════╗
  ║  WARNING: Authorised access only. All activity is logged.   ║
  ║  Unauthorised access is prohibited and will be prosecuted.  ║
  ║  Disconnect now if you are not an authorised user.          ║
  ╚══════════════════════════════════════════════════════════════╝

BANNER
        cp /etc/issue /etc/issue.net
        cp /etc/issue /etc/motd
    fi
    _ok "Login warning banner set"
else
    _skip "Login banner"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  13. DISABLE IPv6
# ─────────────────────────────────────────────────────────────────────────────
_section "13 / IPv6"

if ask "Disable IPv6 system-wide? (only if you have no need for it)"; then
    if [[ "$DRY_RUN" == false ]]; then
        cat > /etc/sysctl.d/99-disable-ipv6.conf <<'IPV6'
net.ipv6.conf.all.disable_ipv6     = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6      = 1
IPV6
        sysctl -p /etc/sysctl.d/99-disable-ipv6.conf >> "$LOG_FILE" 2>&1 \
            || _warn "Could not apply IPv6 disable at runtime — will take effect on reboot"
    fi
    _ok "IPv6 disabled"
else
    _skip "IPv6 disable"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  14. RKHUNTER
# ─────────────────────────────────────────────────────────────────────────────
_section "14 / RKHUNTER"

if command -v rkhunter &>/dev/null; then
    if ask "Run rkhunter initial baseline scan?"; then

        # Known false positive patterns on Kali / Debian desktop installs
        declare -a RKH_FP=(
            "lwp-request"           # Perl script — normal on Debian/Kali
            "sem.haveged"           # haveged entropy daemon semaphore
            "/etc/.java"            # Standard Java config directory
            "/etc/.updated"         # PackageKit update timestamp file
            "thunar"                # Desktop file manager — high shm is normal
            "xfdesktop"             # XFCE desktop — high shm is normal
            "firefox-esr"           # Browser — high shm is normal
        )

        _info "Updating rkhunter database..."
        run rkhunter --update  || true
        run rkhunter --propupd

        _info "Running rootkit scan..."
        rkhunter_tmp=$(mktemp)

        # Run and capture — avoid tee so output is fully buffered before display
        rkhunter --check --sk --rwo > "$rkhunter_tmp" 2>&1 || true
        cat "$rkhunter_tmp" >> "$LOG_FILE"

        # Display with false-positive annotations
        had_real_warning=false
        while IFS= read -r line; do
            is_fp=false
            for pattern in "${RKH_FP[@]}"; do
                if [[ "$line" == *"$pattern"* ]]; then
                    is_fp=true; break
                fi
            done
            if [[ "$is_fp" == true ]]; then
                _log "${DIM}    $line${NC}"
                _log "${DIM}${Y}    └─ likely false positive on Kali — see README${NC}"
            elif [[ "$line" == Warning:* ]]; then
                _log "${Y}    $line${NC}"
                had_real_warning=true
            elif [[ -n "$line" ]]; then
                _log "    $line"
            fi
        done < "$rkhunter_tmp"
        rm -f "$rkhunter_tmp"

        if [[ "$had_real_warning" == true ]]; then
            _warn "rkhunter found warnings not in the known false-positive list — review /var/log/rkhunter.log"
        else
            _info "All rkhunter warnings are known Kali false positives"
        fi

        _ok "rkhunter baseline scan complete — full log at /var/log/rkhunter.log"
    else
        _skip "rkhunter scan"
    fi
else
    _info "rkhunter not installed — skipping"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  15. LYNIS SECURITY AUDIT
# ─────────────────────────────────────────────────────────────────────────────
_section "15 / LYNIS AUDIT"

if command -v lynis &>/dev/null; then
    if ask "Run lynis security audit? (read-only, informational only)"; then
        run lynis audit system --quiet || true
        _ok "Lynis audit complete — report at /var/log/lynis.log"
    else
        _skip "Lynis audit"
    fi
else
    _info "lynis not installed — skipping"
fi

# ─────────────────────────────────────────────────────────────────────────────
#  SUMMARY
# ─────────────────────────────────────────────────────────────────────────────
_section "SUMMARY"

_log ""
_log "${G}${W}  Applied (${#APPLIED[@]}):${NC}"
if [[ ${#APPLIED[@]} -eq 0 ]]; then
    _log "${DIM}    (nothing applied)${NC}"
else
    for item in "${APPLIED[@]}"; do
        _log "${G}    ✔  ${item}${NC}"
    done
fi

_log ""
_log "${DIM}${W}  Skipped (${#SKIPPED[@]}):${NC}"
if [[ ${#SKIPPED[@]} -eq 0 ]]; then
    _log "${DIM}    (nothing skipped)${NC}"
else
    for item in "${SKIPPED[@]}"; do
        _log "${DIM}    ─  ${item}${NC}"
    done
fi

if [[ ${#WARNINGS_LIST[@]} -gt 0 ]]; then
    _log ""
    _log "${Y}${W}  Warnings (${#WARNINGS_LIST[@]}):${NC}"
    for item in "${WARNINGS_LIST[@]}"; do
        _log "${Y}    ⚠  ${item}${NC}"
    done
fi

_log ""
_log "${C}  Full log saved → ${W}${LOG_FILE}${NC}"
_log ""

if [[ "$DRY_RUN" == true ]]; then
    _log "${Y}  ⚠  Dry-run — no changes were made to this system.${NC}"
else
    _log "${G}  ✔  Hardening complete. Consider rebooting to ensure all changes take effect.${NC}"
fi
_log ""
