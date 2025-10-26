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
echo "Creating kiosk.sh script..."

# Create the main kiosk script
cat > "$USER_HOME/kiosk.sh" << 'KIOSK_SCRIPT_EOF'
#!/bin/bash
xset -dpms      # Disable DPMS (Energy Star) features
xset s off      # Disable screen saver
xset s noblank  # Don't blank the video device
unclutter &     # Hide mouse cursor (install with: sudo apt install unclutter)

# URL file location
URL_FILE="$(dirname "$0")/kiosk.url"
DEFAULT_URL="https://www.youtube.com/watch?v=AeMUdOPFcXI"
MPV_SOCKET="/tmp/mpvsocket"

# Function to read all URLs from file
read_urls() {
	if [ -f "$URL_FILE" ]; then
		grep -v '^[[:space:]]*$' "$URL_FILE" | grep -v '^#'
	else
		echo "Warning: kiosk.url file not found at $URL_FILE, using default URL" >&2
		echo "$DEFAULT_URL"
	fi
}

# Function to get random URL from the list
# Usage: get_random_url [previous_url]
# If previous_url is provided and there are multiple URLs, avoid selecting it again
get_random_url() {
	local previous_url="$1"
	local url_list
	url_list=$(read_urls)
	local count=$(echo "$url_list" | grep -c '^')

	if [ $count -eq 0 ]; then
		echo "$DEFAULT_URL"
		return
	fi

	# If only one URL, return it
	if [ $count -eq 1 ]; then
		echo "$url_list"
		return
	fi

	# If multiple URLs and we have a previous URL, avoid it
	if [ -n "$previous_url" ]; then
		local new_url
		local attempts=0
		local max_attempts=50

		while [ $attempts -lt $max_attempts ]; do
			local random_line=$((RANDOM % count + 1))
			new_url=$(echo "$url_list" | sed -n "${random_line}p")

			if [ "$new_url" != "$previous_url" ]; then
				echo "$new_url"
				return
			fi

			attempts=$((attempts + 1))
		done

		# Fallback: if we somehow keep getting the same URL, just return any different one
		echo "$url_list" | grep -v "^${previous_url}$" | head -n1
	else
		# No previous URL, just pick random
		local random_line=$((RANDOM % count + 1))
		echo "$url_list" | sed -n "${random_line}p"
	fi
}

# Function to count URLs in file
count_urls() {
	read_urls | wc -l
}

# Function to send command to mpv via IPC
mpv_command() {
	local cmd="$1"
	echo "$cmd" | socat - "$MPV_SOCKET" 2>/dev/null > /dev/null
}

# Function to load a URL in mpv
load_url() {
	local url="$1"
	echo "$(date '+%Y-%m-%d %H:%M:%S') - Loading URL: $url" >> /tmp/kiosk.log
	mpv_command "loadfile \"$url\" replace"
	echo "$(date '+%Y-%m-%d %H:%M:%S') - Load command sent" >> /tmp/kiosk.log
}

# Cleanup function
cleanup() {
	echo "$(date '+%Y-%m-%d %H:%M:%S') - Shutting down kiosk" >> /tmp/kiosk.log
	if [ -n "$MPV_PID" ]; then
		kill $MPV_PID 2>/dev/null
		wait $MPV_PID 2>/dev/null
	fi
	rm -f "$MPV_SOCKET"
	exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# Start mpv in IPC mode
echo "Starting mpv in kiosk mode with IPC..."
mpv --idle \
	--force-window \
	--fullscreen \
	--no-osd-bar \
	--osd-level=0 \
	--no-border \
	--ytdl-format=best \
	--input-ipc-server="$MPV_SOCKET" \
	--hwdec=auto \
	--really-quiet &

MPV_PID=$!

# Wait for mpv to start and create socket
echo "Waiting for mpv to initialize..."
TIMEOUT=10
while [ ! -S "$MPV_SOCKET" ] && [ $TIMEOUT -gt 0 ]; do
	sleep 0.5
	TIMEOUT=$((TIMEOUT - 1))
	if ! kill -0 $MPV_PID 2>/dev/null; then
		echo "Error: mpv failed to start" >&2
		exit 1
	fi
done

if [ ! -S "$MPV_SOCKET" ]; then
	echo "Error: mpv socket not created" >&2
	exit 1
fi

echo "mpv started successfully"

# Initial URL read
CURRENT_URL=$(get_random_url)
URL_COUNT=$(count_urls)
echo "$(date '+%Y-%m-%d %H:%M:%S') - Starting kiosk with URL: $CURRENT_URL (${URL_COUNT} URLs available)" | tee -a /tmp/kiosk.log

# Load initial URL
load_url "$CURRENT_URL"

# Track time for rotation (60 seconds = 1 minute)
ELAPSED=0
CHECK_INTERVAL=2

# Main monitoring loop
echo "$(date '+%Y-%m-%d %H:%M:%S') - Entering main monitoring loop" >> /tmp/kiosk.log
while true; do
	# Check if mpv is still running
	if ! kill -0 $MPV_PID 2>/dev/null; then
		echo "$(date '+%Y-%m-%d %H:%M:%S') - Error: mpv process died, exiting" >> /tmp/kiosk.log
		exit 1
	fi

	# Check if the URL file has changed (different number of URLs)
	NEW_URL_COUNT=$(count_urls)
	if [ "$NEW_URL_COUNT" != "$URL_COUNT" ]; then
		echo "$(date '+%Y-%m-%d %H:%M:%S') - URL file changed (${URL_COUNT} -> ${NEW_URL_COUNT} URLs)" >> /tmp/kiosk.log
		URL_COUNT=$NEW_URL_COUNT
		CURRENT_URL=$(get_random_url "$CURRENT_URL")
		echo "$(date '+%Y-%m-%d %H:%M:%S') - Switching to new random URL: $CURRENT_URL" >> /tmp/kiosk.log
		load_url "$CURRENT_URL"
		ELAPSED=0  # Reset timer after manual switch
	fi

	# If multiple URLs, rotate every 60 seconds
	if [ "$URL_COUNT" -gt 1 ] && [ "$ELAPSED" -ge 60 ]; then
		echo "$(date '+%Y-%m-%d %H:%M:%S') - Timer triggered (ELAPSED=$ELAPSED, URL_COUNT=$URL_COUNT)" >> /tmp/kiosk.log
		CURRENT_URL=$(get_random_url "$CURRENT_URL")
		echo "$(date '+%Y-%m-%d %H:%M:%S') - Rotating to new random URL: $CURRENT_URL" >> /tmp/kiosk.log
		load_url "$CURRENT_URL"
		ELAPSED=0  # Reset timer
	fi

	sleep $CHECK_INTERVAL

	# Only increment timer if we have multiple URLs
	if [ "$URL_COUNT" -gt 1 ]; then
		ELAPSED=$((ELAPSED + CHECK_INTERVAL))
	fi
done
KIOSK_SCRIPT_EOF

chmod +x "$USER_HOME/kiosk.sh"
echo "Created: $USER_HOME/kiosk.sh"

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
echo "Creating kiosk monitor script..."

# Create the monitor script
cat > "$USER_HOME/kiosk-monitor.sh" << 'MONITOR_SCRIPT_EOF'
#!/bin/bash
# Monitor script to restart getty@tty1 if X dies

while true; do
    # Check if X is running
    if ! pgrep -x X > /dev/null && ! pgrep -x Xorg > /dev/null; then
        echo "$(date): X not running, restarting getty@tty1" >> /var/log/kiosk-monitor.log
        systemctl restart getty@tty1
    fi

    sleep 10
done
MONITOR_SCRIPT_EOF

chmod +x "$USER_HOME/kiosk-monitor.sh"
echo "Created: $USER_HOME/kiosk-monitor.sh"

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
echo "  - $USER_HOME/kiosk.sh (main kiosk script)"
echo "  - $USER_HOME/kiosk.url (URL list - edit this to change videos)"
echo "  - $USER_HOME/kiosk-monitor.sh (monitor script)"
echo "  - /etc/systemd/system/kiosk-monitor.service"
echo "  - /etc/systemd/system/getty@tty1.service.d/autologin.conf"
echo ""
echo "Features:"
echo "  ✓ Auto-login on tty1"
echo "  ✓ Auto-start X with kiosk"
echo "  ✓ Auto-restart on crash"
echo "  ✓ Multi-URL support with random rotation"
echo "  ✓ Smooth video transitions via mpv IPC"
echo "  ✓ 60-second rotation when multiple URLs present"
echo ""
echo "Usage:"
echo "  - Edit URLs: nano $USER_HOME/kiosk.url"
echo "  - View logs: tail -f /tmp/kiosk.log"
echo "  - Restart: sudo pkill X"
echo "  - Reboot to start: sudo reboot"
echo ""
echo "The kiosk will start automatically on next boot or login to tty1"
echo ""
