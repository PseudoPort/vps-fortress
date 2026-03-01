#!/usr/bin/env bash
# =============================================================================
# vps-fortress: Automated VPS Hardening Setup Script
# Automates all steps from README.md
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# State file for resume functionality
# -----------------------------------------------------------------------------
STATE_FILE="/var/run/vps-fortress.state"

# -----------------------------------------------------------------------------
# Colors & Helpers
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
step()    { echo -e "\n${BOLD}${GREEN}==> $*${RESET}"; }
die()     { error "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Resume functionality
# -----------------------------------------------------------------------------
mark_step_completed() {
  local step_name="$1"
  local extra_info="${2:-}"
  echo "$step_name" >> "$STATE_FILE"
  if [[ -n "$extra_info" ]]; then
    echo "$extra_info" >> "$STATE_FILE"
  fi
  success "Step '$step_name' marked as completed"
}

get_step_info() {
  local step_name="$1"
  if [[ -f "$STATE_FILE" ]]; then
    grep -A1 "^${step_name}$" "$STATE_FILE" | tail -n1
  fi
}

is_step_completed() {
  local step_name="$1"
  if [[ -f "$STATE_FILE" ]] && grep -qF "$step_name" "$STATE_FILE"; then
    return 0
  else
    return 1
  fi
}

skip_if_completed() {
  local step_name="$1"
  if is_step_completed "$step_name"; then
    info "Skipping step '$step_name' (already completed)"
    return 0
  else
    return 1
  fi
}

# -----------------------------------------------------------------------------
# Root check
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  die "This script must be run as root. Try: sudo bash $0"
fi

# -----------------------------------------------------------------------------
# Detect OS / Package Manager
# -----------------------------------------------------------------------------
detect_os() {
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect OS: /etc/os-release not found."
  fi

  case "$OS_ID" in
    ubuntu|debian)
      PKG_MANAGER="apt"
      ;;
    centos|rhel|almalinux|rocky|opencloudos)
      PKG_MANAGER="dnf"
      ;;
    arch|manjaro)
      PKG_MANAGER="pacman"
      ;;
    *)
      # Try ID_LIKE fallback
      if echo "$OS_ID_LIKE" | grep -qiE "debian|ubuntu"; then
        PKG_MANAGER="apt"
      elif echo "$OS_ID_LIKE" | grep -qiE "rhel|centos|fedora|opencloudos"; then
        PKG_MANAGER="dnf"
      elif echo "$OS_ID_LIKE" | grep -qiE "arch"; then
        PKG_MANAGER="pacman"
      else
        # Auto-detect package manager by probing available commands
        info "OS not directly supported, probing for package manager..."
        if command -v dnf &>/dev/null; then
          PKG_MANAGER="dnf"
          warn "Detected dnf - treating as RHEL-based distribution"
        elif command -v apt &>/dev/null; then
          PKG_MANAGER="apt"
          warn "Detected apt - treating as Debian-based distribution"
        elif command -v pacman &>/dev/null; then
          PKG_MANAGER="pacman"
          warn "Detected pacman - treating as Arch-based distribution"
        elif command -v zypper &>/dev/null; then
          PKG_MANAGER="zypper"
          warn "Detected zypper - treating as SUSE-based distribution"
        else
          die "Unsupported OS: $OS_ID. Supported: Ubuntu, Debian, CentOS, RHEL, AlmaLinux, Rocky, OpenCloudOS, Arch."
        fi
      fi
      ;;
  esac

  info "Detected OS: ${OS_ID} | Package manager: ${PKG_MANAGER}"
}

# -----------------------------------------------------------------------------
# Step 1: Update System Packages
# -----------------------------------------------------------------------------
step_1_update_packages() {
  step "Step 1: Update System Packages"

  case "$PKG_MANAGER" in
    apt)
      info "Running: apt update && apt upgrade -y"
      apt update && apt upgrade -y
      ;;
    dnf)
      info "Running: dnf update -y"
      dnf update -y
      ;;
    pacman)
      info "Running: pacman -Syu --noconfirm"
      pacman -Syu --noconfirm
      ;;
  esac

  success "System packages updated."
}

# -----------------------------------------------------------------------------
# Step 2: Create a Non-Root Sudo User
# -----------------------------------------------------------------------------
step_2_create_user() {
  step "Step 2: Create a Non-Root Sudo User"

  # Prompt for username
  while true; do
    read -rp "Enter the new username to create: " NEW_USER
    if [[ -z "$NEW_USER" ]]; then
      warn "Username cannot be empty. Please try again."
    elif id "$NEW_USER" &>/dev/null; then
      warn "User '$NEW_USER' already exists. Skipping user creation."
      break
    else
      break
    fi
  done

  if ! id "$NEW_USER" &>/dev/null; then
    case "$PKG_MANAGER" in
      apt)
        info "Creating user '$NEW_USER' with adduser..."
        adduser --gecos "" "$NEW_USER"
        usermod -aG sudo "$NEW_USER"
        ;;
      dnf|pacman)
        info "Creating user '$NEW_USER' with useradd..."
        useradd -m "$NEW_USER"
        passwd "$NEW_USER"
        usermod -aG wheel "$NEW_USER"

        # Ensure sudo is installed and wheel group is enabled
        if ! command -v sudo &>/dev/null; then
          info "Installing sudo..."
          case "$PKG_MANAGER" in
            dnf)    dnf install -y sudo ;;
            pacman) pacman -S --noconfirm sudo ;;
          esac
        fi

        # Uncomment %wheel line in sudoers if not already active
        if ! grep -qE '^\s*%wheel\s+ALL=\(ALL\)\s+ALL' /etc/sudoers; then
          info "Enabling %wheel group in /etc/sudoers..."
          sed -i 's/^#\s*\(%wheel\s\+ALL=(ALL)\s\+ALL\)/\1/' /etc/sudoers
          sed -i 's/^#\s*\(%wheel\s\+ALL=(ALL:ALL)\s\+ALL\)/\1/' /etc/sudoers
        fi
        ;;
    esac
    success "User '$NEW_USER' created and added to the sudo/wheel group."
  fi
}

# -----------------------------------------------------------------------------
# Step 3: Configure SSH Key Authentication
# -----------------------------------------------------------------------------
step_3_ssh_key_auth() {
  step "Step 3: Configure SSH Key Authentication"

  local ssh_dir="/home/${NEW_USER}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  # Create .ssh directory
  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  chown "${NEW_USER}:${NEW_USER}" "$ssh_dir"

  # Prompt for public key
  echo ""
  info "Paste your local machine's SSH public key below."
  info "It typically starts with 'ssh-rsa', 'ssh-ed25519', or 'ecdsa-sha2-nistp256'."
  info "Press ENTER twice when done."
  echo ""

  local pub_key=""
  while true; do
    read -rp "Public key: " pub_key
    if [[ -z "$pub_key" ]]; then
      warn "No key entered. Please paste your public SSH key."
    elif [[ "$pub_key" != ssh-* && "$pub_key" != ecdsa-* ]]; then
      warn "Key does not appear to be a valid SSH public key. Please try again."
    else
      break
    fi
  done

  # Append key (avoid duplicates)
  if [[ -f "$auth_keys" ]] && grep -qF "$pub_key" "$auth_keys"; then
    warn "Public key already present in authorized_keys. Skipping."
  else
    echo "$pub_key" >> "$auth_keys"
    success "Public key added to ${auth_keys}."
  fi

  chmod 600 "$auth_keys"
  chown "${NEW_USER}:${NEW_USER}" "$auth_keys"

  success "SSH key authentication configured for user '${NEW_USER}'."
}

# -----------------------------------------------------------------------------
# Step 4: Harden SSH Configuration
# -----------------------------------------------------------------------------
step_4_harden_ssh() {
  step "Step 4: Harden SSH Configuration"

  local sshd_config="/etc/ssh/sshd_config"

  # Prompt for custom SSH port
  while true; do
    read -rp "Enter custom SSH port [default: 2222]: " SSH_PORT
    SSH_PORT="${SSH_PORT:-2222}"
    if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )); then
      break
    else
      warn "Port must be a number between 1024 and 65535."
    fi
  done

  info "Backing up ${sshd_config} to ${sshd_config}.bak"
  cp "$sshd_config" "${sshd_config}.bak"

  # Helper: set or replace a directive in sshd_config
  set_sshd_option() {
    local key="$1"
    local value="$2"
    # Remove existing (commented or uncommented) lines for this key
    sed -i "s/^\s*#\?\s*${key}\s.*/${key} ${value}/" "$sshd_config"
    # If the key is not present at all, append it
    if ! grep -qE "^\s*${key}\s" "$sshd_config"; then
      echo "${key} ${value}" >> "$sshd_config"
    fi
  }

  info "Setting Port to ${SSH_PORT}..."
  set_sshd_option "Port" "$SSH_PORT"

  info "Disabling root login..."
  set_sshd_option "PermitRootLogin" "no"

  info "Disabling password authentication..."
  set_sshd_option "PasswordAuthentication" "no"

  info "Disabling empty passwords..."
  set_sshd_option "PermitEmptyPasswords" "no"

  success "SSH configuration hardened. (Service will be restarted after firewall setup.)"
}

# -----------------------------------------------------------------------------
# Step 5: Configure the Firewall
# -----------------------------------------------------------------------------
step_5_configure_firewall() {
  step "Step 5: Configure the Firewall"

  case "$PKG_MANAGER" in
    apt)
      info "Installing UFW..."
      apt install -y ufw

      info "Configuring UFW rules..."
      ufw --force reset
      ufw default deny incoming
      ufw default allow outgoing
      ufw allow "${SSH_PORT}/tcp"
      ufw --force enable

      success "UFW configured. Allowed port ${SSH_PORT}/tcp."
      ;;

    dnf)
      info "Installing and enabling Firewalld..."
      dnf install -y firewalld
      systemctl start firewalld
      systemctl enable firewalld

      info "Configuring Firewalld rules..."
      firewall-cmd --permanent --add-port="${SSH_PORT}/tcp"
      firewall-cmd --permanent --remove-service=ssh 2>/dev/null || true
      firewall-cmd --reload

      success "Firewalld configured. Allowed port ${SSH_PORT}/tcp."
      ;;

    pacman)
      info "Installing UFW..."
      pacman -S --noconfirm ufw
      systemctl enable --now ufw

      info "Configuring UFW rules..."
      ufw --force reset
      ufw default deny incoming
      ufw default allow outgoing
      ufw allow "${SSH_PORT}/tcp"
      ufw --force enable

      success "UFW configured. Allowed port ${SSH_PORT}/tcp."
      ;;
  esac

  # Restart SSH service now that firewall is configured
  info "Restarting SSH service..."
  if systemctl list-units --type=service | grep -q "^  ssh\.service"; then
    systemctl restart ssh
    success "SSH service restarted (ssh)."
  elif systemctl list-units --type=service | grep -q "^  sshd\.service"; then
    systemctl restart sshd
    success "SSH service restarted (sshd)."
  else
    # Try both, ignore errors
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || warn "Could not restart SSH service automatically. Please restart it manually."
  fi

  warn "IMPORTANT: Do NOT close this session yet!"
  warn "Open a NEW terminal and verify you can connect with:"
  warn "  ssh -p ${SSH_PORT} ${NEW_USER}@<your_server_ip>"
  echo ""
  read -rp "Press ENTER once you have confirmed the new SSH connection works, then this script will continue..."
}

# -----------------------------------------------------------------------------
# Step 6: Install and Configure Fail2Ban
# -----------------------------------------------------------------------------
step_6_fail2ban() {
  step "Step 6: Install and Configure Fail2Ban"

  case "$PKG_MANAGER" in
    apt)
      info "Installing Fail2Ban..."
      apt install -y fail2ban
      ;;
    dnf)
      info "Installing Fail2Ban..."
      # Try installing fail2ban directly, EPEL might not be needed on all RHEL derivatives
      if ! dnf install -y fail2ban 2>/dev/null; then
        # Try EPEL if direct install fails
        info "Trying EPEL repository..."
        if dnf install -y epel-release 2>/dev/null; then
          dnf install -y fail2ban
        else
          # Try alternative: install from source or copr
          warn "EPEL not available, trying alternative installation..."
          dnf install -y python3-pyinotify
          # Download and install fail2ban from source
          curl -s https://api.github.com/repos/fail2ban/fail2ban/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | cut -dv -f2
          FAIL2BAN_VERSION=$(curl -s https://api.github.com/repos/fail2ban/fail2ban/releases/latest | grep '"tag_name"' | cut -d'"' -f4 | cut -dv -f2)
          cd /tmp
          curl -sL "https://github.com/fail2ban/fail2ban/archive/refs/tags/${FAIL2BAN_VERSION}.tar.gz" -o "fail2ban-${FAIL2BAN_VERSION}.tar.gz"
          tar -xzf "fail2ban-${FAIL2BAN_VERSION}.tar.gz"
          cd "fail2ban-${FAIL2BAN_VERSION}"
          python3 setup.py install
          cd /tmp
          rm -rf "fail2ban-${FAIL2BAN_VERSION}" "fail2ban-${FAIL2BAN_VERSION}.tar.gz"
        fi
      fi
      ;;
    pacman)
      info "Installing Fail2Ban..."
      pacman -S --noconfirm fail2ban
      ;;
  esac

  systemctl enable --now fail2ban
  success "Fail2Ban installed and enabled."

  # Configure jail.local for custom SSH port
  local jail_conf="/etc/fail2ban/jail.conf"
  local jail_local="/etc/fail2ban/jail.local"

  if [[ -f "$jail_conf" ]]; then
    info "Copying jail.conf to jail.local..."
    cp "$jail_conf" "$jail_local"
  else
    info "jail.conf not found; creating jail.local from scratch..."
    touch "$jail_local"
  fi

  # Inject or replace [sshd] section
  info "Configuring [sshd] jail in jail.local for port ${SSH_PORT}..."

  # Remove any existing [sshd] block and re-insert a clean one
  python3 - <<PYEOF
import re, sys

jail_local = "${jail_local}"

with open(jail_local, "r") as f:
    content = f.read()

sshd_block = """
[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 3
bantime  = 3600
"""

# Remove existing [sshd] section (from [sshd] header to next section or EOF)
content = re.sub(
    r'\[sshd\].*?(?=\n\[|\Z)',
    '',
    content,
    flags=re.DOTALL
)

content = content.rstrip() + "\n" + sshd_block

with open(jail_local, "w") as f:
    f.write(content)

print("jail.local updated successfully.")
PYEOF

  info "Restarting Fail2Ban..."
  systemctl restart fail2ban
  success "Fail2Ban configured and restarted."
}

# -----------------------------------------------------------------------------
# Step 7: Enable Automatic Security Updates (Optional)
# -----------------------------------------------------------------------------
step_7_auto_updates() {
  step "Step 7: Enable Automatic Security Updates (Optional)"

  read -rp "Enable automatic security updates? [y/N]: " AUTO_UPDATES
  AUTO_UPDATES="${AUTO_UPDATES:-N}"

  if [[ ! "$AUTO_UPDATES" =~ ^[Yy]$ ]]; then
    info "Skipping automatic security updates."
    return
  fi

  case "$PKG_MANAGER" in
    apt)
      info "Installing unattended-upgrades..."
      apt install -y unattended-upgrades
      # Non-interactive reconfigure
      echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" \
        | debconf-set-selections
      dpkg-reconfigure -f noninteractive unattended-upgrades
      success "Automatic security updates enabled (unattended-upgrades)."
      ;;

    dnf)
      info "Installing dnf-automatic..."
      dnf install -y dnf-automatic

      info "Setting apply_updates = yes in /etc/dnf/automatic.conf..."
      sed -i 's/^\s*apply_updates\s*=\s*no/apply_updates = yes/' /etc/dnf/automatic.conf

      systemctl enable --now dnf-automatic.timer
      success "Automatic security updates enabled (dnf-automatic)."
      ;;

    pacman)
      warn "Arch Linux does not have a built-in automatic update mechanism equivalent to"
      warn "unattended-upgrades. Consider setting up a systemd timer or using 'informant'."
      warn "Skipping automatic updates for Arch Linux."
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
print_summary() {
  echo ""
  echo -e "${BOLD}${GREEN}============================================================${RESET}"
  echo -e "${BOLD}${GREEN}  VPS Fortress Setup Complete!${RESET}"
  echo -e "${BOLD}${GREEN}============================================================${RESET}"
  echo ""
  echo -e "  ${BOLD}New sudo user:${RESET}  ${NEW_USER}"
  echo -e "  ${BOLD}SSH port:${RESET}       ${SSH_PORT}"
  echo -e "  ${BOLD}Root login:${RESET}     Disabled"
  echo -e "  ${BOLD}Password auth:${RESET}  Disabled"
  echo -e "  ${BOLD}Firewall:${RESET}       Active (port ${SSH_PORT}/tcp allowed)"
  echo -e "  ${BOLD}Fail2Ban:${RESET}       Active (max 3 retries, ban 1 hour)"
  echo ""
  echo -e "  ${YELLOW}Connect with:${RESET}  ssh -p ${SSH_PORT} ${NEW_USER}@<your_server_ip>"
  echo ""
  echo -e "${BOLD}${GREEN}============================================================${RESET}"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  # Check for flags
  local resume=false
  local clear_state=false
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --resume|-r)
        resume=true
        ;;
      --clear-state|-c)
        clear_state=true
        ;;
      --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --resume, -r     Resume from previous interrupted run"
        echo "  --clear-state, -c Clear state file and start fresh"
        echo "  --help, -h       Show this help message"
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        echo "Use --help for usage information"
        exit 1
        ;;
    esac
    shift
  done

  # Clear state if requested
  if [[ "$clear_state" == true ]]; then
    if [[ -f "$STATE_FILE" ]]; then
      rm -f "$STATE_FILE"
      success "State file cleared"
    else
      info "No state file to clear"
    fi
  fi

  # Resume mode
  if [[ "$resume" == true ]]; then
    if [[ -f "$STATE_FILE" ]]; then
      info "Resuming from previous run..."
      info "Completed steps: $(tr '\n' ' ' < "$STATE_FILE")"
    else
      warn "No previous state found, starting fresh..."
    fi
  fi

  echo ""
  echo -e "${BOLD}${CYAN}============================================================${RESET}"
  echo -e "${BOLD}${CYAN}  vps-fortress: Automated VPS Hardening Script${RESET}"
  echo -e "${BOLD}${CYAN}============================================================${RESET}"
  echo ""

  detect_os

  if ! skip_if_completed "step_1"; then
    step_1_update_packages
    mark_step_completed "step_1"
  fi

  if ! skip_if_completed "step_2"; then
    step_2_create_user
    mark_step_completed "step_2" "$NEW_USER"
  else
    # Restore NEW_USER from state if resuming
    NEW_USER=$(get_step_info "step_2")
    if [[ -n "$NEW_USER" ]]; then
      info "Restored user: $NEW_USER"
    fi
  fi

  if ! skip_if_completed "step_3"; then
    step_3_ssh_key_auth
    mark_step_completed "step_3"
  fi

  if ! skip_if_completed "step_4"; then
    step_4_harden_ssh
    mark_step_completed "step_4" "$SSH_PORT"
  else
    # Restore SSH_PORT from state if resuming
    SSH_PORT=$(get_step_info "step_4")
    if [[ -n "$SSH_PORT" ]]; then
      info "Restored SSH port: $SSH_PORT"
    fi
  fi

  if ! skip_if_completed "step_5"; then
    step_5_configure_firewall
    mark_step_completed "step_5"
  fi

  if ! skip_if_completed "step_6"; then
    step_6_fail2ban
    mark_step_completed "step_6"
  fi

  if ! skip_if_completed "step_7"; then
    step_7_auto_updates
    mark_step_completed "step_7"
  fi

  print_summary
}

main "$@"
