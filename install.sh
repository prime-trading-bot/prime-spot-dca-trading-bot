#!/bin/bash

# =======================================================
# Prime Spot DCA Trading Bot - Auto Installer (Universal)
# Version: 1.1
# =======================================================

# 1. Configuration
VERSION="v5.0"
BINARY_NAME="server_v5.bin"
DOWNLOAD_URL="https://github.com/prime-trading-bot/prime-spot-dca-trading-bot/releases/download/$VERSION/$BINARY_NAME"
INSTALL_DIR="/opt/Prime-Spot-DCA-Trading-Bot"
SERVICE_NAME="primespotdca"

# 2. Check for Root (Required for installation steps)
if [ "$EUID" -ne 0 ]; then
  echo "Error: You need to run this script with root privileges."
  echo "Run the command: sudo bash install.sh"
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
# Supports both Debian/Ubuntu (apt) and RedHat/Amazon Linux/CentOS (yum) so the same script
# works on EC2 as well as other cloud providers, not just Ubuntu-based images.
if command -v apt-get >/dev/null 2>&1; then
    OS_FAMILY="debian"
    echo ">>>Detected Debian/Ubuntu family OS. Installing curl & ufw..."
    apt-get update -qq >/dev/null
    apt-get install -y curl ufw >/dev/null
elif command -v yum >/dev/null 2>&1; then
    OS_FAMILY="redhat"
    echo ">>>Detected RedHat/Amazon Linux/CentOS family OS. Installing curl..."
    yum update -y -q >/dev/null 2>&1
    yum install -y curl >/dev/null 2>&1
    # These distros typically rely on the cloud provider's Security Groups for port
    # management rather than a local firewall daemon, so ufw is skipped here.
    echo ">>>Skipping ufw setup - please make sure port 8765 is open in your Cloud Firewall/Security Group."
else
    OS_FAMILY="unknown"
    echo "Warning: Neither apt-get nor yum was found. Skipping automatic dependency install."
    echo "         Please make sure 'curl' is installed manually before continuing."
fi

# 5. Configure Firewall (Debian/Ubuntu only - see step 4 for RedHat family)
if [ "$OS_FAMILY" = "debian" ]; then
    echo ">>>Configuring Firewall..."
    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow 8765/tcp >/dev/null 2>&1
    if ! ufw status | grep -q "Status: active"; then
        echo "y" | ufw enable >/dev/null 2>&1
    fi
fi

# 6. Setup Directory & Download
echo ">>>Creating directory at $INSTALL_DIR..."
mkdir -p $INSTALL_DIR

# NOTE: the binary is deliberately re-downloaded (overwritten) every time this script runs.
# Re-running this installer is the intended way to update the bot to the latest build at
# $DOWNLOAD_URL - it is not a bug, and should not be changed to "skip if already present".
echo ">>>Downloading Server Binary..."
curl -L --progress-bar "$DOWNLOAD_URL" -o "$INSTALL_DIR/server.bin"

if [ ! -f "$INSTALL_DIR/server.bin" ]; then
    echo "Error: Download failed. Check link or internet."
    exit 1
fi

# 7. Set Permissions & Ownership
echo ">>>Setting permissions for user $REAL_USER..."
chmod +x "$INSTALL_DIR/server.bin"
chown -R $REAL_USER:$REAL_GROUP $INSTALL_DIR

# 8. Create Systemd Service
echo ">>>Creating Service..."
cat <<EOF > /etc/systemd/system/$SERVICE_NAME.service
[Unit]
Description=Prime Trading Bot Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$REAL_USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$INSTALL_DIR/server.bin
Restart=always
RestartSec=5
StandardOutput=append:$INSTALL_DIR/server.log
StandardError=append:$INSTALL_DIR/server.error.log
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

# 9. Start Service
systemctl daemon-reload
systemctl enable $SERVICE_NAME >/dev/null 2>&1
systemctl restart $SERVICE_NAME

# 10. Final Check
sleep 2
IS_ACTIVE=$(systemctl is-active $SERVICE_NAME)

echo "=================================================="
if [ "$IS_ACTIVE" == "active" ]; then
    SERVER_IP=$(curl -s ifconfig.me)
    echo "INSTALLATION SUCCESSFUL!"
    echo "Server IP: $SERVER_IP"
    echo "Port: 8765"
    echo ""
    echo "View Log:  tail -f $INSTALL_DIR/server.log"
    echo "Stop Bot:  sudo systemctl stop $SERVICE_NAME"
else
    echo "⚠️  WARNING: Bot installed but failed to start."
    echo "    Check errors: cat $INSTALL_DIR/server.error.log"
fi
echo "=================================================="
