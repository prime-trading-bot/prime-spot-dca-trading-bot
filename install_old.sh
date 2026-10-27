#!/bin/bash

# =======================================================
# Prime Spot Grid Trading Bot - Auto Installer (Standalone)
# Version: 1.0 (Grid Bot)
# =======================================================

# 1. Configuration
VERSION="V1.0"
ARCHIVE_NAME="Grid_server.tar.xz"
DOWNLOAD_URL="https://github.com/prime-trading-bot/prime-spot-grid-trading-bot/releases/download/$VERSION/$ARCHIVE_NAME"
INSTALL_DIR="/opt/Prime-Spot-Grid-Trading-Bot"
APP_DIR="$INSTALL_DIR/Grid_server"
SERVICE_NAME="primespotgrid"

# 2. Check for Root (Required for installation steps)
if [ "$EUID" -ne 0 ]; then
  echo "Error: You need to run this script with root privileges."
  echo "Run the command: sudo bash grid-install.sh"
  exit 1
fi

# 3. Detect Real User
REAL_USER=${SUDO_USER:-$USER}
REAL_GROUP=$(id -gn $REAL_USER)

echo "=================================================="
echo "Starting Installation ($VERSION)..."
echo "Installing for User: $REAL_USER"
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

# 5. Configure Firewall (Debian/Ubuntu only)
if [ "$OS_FAMILY" = "debian" ]; then
    echo ">>>Configuring Firewall..."
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow 8764/tcp >/dev/null 2>&1
    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable >/dev/null 2>&1
    fi
fi

# 6. Setup Directory & Clean up Old Processes
echo ">>>Creating base directory at $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"

echo ">>>Stopping existing service (if running)..."
systemctl stop $SERVICE_NAME 2>/dev/null || true

echo ">>>Freeing up port 8764 (killing zombie processes if any)..."
fuser -k -9 8764/tcp >/dev/null 2>&1 || true
sleep 1

# 7. Download
echo ">>>Downloading Server Archive ($ARCHIVE_NAME)..."
curl -L --progress-bar "$DOWNLOAD_URL" -o "$INSTALL_DIR/$ARCHIVE_NAME"

if [ ! -f "$INSTALL_DIR/$ARCHIVE_NAME" ]; then
    echo "Error: Download failed. Check link or internet."
    exit 1
fi

# 8. Extract Archive
echo ">>>Extracting files into $APP_DIR..."

# --- BACKUP DATA ---
BACKUP_DIR="/tmp/grid_bot_backup_$(date +%s)"
if [ -d "$APP_DIR" ]; then
    echo ">>>Backing up configuration and state files..."
    mkdir -p "$BACKUP_DIR"
    
	cp "$APP_DIR/grid_config.enc" "$BACKUP_DIR/" 2>/dev/null || true
    cp "$APP_DIR/grid_server_state.json" "$BACKUP_DIR/" 2>/dev/null || true
    # FIX BUG (total config/state loss on reinstall): pre-redesign installs kept EVERYTHING
    # (API key/secret + per-symbol grid params + runtime state) in this one combined, encrypted
    # file instead of the two above. If the currently-installed release predates the config/state
    # split, grid_config.enc / grid_server_state.json above don't exist yet and the two `cp`
    # lines above silently no-op -- so grid_server_state.enc, which is the ONLY copy of the
    # user's actual running configuration in that case, MUST also be backed up here, or it is
    # permanently deleted by `rm -rf "$APP_DIR"` below with nothing to restore from.
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
    cp "$BACKUP_DIR/"* "$APP_DIR/" 2>/dev/null || true
    rm -rf "$BACKUP_DIR"
fi
# --- END OF RESTORE ---

# 9. Set Permissions & Ownership
echo ">>>Setting executable permissions and ownership for user $REAL_USER..."
chmod +x "$APP_DIR/GridServer.bin"
chown -R $REAL_USER:$REAL_GROUP "$INSTALL_DIR"

# 10. Create Systemd Service
echo ">>>Creating Service..."
cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Prime Grid Trading Bot Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$REAL_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/Grid_server.bin
Restart=always
RestartSec=5
StandardOutput=append:$APP_DIR/server.log
StandardError=append:$APP_DIR/server.error.log
NoNewPrivileges=true

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
    echo "View Log:  tail -f $APP_DIR/server.log"
    echo "Stop Bot:  sudo systemctl stop $SERVICE_NAME"
else
    echo "⚠️  WARNING: Bot installed but failed to start."
    echo "    Check errors: cat $APP_DIR/server.error.log"
fi
echo "=================================================="
