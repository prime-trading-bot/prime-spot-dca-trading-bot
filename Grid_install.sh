#!/bin/bash

# =======================================================
# Prime Spot Grid Trading Bot - Auto Installer (Standalone)
# Version: 1.4 (Production Hardened + safe download)
# =======================================================

# 1. Configuration
VERSION="V1.0"
ARCHIVE_NAME="Grid_server.tar.xz"
DOWNLOAD_URL="https://github.com/prime-trading-bot/prime-spot-grid-trading-bot/releases/download/$VERSION/$ARCHIVE_NAME"
INSTALL_DIR="/opt/Prime-Spot-Grid-Trading-Bot"
APP_DIR="$INSTALL_DIR/Grid_server"
SERVICE_NAME="primespotgrid"
SERVICE_USER="primegrid"

# 2. Check for Root (Required for installation steps)
if [ "$EUID" -ne 0 ]; then
  echo "Error: You need to run this script with root privileges."
  echo "Run the command: sudo bash Grid_install.sh"
  exit 1
fi

# 3. Create Dedicated System User (Prevents 217/USER & preserves non-root machine-id fingerprint)
if ! id -u "$SERVICE_USER" >/dev/null 2>&1; then
    useradd --system --no-create-home --shell /usr/sbin/nologin "$SERVICE_USER"
fi
SERVICE_GROUP=$(id -gn "$SERVICE_USER")

echo "=================================================="
echo "Starting Installation ($VERSION)..."
echo "Service Account: $SERVICE_USER:$SERVICE_GROUP"
echo "=================================================="

# 4. Detect OS family & Install Dependencies
if command -v apt-get >/dev/null 2>&1; then
    OS_FAMILY="debian"
    echo ">>>Detected Debian/Ubuntu family OS. Installing curl, ufw, tar, xz-utils, psmisc..."
    apt-get update -qq >/dev/null
    apt-get install -y curl ufw tar xz-utils psmisc >/dev/null
elif command -v yum >/dev/null 2>&1; then
    OS_FAMILY="redhat"
    echo ">>>Detected RedHat/Amazon Linux/CentOS family OS. Installing curl, tar, xz, psmisc..."
    yum update -y -q >/dev/null 2>&1
    yum install -y curl tar xz psmisc >/dev/null 2>&1
    echo ">>>Skipping ufw setup - please make sure port 8764 is open in your Cloud Firewall/Security Group."
else
    OS_FAMILY="unknown"
    echo "Warning: Neither apt-get nor yum was found. Skipping automatic dependency install."
    echo "         Please make sure 'curl', 'tar', 'xz', and 'fuser' (psmisc) are installed manually before continuing."
fi

# 5. Configure Firewall & Background Apt Limits (Debian/Ubuntu only)
if [ "$OS_FAMILY" = "debian" ]; then
    echo ">>>Configuring Firewall..."
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow 8764/tcp >/dev/null 2>&1
    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable >/dev/null 2>&1
    fi

    echo ">>>Applying memory guardrails (120M) to apt-daily background timers..."
    for u in apt-daily apt-daily-upgrade; do
        mkdir -p "/etc/systemd/system/${u}.service.d"
        printf '[Service]\nMemoryHigh=120M\nNice=19\nIOSchedulingClass=idle\n' > "/etc/systemd/system/${u}.service.d/limit.conf"
    done
fi

# 5.5. Auto-configure 1GB Swap (Universal: GCP ext4, AWS EC2 XFS, DigitalOcean...)
if [ "$(swapon --show | wc -l)" -eq 0 ]; then
    AVAIL_DISK_MB=$(df -m / | awk 'NR==2 {print $4}')
    if [ -n "$AVAIL_DISK_MB" ] && [ "$AVAIL_DISK_MB" -gt 2560 ]; then
        echo ">>>No active swap detected (Free disk: ${AVAIL_DISK_MB}MB). Creating 1GB persistent swapfile..."
        rm -f /swapfile
        dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1
        if swapon /swapfile; then
            grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
            sysctl -w vm.swappiness=10 >/dev/null 2>&1
            if [ -f /etc/sysctl.conf ]; then
                grep -q 'vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
            fi
            echo ">>>1GB Swap configured and enabled successfully."
        else
            echo "Warning: Could not enable /swapfile (possibly unprivileged container). Cleaning up..."
            rm -f /swapfile
        fi
    else
        echo ">>>Skipping Swap creation: Less than 2.5GB free disk space available (${AVAIL_DISK_MB}MB)."
    fi
else
    echo ">>>Active swap already exists. Skipping swap creation."
fi

# 5.9. Download FIRST and validate it, so a failed/404 download can never leave the bot without a binary
echo ">>>Downloading Server Archive ($ARCHIVE_NAME)..."
mkdir -p "$INSTALL_DIR"
rm -f "$INSTALL_DIR/$ARCHIVE_NAME"
if ! curl -fL --progress-bar "$DOWNLOAD_URL" -o "$INSTALL_DIR/$ARCHIVE_NAME"; then
    echo "Error: Download failed (HTTP error or no internet). Existing installation was NOT touched."
    rm -f "$INSTALL_DIR/$ARCHIVE_NAME"
    exit 1
fi
if ! tar -tf "$INSTALL_DIR/$ARCHIVE_NAME" 2>/dev/null | grep -q 'Grid_server\.bin$'; then
    echo "Error: Downloaded archive is corrupt or does not contain Grid_server.bin. Existing installation was NOT touched."
    rm -f "$INSTALL_DIR/$ARCHIVE_NAME"
    exit 1
fi

# 6. Setup Directory & Clean up Old Processes
echo ">>>Creating base directory at $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

echo ">>>Stopping existing service (if running)..."
systemctl stop $SERVICE_NAME 2>/dev/null || true

echo ">>>Freeing up port 8764 (killing zombie processes if any)..."
fuser -k -9 8764/tcp >/dev/null 2>&1 || true
sleep 1

# 8. Extract Archive
echo ">>>Extracting files into $APP_DIR..."

# --- BACKUP DATA ---
BACKUP_DIR="$INSTALL_DIR/.backup_$(date +%s)"   # on disk, NOT /tmp (tmpfs lives in RAM)
if [ -d "$APP_DIR" ]; then
    echo ">>>Backing up configuration and state files..."
    mkdir -p "$BACKUP_DIR"
    
    cp "$APP_DIR/grid_config.enc" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$APP_DIR/grid_server_state.json" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$APP_DIR/grid_server_state.enc" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$APP_DIR/grid_license.sig" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$APP_DIR/.device_seed" "$BACKUP_DIR/" 2>/dev/null || true
    
    cp "$APP_DIR/grid_server_cert.pem" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$APP_DIR/grid_server_key.pem" "$BACKUP_DIR/" 2>/dev/null || true
    
    cp "$APP_DIR"/grid_server.log* "$BACKUP_DIR/" 2>/dev/null || true
    cp "$APP_DIR"/trades*.log "$BACKUP_DIR/" 2>/dev/null || true
    cp "$APP_DIR/trades_log_index.txt" "$BACKUP_DIR/" 2>/dev/null || true
fi
# --- END OF BACKUP ---

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"

tar -xf "$INSTALL_DIR/$ARCHIVE_NAME" -C "$APP_DIR" --strip-components=1
rm -f "$INSTALL_DIR/$ARCHIVE_NAME"

# --- RESTORE DATA ---
if [ -d "$BACKUP_DIR" ]; then
    echo ">>>Restoring configuration and state files..."
    cp -a "$BACKUP_DIR/." "$APP_DIR/" 2>/dev/null || true
    rm -rf "$BACKUP_DIR"
fi
# --- END OF RESTORE ---

# 9. Set Permissions & Ownership
echo ">>>Setting executable permissions and ownership for $SERVICE_USER..."
chmod +x "$APP_DIR/Grid_server.bin"
chmod 600 "$APP_DIR/grid_server_key.pem" "$APP_DIR/grid_config.enc" "$APP_DIR/grid_license.sig" 2>/dev/null || true
chown -R "$SERVICE_USER:$SERVICE_GROUP" "$INSTALL_DIR"

# 10. Create Systemd Service
echo ">>>Creating Service..."
cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Prime Grid Trading Bot Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SERVICE_USER
Group=$SERVICE_GROUP
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/Grid_server.bin
Restart=always
RestartSec=5
StandardOutput=null
StandardError=append:$APP_DIR/server.error.log
NoNewPrivileges=true

# Memory guardrails for 1GB RAM VPS. A little swap is allowed so cold pages can leave RAM (keeps code
# pages hot = avoids the page-cache thrashing seen on this VPS), but a runaway leak is still cut off:
# RAM > 500M or swap > 256M -> kernel kills the bot and systemd restarts it after 5s.
MemoryHigh=420M
MemoryMax=500M
MemorySwapMax=256M

[Install]
WantedBy=multi-user.target
EOF

# 11. Start Service
systemctl daemon-reload
systemctl enable $SERVICE_NAME >/dev/null 2>&1
systemctl restart $SERVICE_NAME

# 12. Final Check
sleep 2
IS_ACTIVE=$(systemctl is-active $SERVICE_NAME)

echo "=================================================="
if [ "$IS_ACTIVE" == "active" ]; then
    SERVER_IP=$(curl -s ifconfig.me)
    echo "INSTALLATION SUCCESSFUL!"
    echo "Server IP: $SERVER_IP"
    echo "Port: 8764"
    echo ""
    echo "View Log:  sudo tail -f $APP_DIR/grid_server.log"
    echo "Stop Bot:  sudo systemctl stop $SERVICE_NAME"
else
    echo "⚠️  WARNING: Bot installed but failed to start."
    echo "    Check errors: sudo cat $APP_DIR/server.error.log"
fi
echo "=================================================="