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
  [[ -f "$STATE_FILE" ]] || return 0
  # Robust to "step_3" with no extra info: the next line is the FOLLOWING step
  # name, not data. Return only when the line immediately after is not itself
  # a step_<n> token.
  awk -v target="^${step_name}\$" '
    $0 ~ target { found=1; next }
    found && /^(step_[0-9]+|#|$)/ { exit }
    found { print; exit }
  ' "$STATE_FILE"
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
    info "Step '$step_name' was already completed."
    read -rp "Do you want to redo it? [y/N]: " redo_choice
    redo_choice="${redo_choice:-N}"
    if [[ "$redo_choice" =~ ^[Yy]$ ]]; then
      info "Redoing step '$step_name'..."
      # Remove the step from state file to allow re-running
      sed -i "/^${step_name}$/d" "$STATE_FILE"
      return 1
    else
      info "Skipping step '$step_name'"
      return 0
    fi
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
# Prerequisites checker
# -----------------------------------------------------------------------------
check_prerequisites() {
  step "Checking prerequisites..."

  local missing_prereqs=()

  # Check for required commands
  local required_cmds=(curl wget python3)
  
  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      missing_prereqs+=("$cmd")
    fi
  done

  if [[ ${#missing_prereqs[@]} -gt 0 ]]; then
    warn "Missing prerequisites: ${missing_prereqs[*]}"
    info "These will be installed automatically"
    return 1
  else
    success "All prerequisites satisfied"
    return 0
  fi
}

# -----------------------------------------------------------------------------
# Install prerequisites
# -----------------------------------------------------------------------------
install_prerequisites() {
  step "Installing prerequisites..."

  case "$PKG_MANAGER" in
    apt)
      info "Installing basic prerequisites..."
      apt update
      apt install -y python3 python3-pip curl wget git
      ;;
    dnf)
      info "Installing basic prerequisites..."
      dnf install -y python3 python3-pip curl wget git
      # Install pip if not available
      if ! command -v pip3 &>/dev/null; then
        info "Installing pip3..."
        dnf install -y python3-pip 2>/dev/null || {
          curl -sS https://bootstrap.pypa.io/get-pip.py -o /tmp/get-pip.py
          python3 /tmp/get-pip.py
          rm -f /tmp/get-pip.py
        }
      fi
      ;;
    pacman)
      info "Installing basic prerequisites..."
      pacman -S --noconfirm python python-pip curl wget git
      ;;
  esac

  # Ensure python3 is available
  if ! command -v python3 &>/dev/null; then
    die "python3 is required but not installed"
  fi

  success "Prerequisites installed."
}

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
        # Debian minimal may ship without sudo at all; install it before
        # modifying the group, otherwise `usermod -aG sudo` succeeds but the
        # user still cannot escalate.
        if ! command -v sudo &>/dev/null; then
          info "Installing sudo (Debian minimal images often lack it)..."
          apt install -y sudo
        fi
        usermod -aG sudo "$NEW_USER"
        # Same safety net as the dnf/pacman branch: make sure %sudo is
        # actually uncommented in /etc/sudoers. This is a no-op on Ubuntu and
        # a critical fix on stripped Debian images.
        if ! grep -qE '^\s*%sudo\s+ALL=\(ALL(:ALL)?\)\s+ALL' /etc/sudoers; then
          info "Enabling %sudo group in /etc/sudoers..."
          sed -i 's/^#\s*%sudo\s\+ALL=(ALL)\s\+ALL/%sudo   ALL=(ALL:ALL) ALL/' /etc/sudoers
          sed -i 's/^#\s*%sudo\s\+ALL=(ALL:ALL)\s\+ALL/%sudo   ALL=(ALL:ALL) ALL/' /etc/sudoers
        fi
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
# Step 3 helpers: paste / validate / fingerprint a public key
# -----------------------------------------------------------------------------

# Read a multi-line paste from stdin, terminated by a blank line or EOF.
# Strips CR and trailing whitespace per line. Echoes the last non-empty line
# (the candidate key). Long RSA keys often wrap; users are instructed to paste
# without wrapping, but we also accept the last logical line as the key.
read_pubkey_block() {
  local line last=""
  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#"${line%%[![:space:]]*}"}"
    if [[ -z "$line" ]]; then
      [[ -n "$last" ]] && break
      continue
    fi
    last="$line"
  done
  printf '%s' "$last"
}

# Resolve the concrete paths to fail2ban-server / fail2ban-client and the
# Python site-packages dir that contains the `fail2ban` module. Sets globals:
#   F2B_SERVER, F2B_CLIENT, F2B_PYTHONPATH
# Source-install path (/usr/local/bin, /usr/local/lib/.../site-packages) wins
# when both are present, mirroring the install order in step 6.
detect_fail2ban_paths() {
  local srv="/usr/local/bin/fail2ban-server"
  local cli="/usr/local/bin/fail2ban-client"
  if [[ ! -x "$srv" ]]; then srv="/usr/bin/fail2ban-server"; fi
  if [[ ! -x "$cli" ]]; then cli="/usr/bin/fail2ban-client"; fi
  F2B_SERVER="$(command -v fail2ban-server 2>/dev/null || echo "$srv")"
  F2B_CLIENT="$(command -v fail2ban-client 2>/dev/null || echo "$cli")"
  F2B_PYTHONPATH="$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])' 2>/dev/null || echo "")"
}

# Restart the SSH service across the two unit names (ssh.service / sshd.service)
# used by Debian/Ubuntu vs RHEL/Arch. Mirrors the safe-restart pattern used in
# step 5 and do_rollback so all three call sites stay in sync.
#
# Why the verification + fallback layers: in one smoke test the script
# restored sshd_config from .bak and called `systemctl restart ssh`; the
# restart command reported success but sshd did not re-bind to the new
# port, leaving the user locked out. Root cause was a stale child process
# holding a port while the new master could not bind cleanly. The
# fallbacks below handle that case: SIGHUP the existing master (reload
# config without full restart), reset-failed + retry, and finally try
# both unit names.
restart_ssh_service() {
  local sshd_unit=""

  # Detect which service name is in use on this distro.
  if systemctl list-unit-files --no-legend ssh.service 2>/dev/null | grep -q '\.service'; then
    sshd_unit="ssh"
  elif systemctl list-unit-files --no-legend sshd.service 2>/dev/null | grep -q '\.service'; then
    sshd_unit="sshd"
  fi

  # Pre-flight: refuse to restart if the config is invalid. A bad config
  # would kill the current sshd and leave the new one unable to start,
  # which is exactly the lockout we are trying to prevent.
  if command -v sshd >/dev/null 2>&1; then
    if ! sshd -t 2>/dev/null; then
      warn "sshd -t FAILED — refusing to restart (would brick the listener)"
      return 1
    fi
  fi

  # Layer 1: graceful restart via systemd.
  if [[ -n "$sshd_unit" ]]; then
    if systemctl restart "$sshd_unit" 2>/dev/null; then
      sleep 1
      if pgrep -f '/usr/sbin/sshd' >/dev/null 2>&1; then
        success "SSH service restarted (${sshd_unit})."
        return 0
      fi
      warn "systemctl restart ${sshd_unit} returned 0 but no sshd process — trying SIGHUP"
    else
      warn "systemctl restart ${sshd_unit} failed — trying SIGHUP"
    fi
  fi

  # Layer 2: SIGHUP the running master (reload config without killing
  # session children). Faster and less invasive than a full restart.
  local master_pid
  master_pid="$(pgrep -of '/usr/sbin/sshd' 2>/dev/null | head -1)"
  if [[ -n "$master_pid" ]] && kill -HUP "$master_pid" 2>/dev/null; then
    sleep 1
    if pgrep -f '/usr/sbin/sshd' >/dev/null 2>&1; then
      success "SSH service reloaded via SIGHUP (master pid ${master_pid})."
      return 0
    fi
  fi

  # Layer 3: clear systemd's failed-state memo and retry the restart.
  # If a previous restart attempt set the unit to "failed", subsequent
  # `systemctl restart` may return 0 without actually starting anything.
  if [[ -n "$sshd_unit" ]]; then
    systemctl reset-failed "$sshd_unit" 2>/dev/null || true
    if systemctl restart "$sshd_unit" 2>/dev/null; then
      sleep 1
      if pgrep -f '/usr/sbin/sshd' >/dev/null 2>&1; then
        success "SSH service restarted (${sshd_unit}) after reset-failed."
        return 0
      fi
    fi
  fi

  # Layer 4: try the other unit name as a last resort.
  for unit in ssh sshd; do
    [[ "$unit" == "$sshd_unit" ]] && continue
    if systemctl list-unit-files --no-legend "${unit}.service" 2>/dev/null | grep -q '\.service'; then
      if systemctl restart "$unit" 2>/dev/null; then
        sleep 1
        if pgrep -f '/usr/sbin/sshd' >/dev/null 2>&1; then
          success "SSH service restarted (${unit}, fallback)."
          return 0
        fi
      fi
    fi
  done

  warn "Could not restart SSH service automatically. Please restart it manually (e.g. 'systemctl restart ${sshd_unit:-ssh}' or reboot)."
  return 1
}

# Last-resort fail2ban install: clone upstream, `python3 setup.py install`,
# wire a systemd unit. Used only when both distro repo and EPEL lack the
# package. Heavy + slow; emit a clear warning so the operator knows why this
# path was taken.
_fail2ban_install_from_source() {
  command -v git    >/dev/null || dnf install -y git             2>/dev/null || { warn "git not available, source install aborted."; return 1; }
  command -v python3>/dev/null || dnf install -y python3 python3-pyinotify 2>/dev/null || true

  local workdir
  workdir="$(mktemp -d)"
  info "Cloning Fail2Ban into ${workdir}..."
  if ! git clone --depth 1 https://github.com/fail2ban/fail2ban.git "${workdir}/fail2ban"; then
    warn "git clone failed; aborting source install."
    rm -rf "$workdir"
    return 1
  fi
  ( cd "${workdir}/fail2ban" && python3 setup.py install )

  # Re-resolve paths now that the install actually happened.
  detect_fail2ban_paths

  if [[ -f "${workdir}/fail2ban/build/fail2ban.service" ]]; then
    sed -i "s|^ExecStart=.*|Environment=\"PYTHONPATH=${F2B_PYTHONPATH}\"\\nExecStart=${F2B_SERVER} -xf start|" \
      "${workdir}/fail2ban/build/fail2ban.service"
    cp "${workdir}/fail2ban/build/fail2ban.service" /etc/systemd/system/fail2ban.service
  else
    cat > /etc/systemd/system/fail2ban.service << EOF
[Unit]
Description=Fail2Ban Service
After=network.target

[Service]
Type=forking
ExecStart=${F2B_SERVER} -xf start
PIDFile=/var/run/fail2ban/fail2ban.pid
Environment="PYTHONPATH=${F2B_PYTHONPATH}"

[Install]
WantedBy=multi-user.target
EOF
  fi

  rm -f /etc/init.d/fail2ban
  mkdir -p /run/fail2ban /var/log/fail2ban
  systemctl daemon-reload
  rm -rf "$workdir"
  if ! systemctl enable --now fail2ban; then
    warn "Failed to start fail2ban via systemd, will retry after configuration..."
  fi
  success "Fail2Ban installed from source."
}

# Validate a candidate public key string. Returns 0 on success, non-zero on
# failure (and emits a warn explaining why).
validate_pubkey() {
  local key="$1"
  if [[ -z "$key" ]]; then
    warn "No key entered."
    return 1
  fi

  local prefix="${key%% *}"
  case "$prefix" in
    ssh-rsa|ssh-ed25519|ssh-dss| \
    ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521| \
    sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) ;;
    *)
      warn "Unrecognized key type '${prefix}'. Expected ssh-rsa, ssh-ed25519, ecdsa-*, or sk-* key."
      return 1
      ;;
  esac

  local rest="${key#"$prefix" }"
  local body="${rest%% *}"
  if [[ ${#body} -lt 68 ]]; then
    warn "Key body is suspiciously short (${#body} chars). Please paste the full key on a single line."
    return 1
  fi
  if [[ ! "$body" =~ ^[A-Za-z0-9+/=]+$ ]]; then
    warn "Key body contains non-base64 characters. The paste may have wrapped or been truncated."
    return 1
  fi
  return 0
}

# Print a confirmation preview for a public key: type, fingerprint, comment.
# Falls back to a truncated body preview if ssh-keygen is unavailable.
pubkey_fingerprint() {
  local key="$1"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$key" > "$tmp"

  if command -v ssh-keygen &>/dev/null; then
    local out
    if out="$(ssh-keygen -lf "$tmp" 2>/dev/null)"; then
      rm -f "$tmp"
      printf '  %s\n' "$out"
      return 0
    fi
  fi

  rm -f "$tmp"
  local prefix="${key%% *}"
  local rest="${key#"$prefix" }"
  local body="${rest%% *}"
  local comment="${rest#"$body"}"
  comment="${comment# }"
  printf '  type=%s body=%s... comment=%s\n' \
    "$prefix" "${body:0:40}" "${comment:-<none>}"
}

confirm_pubkey() {
  local key="$1"
  local confirm=""

  echo ""
  info "Public key preview:"
  pubkey_fingerprint "$key"
  echo ""

  read -rp "Add this key to authorized_keys? [Y/n]: " confirm
  confirm="${confirm:-Y}"
  [[ "$confirm" =~ ^[Yy]$ ]]
}

FETCHED_PUBKEYS=()
SELECTED_PUBKEY=""

fetch_pubkeys_from_url() {
  local url="$1"
  local response line valid_count=0
  FETCHED_PUBKEYS=()

  if [[ ! "$url" =~ ^https:// ]]; then
    warn "Only HTTPS key URLs are allowed."
    return 1
  fi
  if ! command -v curl &>/dev/null; then
    warn "curl is required to fetch public keys. Falling back to paste mode."
    return 1
  fi
  if ! response="$(curl -fsSL --max-time 10 --max-filesize 65536 "$url")"; then
    warn "Could not fetch public keys from ${url}."
    return 1
  fi
  if [[ -z "$response" ]]; then
    warn "No public keys found at ${url}."
    return 1
  fi

  while IFS= read -r line; do
    line="${line%$'\r'}"
    line="${line%"${line##*[![:space:]]}"}"
    line="${line#"${line%%[![:space:]]*}"}"
    if validate_pubkey "$line" >/dev/null 2>&1; then
      FETCHED_PUBKEYS+=("$line")
      ((valid_count++)) || true
    fi
  done <<< "$response"

  if [[ $valid_count -eq 0 ]]; then
    warn "Fetched data did not contain any valid SSH public keys."
    return 1
  fi
}

fetch_pubkeys_from_source() {
  local source="$1"
  local url=""

  case "$source" in
    gh:*)
      local username="${source#gh:}"
      if [[ ! "$username" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
        warn "Invalid GitHub username '${username}'."
        return 1
      fi
      url="https://github.com/${username}.keys"
      ;;
    url:https://*)
      url="${source#url:}"
      ;;
    https://*)
      url="$source"
      ;;
    *)
      warn "Unknown key source '${source}'. Use paste, gh:<username>, or https://..."
      return 1
      ;;
  esac

  fetch_pubkeys_from_url "$url"
}

select_fetched_pubkey() {
  local source="$1"
  local choice=""
  SELECTED_PUBKEY=""

  fetch_pubkeys_from_source "$source" || return 1

  if [[ ${#FETCHED_PUBKEYS[@]} -eq 1 ]]; then
    SELECTED_PUBKEY="${FETCHED_PUBKEYS[0]}"
    return 0
  fi

  echo ""
  info "Found ${#FETCHED_PUBKEYS[@]} valid public keys. Choose one to install:"
  local i
  for i in "${!FETCHED_PUBKEYS[@]}"; do
    printf '  [%d]\n' "$((i + 1))"
    pubkey_fingerprint "${FETCHED_PUBKEYS[$i]}"
  done
  echo ""

  while true; do
    read -rp "Enter key number [1-${#FETCHED_PUBKEYS[@]}]: " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#FETCHED_PUBKEYS[@]} )); then
      SELECTED_PUBKEY="${FETCHED_PUBKEYS[$((choice - 1))]}"
      return 0
    fi
    warn "Please enter a number between 1 and ${#FETCHED_PUBKEYS[@]}."
  done
}

read_pubkey_interactively() {
  local pub_key=""
  SELECTED_PUBKEY=""

  while true; do
    echo ""
    info "Paste your local machine's SSH public key, then press ENTER on a blank line."
    info "Accepted formats: ssh-rsa, ssh-ed25519, ecdsa-sha2-nistp256/384/521, sk-* hardware keys."
    echo ""

    pub_key="$(read_pubkey_block)"
    validate_pubkey "$pub_key" || continue

    if confirm_pubkey "$pub_key"; then
      SELECTED_PUBKEY="$pub_key"
      return 0
    fi
    warn "Key not confirmed. Let's try again."
  done
}

choose_pubkey() {
  local source=""

  while true; do
    echo ""
    info "Choose how to provide your SSH public key:"
    info "  paste              Paste the key manually (default)"
    info "  gh:<username>      Fetch public keys from GitHub"
    info "  https://...        Fetch public keys from an HTTPS URL"
    read -rp "Public key source [paste]: " source
    source="${source:-paste}"

    if [[ "$source" == "paste" ]]; then
      read_pubkey_interactively
      return 0
    fi

    if select_fetched_pubkey "$source"; then
      validate_pubkey "$SELECTED_PUBKEY" || continue
      if confirm_pubkey "$SELECTED_PUBKEY"; then
        return 0
      fi
      warn "Key not confirmed. Let's try again."
    else
      warn "Falling back to manual paste."
      read_pubkey_interactively
      return 0
    fi
  done
}

# -----------------------------------------------------------------------------
# Step 3: Configure SSH Key Authentication
# -----------------------------------------------------------------------------
step_3_ssh_key_auth() {
  step "Step 3: Configure SSH Key Authentication"

  local ssh_dir="/home/${NEW_USER}/.ssh"
  local auth_keys="${ssh_dir}/authorized_keys"

  mkdir -p "$ssh_dir"
  chmod 700 "$ssh_dir"
  chown "${NEW_USER}:${NEW_USER}" "$ssh_dir"

  choose_pubkey

  if [[ -f "$auth_keys" ]] && grep -qF "$SELECTED_PUBKEY" "$auth_keys"; then
    warn "Public key already present in authorized_keys. Skipping."
  else
    echo "$SELECTED_PUBKEY" >> "$auth_keys"
    success "Public key added to ${auth_keys}."
  fi

  chmod 600 "$auth_keys"
  chown "${NEW_USER}:${NEW_USER}" "$auth_keys"

  success "SSH key authentication configured for user '${NEW_USER}'."
}

# -----------------------------------------------------------------------------
# Step 4 helpers
# -----------------------------------------------------------------------------

# Pick a random SSH port in [10000, 65535]. Best-effort avoid ports already
# listening locally. Echoes the port; never fails (the prompt is the safety
# net if the rare collision-exhaustion case happens).
pick_random_ssh_port() {
  local min=10000 max=65535 candidate="" attempt
  for attempt in 1 2 3 4 5; do
    if command -v shuf &>/dev/null; then
      candidate="$(shuf -i ${min}-${max} -n 1)"
    else
      candidate="$(awk -v min="$min" -v max="$max" \
        'BEGIN{srand(); print int(min + rand() * (max - min + 1))}')"
    fi
    if command -v ss &>/dev/null; then
      if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${candidate}\$"; then
        continue
      fi
    fi
    printf '%s' "$candidate"
    return 0
  done
  warn "Could not find a free random port after 5 attempts; offering ${candidate} anyway."
  printf '%s' "$candidate"
}

# -----------------------------------------------------------------------------
# Step 4: Harden SSH Configuration
# -----------------------------------------------------------------------------
step_4_harden_ssh() {
  step "Step 4: Harden SSH Configuration"

  local sshd_config="/etc/ssh/sshd_config"

  # Resolve SSH_PORT: --ssh-port flag wins; otherwise prompt with a random default.
  if [[ -n "${SSH_PORT_FLAG:-}" ]]; then
    SSH_PORT="$SSH_PORT_FLAG"
    info "Using SSH port ${SSH_PORT} (from --ssh-port)"
  else
    local default_port
    default_port="$(pick_random_ssh_port)"
    while true; do
      read -rp "Enter custom SSH port [default: ${default_port}]: " SSH_PORT
      SSH_PORT="${SSH_PORT:-$default_port}"
      if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1024 && SSH_PORT <= 65535 )); then
        break
      else
        warn "Port must be a number between 1024 and 65535."
      fi
    done
  fi

  info "Backing up ${sshd_config} to ${sshd_config}.bak"
  cp "$sshd_config" "${sshd_config}.bak"

  # Helper: set or replace a directive in sshd_config.
  # Only touches top-level (column-0) directives so Match blocks below are
  # left alone. If the key appears in multiple Match blocks, those overrides
  # intentionally win — that's the user's intent, not the script's to flatten.
  set_sshd_option() {
    local key="$1"
    local value="$2"
    # Replace any existing top-level (un-indented) directive, commented or not.
    sed -i "s/^${key}[[:space:]].*/${key} ${value}/" "$sshd_config"
    sed -i "s/^#[[:space:]]*${key}[[:space:]].*/${key} ${value}/" "$sshd_config"
    # If the key is not present at all at top level, append it.
    if ! grep -qE "^${key}[[:space:]]" "$sshd_config"; then
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
  restart_ssh_service

  warn "IMPORTANT: Do NOT close this session yet!"
  warn "Open a NEW terminal and verify you can connect with:"
  warn "  ssh -p ${SSH_PORT} ${NEW_USER}@<your_server_ip>"
  echo ""
  # `|| true` because `read` returns non-zero on EOF (Ctrl-D); under `set -e`
  # that would kill the script mid-confirmation. The second-terminal test is
  # the actual safety net.
  read -rp "Press ENTER once you have confirmed the new SSH connection works, then this script will continue..." || true
}

# -----------------------------------------------------------------------------
# Step 6: Install and Configure Fail2Ban
# -----------------------------------------------------------------------------
step_6_fail2ban() {
  step "Step 6: Install and Configure Fail2Ban"

  # Resolve concrete paths once per run. Source-install (/usr/local/...) wins
  # over distro paths so the override and the install test always target the
  # same binary — previously these were hardcoded to /usr/local/... which
  # silently no-op'd on distro-package installs.
  detect_fail2ban_paths
  info "fail2ban-server: ${F2B_SERVER}"
  info "fail2ban-client: ${F2B_CLIENT}"
  [[ -n "$F2B_PYTHONPATH" ]] && info "fail2ban PYTHONPATH: ${F2B_PYTHONPATH}"

  # Check if Fail2Ban is already installed and offer to reinstall
  if command -v fail2ban-server &>/dev/null || command -v fail2ban-client &>/dev/null; then
    info "Fail2Ban appears to be already installed"
    read -rp "Do you want to reinstall/reconfigure Fail2Ban? [y/N]: " reinstall_choice
    reinstall_choice="${reinstall_choice:-N}"
    if [[ "$reinstall_choice" =~ ^[Yy]$ ]]; then
      info "Uninstalling existing Fail2Ban..."
      # Stop service
      systemctl stop fail2ban 2>/dev/null || true
      systemctl disable fail2ban 2>/dev/null || true
      # Try different uninstall methods
      case "$PKG_MANAGER" in
        apt)
          apt remove -y fail2ban 2>/dev/null || true
          ;;
        dnf)
          dnf remove -y fail2ban 2>/dev/null || true
          ;;
        pacman)
          pacman -R --noconfirm fail2ban 2>/dev/null || true
          ;;
      esac
      # Remove pip version if installed
      pip3 uninstall -y fail2ban 2>/dev/null || true
      # Remove source installation
      rm -f /usr/local/bin/fail2ban-* 2>/dev/null || true
      rm -rf /usr/local/lib/python*/site-packages/fail2ban* 2>/dev/null || true
      rm -f /etc/systemd/system/fail2ban.service 2>/dev/null || true
      systemctl daemon-reload 2>/dev/null || true
      success "Fail2Ban uninstalled"
    else
      info "Skipping Fail2Ban installation"
      return 0
    fi
  fi

  case "$PKG_MANAGER" in
    apt)
      info "Installing Fail2Ban..."
      apt install -y fail2ban
      ;;
    dnf)
      info "Installing Fail2Ban..."
      # Order: distro repo → EPEL → source. Source is last resort because the
      # git+setup.py path is slow, fragile, and pulls PyPI deps on a fresh VPS.
      # `dnf install fail2ban` covers RHEL 9+ (BaseOS) and Alma/Rocky 9+ once
      # EPEL is enabled. The previous @fail2ban/fail2ban COPR is gone, so we
      # no longer probe it.
      if dnf install -y fail2ban 2>/dev/null; then
        :
      elif dnf install -y epel-release 2>/dev/null && dnf install -y fail2ban 2>/dev/null; then
        :
      else
        warn "fail2ban not in distro/EPEL repos — falling back to source install."
        _fail2ban_install_from_source
      fi
      ;;
    pacman)
      info "Installing Fail2Ban..."
      pacman -S --noconfirm fail2ban
      ;;
  esac

  # PYTHONPATH fixup for the SOURCE-install path. Distro packages put the
  # module in dist-packages under the system python and don't need this.
  if [[ -f /etc/systemd/system/fail2ban.service ]] \
      && [[ ! -f /usr/lib/systemd/system/fail2ban.service ]] \
      && ! grep -q 'PYTHONPATH' /etc/systemd/system/fail2ban.service 2>/dev/null; then
    info "Patching source-install fail2ban.service with PYTHONPATH..."
    sed -i "s|^ExecStart=.*|Environment=\"PYTHONPATH=${F2B_PYTHONPATH}\"\\nExecStart=${F2B_SERVER} -xf start|" \
      /etc/systemd/system/fail2ban.service
    systemctl daemon-reload
  fi

  # Apply fail2ban race condition fix - create systemd override to wait for socket
  info "Applying fail2ban race condition fix..."
  mkdir -p /etc/systemd/system/fail2ban.service.d
  cat > /etc/systemd/system/fail2ban.service.d/override.conf << EOF
[Service]
ExecStartPost=/bin/bash -c 'for i in {1..30}; do test -S /var/run/fail2ban/fail2ban.sock && break; sleep 0.5; done; ${F2B_CLIENT} ping || exit 1'
EOF
  info "Reloading systemd daemon to apply override..."
  systemctl daemon-reload
  success "Fail2ban race condition fix applied."

  # Enable and start Fail2Ban service (only if not already handled in install)
  if systemctl is-active fail2ban &>/dev/null; then
    success "Fail2Ban is already running via systemd."
  elif pgrep -f fail2ban-server > /dev/null; then
    success "Fail2Ban is already running."
  else
    if systemctl list-unit-files --no-legend fail2ban.service 2>/dev/null | grep -q '\.service'; then
      info "Testing Fail2Ban configuration..."
      if ! PYTHONPATH="${F2B_PYTHONPATH}" "${F2B_SERVER}" -t 2>&1; then
        warn "Fail2Ban configuration test failed, attempting to fix..."
        mkdir -p /run/fail2ban /var/log/fail2ban
        chmod 755 /run/fail2ban /var/log/fail2ban
      fi
      systemctl start fail2ban
    else
      # Manual start as fallback (no systemd unit). The previous version
      # backgrounded with `nohup ... &` but did not `disown`, so the child was
      # tied to the script's session; we add `disown` and run from /root so
      # relative paths in the unit resolve cleanly.
      info "Starting Fail2Ban server manually..."
      mkdir -p /run/fail2ban /var/log/fail2ban
      ( cd /root && nohup env "PYTHONPATH=${F2B_PYTHONPATH}" "${F2B_SERVER}" -xf start \
          > /var/log/fail2ban/fail2ban.log 2>&1 & disown ) || true
      sleep 2
    fi
  fi

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

  # Detect SSH log file location
  local sshd_log="/var/log/secure"
  if [[ -f /var/log/auth.log ]]; then
    sshd_log="/var/log/auth.log"
  elif [[ -f /var/log/messages ]]; then
    sshd_log="/var/log/messages"
  fi
  info "Using SSH log file: $sshd_log"

  # Remove any existing [sshd] block and re-insert a clean one. The old
  # `sed` approach couldn't safely rewrite the block boundaries, and the
  # previous f-string heredoc leaked variables through shell interpolation;
  # the standalone script reads the file from disk, which is the only safe
  # boundary.
  python3 - <<'PYEOF' "$jail_local" "$sshd_log" "$SSH_PORT"
import re, sys

jail_local, sshd_log, ssh_port = sys.argv[1], sys.argv[2], sys.argv[3]

with open(jail_local, "r") as f:
    content = f.read()

sshd_block = f"""

[sshd]
enabled  = true
port     = {ssh_port}
logpath  = {sshd_log}
backend  = auto
maxretry = 3
bantime  = 3600
"""

# Remove existing [sshd] section (from [sshd] header to next section or EOF)
content = re.sub(
    r'\[sshd\].*?(?=\n\[|\Z)',
    '',
    content,
    flags=re.DOTALL,
)

content = content.rstrip() + "\n" + sshd_block

with open(jail_local, "w") as f:
    f.write(content)

print("jail.local updated successfully.")
PYEOF

  info "Restarting Fail2Ban..."
  if systemctl list-unit-files --no-legend fail2ban.service 2>/dev/null | grep -q '\.service'; then
    # Ensure override is in place (race condition fix)
    if [[ ! -f /etc/systemd/system/fail2ban.service.d/override.conf ]]; then
      info "Recreating fail2ban race condition fix..."
      mkdir -p /etc/systemd/system/fail2ban.service.d
      cat > /etc/systemd/system/fail2ban.service.d/override.conf << EOF
[Service]
ExecStartPost=/bin/bash -c 'for i in {1..30}; do test -S /var/run/fail2ban/fail2ban.sock && break; sleep 0.5; done; ${F2B_CLIENT} ping || exit 1'
EOF
    fi
    # Make sure the service file has PYTHONPATH (source-install only)
    if [[ -f /etc/systemd/system/fail2ban.service ]] \
        && [[ ! -f /usr/lib/systemd/system/fail2ban.service ]] \
        && ! grep -q 'PYTHONPATH' /etc/systemd/system/fail2ban.service 2>/dev/null; then
      info "Adding PYTHONPATH to existing fail2ban.service..."
      sed -i "s|^ExecStart=.*|Environment=\"PYTHONPATH=${F2B_PYTHONPATH}\"\\nExecStart=${F2B_SERVER} -xf start|" \
        /etc/systemd/system/fail2ban.service
    fi
    systemctl daemon-reload
    systemctl restart fail2ban
  else
    # Service exists but not running, start it
    systemctl start fail2ban
  fi
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
# Rollback: restore SSH access from sshd_config.bak
# -----------------------------------------------------------------------------
do_rollback() {
  local sshd_config="/etc/ssh/sshd_config"
  local sshd_bak="${sshd_config}.bak"
  local saved_port=""

  step "Rollback: restore SSH access on port 22"

  # Recover the custom SSH port (best-effort; used for firewall cleanup).
  saved_port="$(get_step_info "step_4" || true)"
  if [[ -z "$saved_port" && -n "${SSH_PORT_FLAG:-}" ]]; then
    saved_port="$SSH_PORT_FLAG"
  fi
  if [[ -n "$saved_port" ]]; then
    info "Recovered custom SSH port from state: ${saved_port}"
  else
    info "No recorded SSH port — will not remove a custom port from the firewall."
  fi

  # Confirmation gate (skipped under --yes).
  if [[ "${ASSUME_YES:-false}" != true ]]; then
    echo ""
    warn "This will:"
    warn "  - Restore ${sshd_bak} → ${sshd_config} (re-enables port 22 and password auth)"
    if [[ -n "$saved_port" && "$saved_port" != "22" ]]; then
      warn "  - Reopen 22/tcp and remove ${saved_port}/tcp from the firewall"
    else
      warn "  - Reopen 22/tcp in the firewall"
    fi
    warn "  - Stop fail2ban and unban all currently banned IPs"
    warn "  - Restart sshd"
    warn "User account, packages, and auto-updates are left intact."
    echo ""
    local confirm=""
    read -rp "Proceed with rollback? [y/N]: " confirm
    confirm="${confirm:-N}"
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
      info "Rollback aborted."
      return 1
    fi
  fi

  # 1. Restore sshd_config from backup, or die with manual instructions.
  if [[ -f "$sshd_bak" ]]; then
    local bak_mtime
    bak_mtime="$(stat -c '%y' "$sshd_bak" 2>/dev/null || stat -f '%Sm' "$sshd_bak" 2>/dev/null || echo unknown)"
    info "Restoring ${sshd_bak} (mtime: ${bak_mtime}) → ${sshd_config}"
    cp -p "$sshd_bak" "$sshd_config"
    success "sshd_config restored."
  else
    error "${sshd_bak} not found — cannot auto-restore."
    cat <<'MANUAL' >&2

Manual recovery (run as root):
  sed -i 's/^\s*Port .*/Port 22/' /etc/ssh/sshd_config
  sed -i 's/^\s*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
  sed -i 's/^\s*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
  # Reopen port 22 in your firewall, e.g.:
  #   ufw allow 22/tcp
  #   firewall-cmd --permanent --add-port=22/tcp && firewall-cmd --reload
MANUAL
    die "Aborting rollback: no backup to restore."
  fi

  # 2. Firewall: reopen 22/tcp and (if known) remove the custom port.
  case "${PKG_MANAGER:-}" in
    apt|pacman)
      if command -v ufw &>/dev/null; then
        info "UFW: allow 22/tcp"
        ufw allow 22/tcp || warn "ufw allow 22/tcp failed — check 'ufw status' manually."
        if [[ -n "$saved_port" && "$saved_port" != "22" ]]; then
          info "UFW: delete allow ${saved_port}/tcp"
          ufw delete allow "${saved_port}/tcp" 2>/dev/null \
            || warn "ufw delete allow ${saved_port}/tcp failed (rule may not exist)."
        fi
      else
        warn "UFW not installed; skipping firewall changes."
      fi
      ;;
    dnf)
      if command -v firewall-cmd &>/dev/null; then
        info "firewalld: --add-port=22/tcp (permanent)"
        firewall-cmd --permanent --add-port=22/tcp \
          || warn "firewall-cmd add-port=22/tcp failed."
        if [[ -n "$saved_port" && "$saved_port" != "22" ]]; then
          info "firewalld: --remove-port=${saved_port}/tcp (permanent)"
          firewall-cmd --permanent --remove-port="${saved_port}/tcp" 2>/dev/null \
            || warn "firewall-cmd remove-port=${saved_port}/tcp failed (rule may not exist)."
        fi
        firewall-cmd --reload || warn "firewall-cmd --reload failed."
      else
        warn "firewall-cmd not installed; skipping firewall changes."
      fi
      ;;
    *)
      warn "Unknown package manager '${PKG_MANAGER:-unset}'; skipping firewall changes."
      ;;
  esac

  # 3. Fail2Ban: unban first (needs running daemon), then stop. Best-effort.
  if [[ -z "${F2B_CLIENT:-}" ]]; then
    detect_fail2ban_paths
  fi
  if [[ -x "$F2B_CLIENT" ]]; then
    "$F2B_CLIENT" unban --all 2>/dev/null || true
  fi
  info "Stopping fail2ban..."
  systemctl stop fail2ban 2>/dev/null || true

  # 4. Restart sshd (shared helper from step 5).
  info "Restarting SSH service..."
  restart_ssh_service

  # 5. Summary banner.
  echo ""
  echo -e "${BOLD}${GREEN}============================================================${RESET}"
  echo -e "${BOLD}${GREEN}  Rollback Complete${RESET}"
  echo -e "${BOLD}${GREEN}============================================================${RESET}"
  echo ""
  echo -e "  ${BOLD}SSH port:${RESET}       22 (restored from sshd_config.bak)"
  echo -e "  ${BOLD}Password auth:${RESET}  Re-enabled (per restored config)"
  echo -e "  ${BOLD}Fail2Ban:${RESET}       Stopped"
  echo ""
  echo -e "  ${YELLOW}Next:${RESET} log in on port 22, then re-run"
  echo -e "         ${BOLD}sudo bash setup.sh${RESET} to harden again."
  echo ""
  echo -e "${BOLD}${GREEN}============================================================${RESET}"
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
  local start_step=1
  local skip_prereq=false
  local rollback=false
  ASSUME_YES=false
  SSH_PORT_FLAG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --resume|-r)
        resume=true
        ;;
      --clear-state|-c)
        clear_state=true
        ;;
      --start-step|-s)
        start_step="${2:-1}"
        shift
        ;;
      --skip-prereq|-n)
        skip_prereq=true
        ;;
      --ssh-port=*)
        SSH_PORT_FLAG="${1#*=}"
        ;;
      --ssh-port|-p)
        SSH_PORT_FLAG="${2:-}"
        shift
        ;;
      --rollback)
        rollback=true
        ;;
      --yes|-y)
        ASSUME_YES=true
        ;;
      --help|-h)
        echo "Usage: $0 [OPTIONS]"
        echo ""
        echo "Options:"
        echo "  --resume, -r          Resume from previous interrupted run"
        echo "  --clear-state, -c     Clear state file and start fresh"
        echo "  --start-step, -s N    Start from step N (1-7)"
        echo "  --skip-prereq, -n     Skip prerequisite installation"
        echo "  --ssh-port, -p N      Set SSH port (1024-65535); skips the prompt"
        echo "  --rollback            Restore sshd_config.bak, reopen port 22, stop fail2ban"
        echo "  --yes, -y             Skip confirmation prompts (for --rollback)"
        echo "  --help, -h            Show this help message"
        echo ""
        echo "Steps:"
        echo "  1. Update System Packages"
        echo "  2. Create Non-Root Sudo User"
        echo "  3. Configure SSH Key Authentication"
        echo "  4. Harden SSH Configuration"
        echo "  5. Configure Firewall"
        echo "  6. Install and Configure Fail2Ban"
        echo "  7. Enable Automatic Security Updates"
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

  # Validate --ssh-port flag value
  if [[ -n "$SSH_PORT_FLAG" ]]; then
    if ! [[ "$SSH_PORT_FLAG" =~ ^[0-9]+$ ]] || (( SSH_PORT_FLAG < 1024 || SSH_PORT_FLAG > 65535 )); then
      error "Invalid --ssh-port value '${SSH_PORT_FLAG}'. Must be a number between 1024 and 65535."
      exit 1
    fi
  fi

  # Validate --start-step: must be 1..7
  if ! [[ "$start_step" =~ ^[0-9]+$ ]] || (( start_step < 1 || start_step > 7 )); then
    error "Invalid --start-step value '${start_step}'. Must be an integer between 1 and 7."
    exit 1
  fi

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

  # Rollback path: restore SSH access and exit before touching the 7 steps.
  if [[ "$rollback" == true ]]; then
    do_rollback
    exit $?
  fi

  # Check prerequisites first
  check_prerequisites || install_prerequisites

  # Step 1: Update packages (start_step=1)
  if [[ $start_step -le 1 ]] && ! skip_if_completed "step_1"; then
    step_1_update_packages
    mark_step_completed "step_1"
  fi

  # Step 2: Create user (start_step=2)
  if [[ $start_step -le 2 ]] && ! skip_if_completed "step_2"; then
    step_2_create_user
    mark_step_completed "step_2" "$NEW_USER"
  else
    # Restore NEW_USER from state if resuming
    NEW_USER=$(get_step_info "step_2")
    if [[ -n "$NEW_USER" ]]; then
      info "Restored user: $NEW_USER"
    fi
  fi

  # Step 3: SSH key auth (start_step=3)
  if [[ $start_step -le 3 ]] && ! skip_if_completed "step_3"; then
    step_3_ssh_key_auth
    mark_step_completed "step_3"
  fi

  # Step 4: Harden SSH (start_step=4)
  if [[ $start_step -le 4 ]] && ! skip_if_completed "step_4"; then
    step_4_harden_ssh
    mark_step_completed "step_4" "$SSH_PORT"
  else
    # Restore SSH_PORT from state if resuming
    SSH_PORT=$(get_step_info "step_4")
    if [[ -n "$SSH_PORT" ]]; then
      info "Restored SSH port: $SSH_PORT"
    fi
  fi

  # Step 5: Firewall (start_step=5)
  if [[ $start_step -le 5 ]] && ! skip_if_completed "step_5"; then
    step_5_configure_firewall
    mark_step_completed "step_5"
  fi

  # Step 6: Fail2Ban (start_step=6)
  if [[ $start_step -le 6 ]] && ! skip_if_completed "step_6"; then
    step_6_fail2ban
    mark_step_completed "step_6"
  fi

  # Step 7: Auto updates (start_step=7)
  if [[ $start_step -le 7 ]] && ! skip_if_completed "step_7"; then
    step_7_auto_updates
    mark_step_completed "step_7"
  fi

  print_summary
}

main "$@"
