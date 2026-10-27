#!/bin/bash

# =======================================================
# Prime Spot DCA Trading Bot - Auto Installer (Standalone)
# Version: 1.5 (Multi-provider hardened, based on the Grid installer 1.5.1)
#
# Supported : Linux with systemd on x86_64
#             - Debian / Ubuntu                      (apt)
#             - Amazon Linux / Oracle Linux / RHEL   (dnf / yum)
# Not supported: containers without systemd, ARM CPUs
# =======================================================

# 1. Configuration
VERSION="v5.1"
ARCHIVE_NAME="server_v5.tar.xz"
DOWNLOAD_URL="https://github.com/prime-trading-bot/prime-spot-dca-trading-bot/releases/download/$VERSION/$ARCHIVE_NAME"
INSTALL_DIR="/opt/Prime-Spot-DCA-Trading-Bot"
APP_DIR="$INSTALL_DIR/server"
SERVICE_NAME="primespotdca"
SERVICE_USER="primedca"
BOT_PORT=8765

SUPPORTED_ARCH="x86_64"       # the released binary is built for x86_64 only
SMALL_VPS_RAM_MB=3000         # swap + apt limits are only applied on VPS with less RAM than this
MIN_RAM_FOR_LIMITS_MB=800     # below this a memory cap cannot protect the bot, so none is set
SWAP_SIZE_MB=1024

# 2. Pre-flight checks (nothing is modified before these pass)
if [ "$EUID" -ne 0 ]; then
  echo "Error: You need to run this script with root privileges."
  echo "Run the command: sudo bash install.sh"
  exit 1
fi

if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
  echo "Error: this installer needs a Linux system running systemd."
  exit 1
fi

ARCH=$(uname -m)
if [ "$ARCH" != "$SUPPORTED_ARCH" ]; then
  echo "Error: unsupported CPU architecture '$ARCH'. This server build runs on $SUPPORTED_ARCH only."
  echo "       (ARM servers such as AWS Graviton or Oracle Ampere are not supported by this release.)"
  exit 1
fi

# 3. Detect system facts
MEM_TOTAL_MB=$(awk '/^MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)
MEM_TOTAL_MB=${MEM_TOTAL_MB:-0}

SYSTEMD_VER=$(systemctl --version 2>/dev/null | awk 'NR==1 {print $2}')
SYSTEMD_VER=${SYSTEMD_VER%%[!0-9]*}
SYSTEMD_VER=${SYSTEMD_VER:-0}

CGROUP_V2=0
[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null)" = "cgroup2fs" ] && CGROUP_V2=1

# Memory limits (MemoryHigh / MemoryMax / MemorySwapMax) need cgroup v2 + systemd >= 240
CAN_LIMIT=0
if [ "$CGROUP_V2" = 1 ] && [ "$SYSTEMD_VER" -ge 240 ] && [ "$MEM_TOTAL_MB" -ge "$MIN_RAM_FOR_LIMITS_MB" ]; then
  CAN_LIMIT=1
fi
# Escape hatch: run  sudo SKIP_MEMORY_LIMITS=1 bash install.sh  to install without MemoryHigh/MemoryMax
[ "${SKIP_MEMORY_LIMITS:-0}" = "1" ] && CAN_LIMIT=0

# MemoryMax = 52% of RAM (min 500M, max 1500M); MemoryHigh = 84% of MemoryMax
# (a 1GB VPS gives the proven 420M / 500M pair)
calc_mem_limits() {
  MEM_MAX_MB=$(( $1 * 52 / 100 ))
  [ "$MEM_MAX_MB" -lt 500 ]  && MEM_MAX_MB=500
  [ "$MEM_MAX_MB" -gt 1500 ] && MEM_MAX_MB=1500
  MEM_HIGH_MB=$(( MEM_MAX_MB * 84 / 100 ))
}

# Package manager
OS_FAMILY="unknown"
PKG_MGR=""
if command -v apt-get >/dev/null 2>&1; then
  OS_FAMILY="debian"
elif command -v dnf >/dev/null 2>&1; then
  OS_FAMILY="redhat"; PKG_MGR="dnf"
elif command -v yum >/dev/null 2>&1; then
  OS_FAMILY="redhat"; PKG_MGR="yum"
fi

# 4. Choose the service account
#    New installs run as the dedicated user 'primedca' (no login, no home directory).
#    EXCEPTION: an install that ALREADY runs as root keeps running as root. The license device id
#    comes from the DMI product_uuid (readable by root only) or, for normal users, from /etc/machine-id.
#    Moving a root install to 'primedca' would change that id and the license would be rejected
#    ("bound to a different device").
NOLOGIN_SHELL=$(command -v nologin 2>/dev/null || echo /usr/sbin/nologin)
LEGACY_ROOT=0
OLD_UNIT="/etc/systemd/system/$SERVICE_NAME.service"
if [ -f "$OLD_UNIT" ]; then
  OLD_USER=$(sed -n 's/^User=//p' "$OLD_UNIT" | head -n1 | tr -d '[:space:]')
  if [ -z "$OLD_USER" ] || [ "$OLD_USER" = "root" ]; then LEGACY_ROOT=1; fi
elif [ -f "$APP_DIR/license.sig" ] && [ "$(stat -c %u "$APP_DIR/license.sig" 2>/dev/null)" = "0" ]; then
  LEGACY_ROOT=1
fi

if [ "$LEGACY_ROOT" = 1 ]; then
  SERVICE_USER="root"
  SERVICE_GROUP="root"
  echo "Notice: the existing installation runs as root, so it keeps running as root"
  echo "        (this keeps your license device id unchanged)."
else
  if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell "$NOLOGIN_SHELL" "$SERVICE_USER"
  fi
  SERVICE_GROUP=$(id -gn "$SERVICE_USER")
fi

echo "=================================================="
echo "Starting Installation ($VERSION)..."
echo "Service Account: $SERVICE_USER:$SERVICE_GROUP"
echo "System: $OS_FAMILY | RAM: ${MEM_TOTAL_MB}MB | systemd: $SYSTEMD_VER | cgroup v2: $CGROUP_V2"
echo "=================================================="

if [ "$MEM_TOTAL_MB" -lt 900 ]; then
  echo "Warning: this VPS has less than ~1GB RAM. 1GB or more is recommended for stable operation."
fi

# 5. Install ONLY the missing dependencies (never runs a full OS update)
# usage: install_missing "command:debian-package:redhat-package" ...
install_missing() {
  local to_install="" spec cmd rest deb rpm
  for spec in "$@"; do
    cmd=${spec%%:*}; rest=${spec#*:}; deb=${rest%%:*}; rpm=${rest#*:}
    if ! command -v "$cmd" >/dev/null 2>&1; then
      if [ "$OS_FAMILY" = "debian" ]; then to_install="$to_install $deb"; else to_install="$to_install $rpm"; fi
    fi
  done
  [ -z "$to_install" ] && return 0
  echo ">>>Installing missing packages:$to_install"
  if [ "$OS_FAMILY" = "debian" ]; then
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y $to_install >/dev/null 2>&1
  elif [ "$OS_FAMILY" = "redhat" ]; then
    $PKG_MGR install -y $to_install >/dev/null 2>&1
  else
    echo "Warning: no supported package manager found. Please install manually:$to_install"
    return 1
  fi
}

if [ "$OS_FAMILY" = "debian" ]; then
  install_missing "curl:curl:curl" "tar:tar:tar" "xz:xz-utils:xz" "fuser:psmisc:psmisc" "ufw:ufw:ufw"
else
  install_missing "curl:curl:curl" "tar:tar:tar" "xz:xz-utils:xz" "fuser:psmisc:psmisc"
fi

for tool in curl tar xz; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Error: required tool '$tool' is missing and could not be installed. Install it manually and run again."
    exit 1
  fi
done

# 6. Firewall (host level). Your cloud provider's own firewall must ALSO allow the port.
echo ">>>Configuring firewall..."
FIREWALL_NOTE="none (no supported host firewall found)"
if [ "$OS_FAMILY" = "debian" ] && command -v ufw >/dev/null 2>&1; then
  SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port / {print $2; exit}')
  SSH_PORT=${SSH_PORT:-22}
  ufw allow "${SSH_PORT}/tcp" >/dev/null 2>&1
  ufw allow "${BOT_PORT}/tcp" >/dev/null 2>&1
  if ! ufw status | grep -q "Status: active"; then
    echo "y" | ufw enable >/dev/null 2>&1
  fi
  FIREWALL_NOTE="ufw (SSH port $SSH_PORT and $BOT_PORT allowed)"
elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
  firewall-cmd --permanent --add-port="${BOT_PORT}/tcp" >/dev/null 2>&1
  firewall-cmd --reload >/dev/null 2>&1
  FIREWALL_NOTE="firewalld ($BOT_PORT allowed)"
fi
echo ">>>Host firewall: $FIREWALL_NOTE"
echo ">>>IMPORTANT: also open TCP port $BOT_PORT in your cloud provider's firewall"
echo "             (AWS Security Group / Oracle VCN Security List / Google VPC firewall rule)."

# 7. Limit apt background jobs (Debian/Ubuntu on small VPS only)
APT_NOTE="not applicable"
if [ "$OS_FAMILY" = "debian" ] && [ "$MEM_TOTAL_MB" -lt "$SMALL_VPS_RAM_MB" ] \
   && systemctl cat apt-daily.service >/dev/null 2>&1; then
  echo ">>>Limiting apt-daily background timers (RAM spikes on small VPS)..."
  for u in apt-daily apt-daily-upgrade; do
    mkdir -p "/etc/systemd/system/${u}.service.d"
    {
      echo "[Service]"
      [ "$CAN_LIMIT" = 1 ] && echo "MemoryHigh=120M"
      echo "Nice=19"
      echo "IOSchedulingClass=idle"
    } > "/etc/systemd/system/${u}.service.d/limit.conf"
  done
  APT_NOTE="limited"
fi

# 8. Swap (only on small VPS without swap, real VM, ext4/xfs-like filesystem, enough disk)
SWAP_NOTE="not needed"
if [ "$MEM_TOTAL_MB" -ge "$SMALL_VPS_RAM_MB" ]; then
  SWAP_NOTE="skipped (RAM >= ${SMALL_VPS_RAM_MB}MB)"
elif [ "$(wc -l < /proc/swaps)" -gt 1 ]; then
  SWAP_NOTE="already exists"
  echo ">>>Active swap already exists. Skipping swap creation."
else
  VIRT_CONT=$(systemd-detect-virt --container 2>/dev/null || true)
  ROOT_FS=$(stat -fc %T / 2>/dev/null)
  AVAIL_DISK_MB=$(df -Pm / | awk 'NR==2 {print $4}')
  MIN_DISK_MB=$(( SWAP_SIZE_MB + 1536 ))
  if [ -n "$VIRT_CONT" ] && [ "$VIRT_CONT" != "none" ]; then
    SWAP_NOTE="skipped (container: $VIRT_CONT)"
  elif [ "$ROOT_FS" = "btrfs" ] || [ "$ROOT_FS" = "zfs" ]; then
    SWAP_NOTE="skipped (swapfile not supported on $ROOT_FS)"
  elif [ -z "$AVAIL_DISK_MB" ] || [ "$AVAIL_DISK_MB" -le "$MIN_DISK_MB" ]; then
    SWAP_NOTE="skipped (only ${AVAIL_DISK_MB:-?}MB free disk, need > ${MIN_DISK_MB}MB)"
  else
    echo ">>>No active swap detected (Free disk: ${AVAIL_DISK_MB}MB). Creating ${SWAP_SIZE_MB}MB persistent swapfile..."
    rm -f /swapfile
    dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_SIZE_MB" status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null 2>&1
    if swapon /swapfile; then
      grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
      echo 'vm.swappiness=10' > /etc/sysctl.d/99-prime-bot-swap.conf
      sysctl -w vm.swappiness=10 >/dev/null 2>&1
      SWAP_NOTE="created (${SWAP_SIZE_MB}MB)"
      echo ">>>Swap configured and enabled successfully."
    else
      rm -f /swapfile
      SWAP_NOTE="failed (swapon refused - possibly a restricted VPS)"
      echo "Warning: Could not enable /swapfile. Cleaned up."
    fi
  fi
fi

# 9. Download FIRST and validate it, so a failed download can never leave the bot without a binary
echo ">>>Downloading Server Archive ($ARCHIVE_NAME)..."
mkdir -p "$INSTALL_DIR"
rm -f "$INSTALL_DIR/$ARCHIVE_NAME"
if ! curl -fL --retry 3 --retry-delay 2 --progress-bar "$DOWNLOAD_URL" -o "$INSTALL_DIR/$ARCHIVE_NAME"; then
  echo "Error: Download failed (HTTP error or no internet). Existing installation was NOT touched."
  rm -f "$INSTALL_DIR/$ARCHIVE_NAME"
  exit 1
fi
if ! tar -tf "$INSTALL_DIR/$ARCHIVE_NAME" 2>/dev/null | grep -q 'server\.bin$'; then
  echo "Error: Downloaded archive is corrupt or does not contain server.bin. Existing installation was NOT touched."
  rm -f "$INSTALL_DIR/$ARCHIVE_NAME"
  exit 1
fi

# 10. Stop old service & free the port
echo ">>>Stopping existing service (if running)..."
systemctl stop $SERVICE_NAME 2>/dev/null || true

echo ">>>Freeing up port $BOT_PORT (killing zombie processes if any)..."
if command -v fuser >/dev/null 2>&1; then
  fuser -k -9 "${BOT_PORT}/tcp" >/dev/null 2>&1 || true
fi
sleep 1

# 11. Extract Archive
echo ">>>Extracting files into $APP_DIR..."

# --- BACKUP DATA (on disk, NOT /tmp: /tmp lives in RAM on most distros) ---
BACKUP_DIR="$INSTALL_DIR/.backup_$(date +%s)"
if [ -d "$APP_DIR" ]; then
  echo ">>>Backing up configuration and state files..."
  mkdir -p "$BACKUP_DIR"

  cp "$APP_DIR/config.enc" "$BACKUP_DIR/" 2>/dev/null || true
  cp "$APP_DIR/license.sig" "$BACKUP_DIR/" 2>/dev/null || true
  cp "$APP_DIR/state_mainnet.json" "$BACKUP_DIR/" 2>/dev/null || true
  cp "$APP_DIR/state_testnet.json" "$BACKUP_DIR/" 2>/dev/null || true
  cp "$APP_DIR/isolated.json" "$BACKUP_DIR/" 2>/dev/null || true
  cp "$APP_DIR/.device_seed" "$BACKUP_DIR/" 2>/dev/null || true

  cp "$APP_DIR/trade_history.json" "$BACKUP_DIR/" 2>/dev/null || true
  cp "$APP_DIR"/trades*.log* "$BACKUP_DIR/" 2>/dev/null || true
  cp "$APP_DIR"/trading_bot.log* "$BACKUP_DIR/" 2>/dev/null || true

  cp "$APP_DIR/dca_server_cert.pem" "$BACKUP_DIR/" 2>/dev/null || true
  cp "$APP_DIR/dca_server_key.pem" "$BACKUP_DIR/" 2>/dev/null || true
fi
# --- END OF BACKUP ---

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"

tar -xf "$INSTALL_DIR/$ARCHIVE_NAME" -C "$APP_DIR" --strip-components=1
rm -f "$INSTALL_DIR/$ARCHIVE_NAME"

if [ ! -f "$APP_DIR/server.bin" ]; then
  echo "Error: extraction failed (server.bin not found)."
  [ -d "$BACKUP_DIR" ] && echo "       Your data backup is kept in: $BACKUP_DIR"
  exit 1
fi

# --- RESTORE DATA ---
if [ -d "$BACKUP_DIR" ]; then
  echo ">>>Restoring configuration and state files..."
  cp -a "$BACKUP_DIR/." "$APP_DIR/" 2>/dev/null || true
  rm -rf "$BACKUP_DIR"
fi
# --- END OF RESTORE ---

# 12. Set Permissions & Ownership
echo ">>>Setting executable permissions and ownership for $SERVICE_USER..."
chmod +x "$APP_DIR/server.bin"
chmod 600 "$APP_DIR/dca_server_key.pem" "$APP_DIR/config.enc" "$APP_DIR/license.sig" 2>/dev/null || true
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"
# SELinux (Oracle Linux / RHEL / Amazon Linux): make sure files carry the right security labels
command -v restorecon >/dev/null 2>&1 && restorecon -R "$INSTALL_DIR" >/dev/null 2>&1 || true

# 13. Create Systemd Service
echo ">>>Creating Service..."
if [ "$CAN_LIMIT" = 1 ]; then
  calc_mem_limits "$MEM_TOTAL_MB"
  MEM_LINES=$(printf '%s\n' \
    "# Memory guardrails, sized for this VPS (${MEM_TOTAL_MB}MB RAM). A runaway leak is cut off and restarted in 5s." \
    "# MemorySwapMax lets cold pages leave RAM but stops a leak from dragging the disk into swap thrashing." \
    "MemoryHigh=${MEM_HIGH_MB}M" \
    "MemoryMax=${MEM_MAX_MB}M" \
    "MemorySwapMax=256M")
  LIMIT_NOTE="MemoryHigh=${MEM_HIGH_MB}M MemoryMax=${MEM_MAX_MB}M MemorySwapMax=256M"
else
  MEM_LINES="# Memory guardrails skipped (need cgroup v2, systemd >= 240 and >= ${MIN_RAM_FOR_LIMITS_MB}MB RAM)."
  LIMIT_NOTE="skipped (need cgroup v2, systemd >= 240, RAM >= ${MIN_RAM_FOR_LIMITS_MB}MB)"
fi

# 'append:' needs systemd >= 240; older systemd sends stderr to the journal instead
if [ "$SYSTEMD_VER" -ge 240 ]; then
  ERR_LINE="StandardError=append:$APP_DIR/server.error.log"
  ERR_NOTE="$APP_DIR/server.error.log"
else
  ERR_LINE="StandardError=journal"
  ERR_NOTE="journalctl -u $SERVICE_NAME"
fi

cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Prime DCA Trading Bot Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/server.bin
Restart=always
RestartSec=5
StandardOutput=null
$ERR_LINE
NoNewPrivileges=true

$MEM_LINES

[Install]
WantedBy=multi-user.target
EOF

# 14. Start Service
systemctl daemon-reload
systemctl enable $SERVICE_NAME >/dev/null 2>&1
systemctl restart $SERVICE_NAME

# 15. Final Check (wait up to 10 seconds for the service to come up)
IS_ACTIVE="inactive"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  sleep 1
  IS_ACTIVE=$(systemctl is-active $SERVICE_NAME)
  [ "$IS_ACTIVE" = "active" ] && break
done

echo "=================================================="
if [ "$IS_ACTIVE" = "active" ]; then
  SERVER_IP=$(curl -s --max-time 5 ifconfig.me)
  echo "INSTALLATION SUCCESSFUL!"
  echo "Server IP: $SERVER_IP"
  echo "Port: $BOT_PORT"
  echo ""
  echo "Applied settings:"
  echo "  Host firewall : $FIREWALL_NOTE"
  echo "  Swap          : $SWAP_NOTE"
  echo "  apt limits    : $APT_NOTE"
  echo "  Memory limits : $LIMIT_NOTE"
  echo ""
  echo "View Log:  sudo tail -f $APP_DIR/trading_bot.log"
  echo "Stop Bot:  sudo systemctl stop $SERVICE_NAME"
else
  echo "⚠️  WARNING: Bot installed but failed to start."
  echo "    Check errors: $ERR_NOTE"
  echo "    Service log : sudo journalctl -u $SERVICE_NAME -n 30 --no-pager"
fi
echo "=================================================="
