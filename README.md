# 🔒 Auto-Hardon
### Kali Linux Hardening Tool

> Automated, interactive hardening script for freshly provisioned Kali / Debian Linux machines and VMs. Prompts before anything that could break your workflow — applies everything else automatically.

---

## Features

| Category | What it does |
|---|---|
| 🔄 **System** | `apt update` + `full-upgrade` + `autoremove` |
| 🔐 **Password** | Change user password interactively |
| 🧱 **Firewall** | UFW with default deny-in / allow-out, per-port prompts |
| 🔑 **SSH** | Harden config, optional key-only auth, custom port, or full removal |
| ⚙️ **Services** | Disable avahi, cups, bluetooth, exim4, rpcbind, nfs, vsftpd, telnet |
| 🧠 **Kernel** | `sysctl` hardening — ASLR, SYN cookies, ICMP, ptrace, martian logging |
| 🚫 **fail2ban** | Installs + configures with sane defaults (5 retries / 1h ban) |
| 📦 **auditd** | Kernel-level audit logging |
| 🔁 **Auto-updates** | `unattended-upgrades` for automatic security patches |
| 🎭 **umask** | Sets default umask to `027` system-wide |
| 📢 **Banner** | Legal warning on `/etc/issue`, `/etc/issue.net`, `/etc/motd` |
| 🌐 **IPv6** | Optional system-wide disable |
| 🦠 **ClamAV** | Optional antivirus install |
| 🔍 **rkhunter** | Optional rootkit scan + baseline |
| 📋 **lynis** | Optional full security audit |
| 📝 **Log** | Timestamped audit log of every applied change |

---

## Usage

```bash
# Clone and make executable
git clone https://github.com/youruser/auto-hardon.git
cd auto-hardon
chmod +x kali-harden.sh

# Interactive mode (recommended)
sudo ./kali-harden.sh

# Preview everything without changing anything
sudo ./kali-harden.sh --dry-run

# Full auto — no prompts, nukes SSH (see Paranoid Mode below)
sudo ./kali-harden.sh --paranoid

# Custom log file
sudo ./kali-harden.sh --log /tmp/my-audit.log
```

---

## Options

| Flag | Description |
|---|---|
| `-h`, `--help` | Show help menu and exit |
| `-y`, `--paranoid` | Accept all prompts automatically, remove SSH entirely |
| `-n`, `--dry-run` | Preview all actions without making any changes |
| `-l`, `--log FILE` | Write output log to `FILE` (default: `/var/log/kali-harden-<timestamp>.log`) |

---

## Paranoid Mode

```bash
sudo ./kali-harden.sh --paranoid
```

Runs the entire script non-interactively with maximum hardening applied:

- ✅ All prompts auto-accepted
- 🚫 SSH (`openssh-server`) is **purged entirely** — no prompt, no confirmation
- 🚫 Password change is **skipped** (requires interactive input — set it manually)

> ⚠️ Use on machines where you have out-of-band access (console, VM manager, etc.) and do **not** need SSH.

---

## What Gets Prompted vs Automatic

The script is designed to never silently break your workflow. Anything with real operational impact requires a `y/n` answer.

**Always prompted (could affect access or usability):**
- System package upgrade
- Password change
- Firewall enable + individual port rules
- SSH keep / harden / remove
- SSH key-only lockdown
- SSH port change
- Per-service disable (avahi, cups, bluetooth, etc.)
- IPv6 disable
- Login banner
- Optional tool installs

**Always automatic (safe, non-destructive):**
- Kernel `sysctl` hardening
- Secure umask (`027`) via `/etc/profile.d/`
- `sshd_config` backup before any edits
- Audit log of every action

---

## Kernel Parameters Applied

Written to `/etc/sysctl.d/99-harden.conf`:

```
net.ipv4.ip_forward                      = 0      # Not a router
net.ipv4.tcp_syncookies                  = 1      # SYN flood protection
net.ipv4.conf.all.accept_redirects       = 0      # No ICMP redirects
net.ipv4.conf.all.send_redirects         = 0
net.ipv4.conf.all.log_martians           = 1      # Log impossible source IPs
net.ipv4.conf.all.rp_filter              = 1      # Reverse path filtering
net.ipv4.icmp_echo_ignore_broadcasts     = 1      # No broadcast pings
kernel.randomize_va_space                = 2      # Full ASLR
kernel.kptr_restrict                     = 2      # Hide kernel pointers
kernel.dmesg_restrict                    = 1      # dmesg restricted to root
kernel.yama.ptrace_scope                 = 1      # Restrict ptrace
fs.protected_hardlinks                   = 1      # Prevent hardlink attacks
fs.protected_symlinks                    = 1      # Prevent symlink attacks
```

---

## SSH Hardening (when kept)

Applied automatically to `/etc/ssh/sshd_config` (with backup):

```
PermitRootLogin           no
X11Forwarding             no
MaxAuthTries              3
LoginGraceTime            30
ClientAliveInterval       300
ClientAliveCountMax       2
AllowTcpForwarding        no
PermitEmptyPasswords      no
UseDNS                    no
PrintLastLog              yes
```

Optionally (prompted):
- `PasswordAuthentication no` — key-only login
- Custom port — also updates UFW automatically if active

---

## fail2ban Defaults

A `jail.local` is written if one doesn't already exist:

```ini
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled = true
```

---

## Requirements

- Debian-based Linux (Kali, Ubuntu, Debian, etc.)
- `bash` 4.0+
- Run as `root` / `sudo`

---

## Output

Every run produces a timestamped log at `/var/log/kali-harden-<YYYYMMDD_HHMMSS>.log` (or your custom path) containing every command run, its output, and a summary of applied vs skipped actions.

At the end of each run, a summary is printed:

```
  Applied (12):
    ✔  System packages updated
    ✔  UFW enabled (default deny incoming)
    ✔  SSH hardened: root login off, X11 off, empty passwords off, timeouts set
    ✔  Kernel hardening applied
    ...

  Skipped (3):
    ─  Password change
    ─  IPv6 disable
    ─  Lynis audit
```

---

## Disclaimer

This script is provided as-is for educational and operational use on systems you own or are authorised to administer. Always test in a VM or with `--dry-run` before running on a production machine. The author takes no responsibility for locked-out systems — if you're killing SSH, make sure you have another way in.

---

## License

MIT
