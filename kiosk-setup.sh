#!/bin/bash
# Kiosk Setup Script
# Automatically sets up a full-screen video kiosk on Raspberry Pi
# Usage: ./kiosk-setup.sh

set -e  # Exit on error

echo "=========================================="
echo "Kiosk Setup Script"
echo "=========================================="
echo ""

# Check if running as root
if [ "$EUID" -eq 0 ]; then
   echo "Error: Please do not run this script as root"
   echo "Usage: ./kiosk-setup.sh"
   exit 1
fi

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_HOME="$HOME"
USERNAME="$(whoami)"

echo "Installing required packages..."
sudo apt-get update -qq
sudo apt-get install -y unclutter socat mpv yt-dlp xorg xinit

echo ""
echo "Copying kiosk.sh script from repository..."

# Copy the main kiosk script from repo
if [ -f "$SCRIPT_DIR/kiosk.sh" ]; then
	cp "$SCRIPT_DIR/kiosk.sh" "$USER_HOME/kiosk.sh"
	chmod +x "$USER_HOME/kiosk.sh"
	echo "Copied: $USER_HOME/kiosk.sh"
else
	echo "Error: kiosk.sh not found in repository directory"
	exit 1
fi

echo ""
echo "Creating default kiosk.url file..."

# Create default URL file if it doesn't exist
if [ ! -f "$USER_HOME/kiosk.url" ]; then
	cat > "$USER_HOME/kiosk.url" << 'URL_FILE_EOF'
https://www.youtube.com/watch?v=AeMUdOPFcXI
https://www.youtube.com/live/ydYDqZQpim8?si=WUlVMVqe0pC16Gc0
URL_FILE_EOF
	echo "Created: $USER_HOME/kiosk.url"
else
	echo "kiosk.url already exists, skipping..."
fi

echo ""
echo "Copying kiosk monitor script from repository..."

# Copy the monitor script from repo
if [ -f "$SCRIPT_DIR/kiosk-monitor.sh" ]; then
	cp "$SCRIPT_DIR/kiosk-monitor.sh" "$USER_HOME/kiosk-monitor.sh"
	chmod +x "$USER_HOME/kiosk-monitor.sh"
	echo "Copied: $USER_HOME/kiosk-monitor.sh"
else
	echo "Error: kiosk-monitor.sh not found in repository directory"
	exit 1
fi

echo ""
echo "Creating systemd service for kiosk monitor..."

# Create systemd service
sudo tee /etc/systemd/system/kiosk-monitor.service > /dev/null << SERVICE_EOF
[Unit]
Description=Kiosk Monitor - Restart X on crash
After=getty@tty1.service

[Service]
Type=simple
ExecStart=$USER_HOME/kiosk-monitor.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SERVICE_EOF

echo "Created: /etc/systemd/system/kiosk-monitor.service"

echo ""
echo "Configuring autologin for $USERNAME on tty1..."

# Create autologin configuration
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << AUTOLOGIN_EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USERNAME --noclear %I \$TERM
AUTOLOGIN_EOF

echo "Created: /etc/systemd/system/getty@tty1.service.d/autologin.conf"

echo ""
echo "Configuring user profile to start X automatically..."

# Backup existing profile if it exists
if [ -f "$USER_HOME/.profile" ]; then
	cp "$USER_HOME/.profile" "$USER_HOME/.profile.backup.$(date +%Y%m%d%H%M%S)"
fi

# Check if startx command already exists in profile
if ! grep -q "startx.*kiosk.sh" "$USER_HOME/.profile" 2>/dev/null; then
	# Add startx to profile
	cat >> "$USER_HOME/.profile" << 'PROFILE_EOF'

# Auto-start X with kiosk on tty1
if [ -z "$DISPLAY" ] && [ $(tty) = /dev/tty1 ]; then
    startx /home/USERNAMEPLACEHOLDER/kiosk.sh
fi
PROFILE_EOF

	# Replace placeholder with actual username
	sed -i "s|USERNAMEPLACEHOLDER|$USERNAME|g" "$USER_HOME/.profile"
	echo "Updated: $USER_HOME/.profile"
else
	echo ".profile already configured for kiosk, skipping..."
fi

echo ""
echo "Enabling and starting kiosk monitor service..."

# Reload systemd, enable and start the monitor service
sudo systemctl daemon-reload
sudo systemctl enable kiosk-monitor.service
sudo systemctl start kiosk-monitor.service

echo ""
echo "=========================================="
echo "Kiosk Setup Complete!"
echo "=========================================="
echo ""
echo "Files created:"
echo "  - $USER_HOME/kiosk.sh (copied from repository)"
echo "  - $USER_HOME/kiosk.url (URL list - edit this to change videos)"
echo "  - $USER_HOME/kiosk-monitor.sh (copied from repository)"
echo "  - /etc/systemd/system/kiosk-monitor.service"
echo "  - /etc/systemd/system/getty@tty1.service.d/autologin.conf"
echo ""
echo "Features:"
echo "  ✓ Auto-login on tty1"
echo "  ✓ Auto-start X with kiosk"
echo "  ✓ Auto-restart on crash"
echo "  ✓ Smart shuffle rotation (plays all URLs before repeating)"
echo "  ✓ Smooth video transitions via mpv IPC"
echo "  ✓ Configurable rotation intervals (default 1 minute)"
echo "  ✓ Automatic log rotation at 1MB"
echo ""
echo "Usage:"
echo "  - Edit URLs: nano $USER_HOME/kiosk.url"
echo "  - Set rotation interval: Add '# N' as first line (N = minutes)"
echo "  - View logs: tail -f /tmp/kiosk.log"
echo "  - Restart: sudo pkill X"
echo "  - Reboot to start: sudo reboot"
echo ""
echo "Example URL file format:"
echo "  # 5                          ← Rotate every 5 minutes (optional)"
echo "  https://youtube.com/live/... ← URLs, one per line"
echo ""
echo "The kiosk will start automatically on next boot or login to tty1"
echo ""
