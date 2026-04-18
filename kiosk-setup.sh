#!/bin/bash
# Kiosk Setup Script
# Sets up a fullscreen video kiosk on Raspberry Pi OS (Bookworm).
# Run on a fresh install with network already configured.
#
# Usage: ./kiosk-setup.sh
# Do NOT run as root.

set -e

# ─── Preflight Checks ──────────────────────────────────────────────────────

if [ "$EUID" -eq 0 ]; then
    echo "Error: Do not run this script as root."
    echo "Usage: ./kiosk-setup.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
USER_HOME="$HOME"
USERNAME="$(whoami)"

echo "=========================================="
echo "Kiosk Setup Script"
echo "=========================================="
echo ""
echo "User:  $USERNAME"
echo "Home:  $USER_HOME"
echo "Repo:  $SCRIPT_DIR"
echo ""

# ─── Install Packages ──────────────────────────────────────────────────────

echo "Installing required packages..."
sudo apt-get update -qq
sudo apt-get install -y unclutter socat mpv yt-dlp xorg xinit
echo ""

# ─── Copy Scripts ───────────────────────────────────────────────────────────

echo "Copying scripts to $USER_HOME..."

for script in kiosk.sh kiosk-monitor.sh restart-kiosk.sh; do
    if [ -f "$SCRIPT_DIR/$script" ]; then
        cp "$SCRIPT_DIR/$script" "$USER_HOME/$script"
        chmod +x "$USER_HOME/$script"
        echo "  Copied: $script"
    else
        echo "  Error: $script not found in repo"
        exit 1
    fi
done

# Copy all .url files from repo
for url_file in "$SCRIPT_DIR"/*.url; do
    if [ -f "$url_file" ]; then
        cp "$url_file" "$USER_HOME/$(basename "$url_file")"
        echo "  Copied: $(basename "$url_file")"
    fi
done
echo ""

# ─── Generate kiosk-with-x.sh ──────────────────────────────────────────────

echo "Generating kiosk-with-x.sh..."
cat > "$USER_HOME/kiosk-with-x.sh" << EOF
#!/bin/bash
startx /home/$USERNAME/kiosk.sh -- :0 vt1
EOF
chmod +x "$USER_HOME/kiosk-with-x.sh"
echo "  Created: $USER_HOME/kiosk-with-x.sh"
echo ""

# ─── Select URL File ───────────────────────────────────────────────────────

echo "Available URL files:"
URL_FILES=()
i=1
for url_file in "$USER_HOME"/*.url; do
    if [ -f "$url_file" ]; then
        name=$(basename "$url_file")
        URL_FILES+=("$name")
        url_count=$(grep -v '^[[:space:]]*$' "$url_file" | grep -vc '^#' || true)
        echo "  $i) $name ($url_count URLs)"
        i=$((i + 1))
    fi
done
echo ""

if [ ${#URL_FILES[@]} -eq 0 ]; then
    echo "No .url files found. Creating default kiosk.url..."
    cat > "$USER_HOME/kiosk.url" << 'EOF'
# 1
https://www.youtube.com/watch?v=AeMUdOPFcXI
EOF
    echo "  Created: kiosk.url with default URL"
else
    SELECTED=""
    while [ -z "$SELECTED" ]; do
        read -p "Select URL file to use as kiosk.url [1-${#URL_FILES[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#URL_FILES[@]} ]; then
            SELECTED="${URL_FILES[$((choice - 1))]}"
        else
            echo "  Invalid choice. Enter a number between 1 and ${#URL_FILES[@]}."
        fi
    done

    if [ "$SELECTED" = "kiosk.url" ]; then
        echo "  Using existing kiosk.url"
    else
        rm -f "$USER_HOME/kiosk.url"
        ln -s "$USER_HOME/$SELECTED" "$USER_HOME/kiosk.url"
        echo "  Linked: kiosk.url -> $SELECTED"
    fi
fi
echo ""

# ─── Install Systemd Services ──────────────────────────────────────────────

echo "Installing systemd services..."

sed "s|USERNAME|$USERNAME|g" "$SCRIPT_DIR/kiosk.service" \
    | sudo tee /etc/systemd/system/kiosk.service > /dev/null
echo "  Installed: kiosk.service"

sed "s|USERNAME|$USERNAME|g" "$SCRIPT_DIR/kiosk-monitor.service" \
    | sudo tee /etc/systemd/system/kiosk-monitor.service > /dev/null
echo "  Installed: kiosk-monitor.service (not enabled)"
echo ""

# ─── Install Xorg Configuration ───────────────────────────────────────────

echo "Installing Xorg configuration..."
sudo mkdir -p /etc/X11/xorg.conf.d
sudo cp "$SCRIPT_DIR/99-vc4.conf" /etc/X11/xorg.conf.d/99-vc4.conf
echo "  Installed: /etc/X11/xorg.conf.d/99-vc4.conf"
echo ""

# ─── Configure Autologin ───────────────────────────────────────────────────

echo "Configuring autologin on tty1..."
sudo mkdir -p /etc/systemd/system/getty@tty1.service.d
sudo tee /etc/systemd/system/getty@tty1.service.d/autologin.conf > /dev/null << EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $USERNAME --noclear %I \$TERM
Type=idle
EOF
echo "  Created: autologin.conf"
echo ""

# ─── Configure .bash_profile Fallback ───────────────────────────────────────

KIOSK_MARKER="# Auto-start X with kiosk on tty1"
BASH_PROFILE="$USER_HOME/.bash_profile"

if grep -q "$KIOSK_MARKER" "$BASH_PROFILE" 2>/dev/null; then
    echo ".bash_profile already configured, skipping."
else
    echo "Adding fallback block to .bash_profile..."
    cat >> "$BASH_PROFILE" << EOF

$KIOSK_MARKER
if [ -z "\$DISPLAY" ] && [ \$(tty) = /dev/tty1 ]; then
    #startx /home/$USERNAME/kiosk.sh
    true
fi
EOF
    echo "  Updated: .bash_profile"
fi
echo ""

# ─── Enable Services ───────────────────────────────────────────────────────

echo "Enabling kiosk service..."
sudo systemctl daemon-reload
sudo systemctl enable kiosk.service
echo ""

# ─── Summary ────────────────────────────────────────────────────────────────

echo "=========================================="
echo "Kiosk Setup Complete!"
echo "=========================================="
echo ""
echo "Installed files:"
echo "  $USER_HOME/kiosk.sh"
echo "  $USER_HOME/kiosk-with-x.sh"
echo "  $USER_HOME/kiosk-monitor.sh"
echo "  $USER_HOME/restart-kiosk.sh"
if [ -L "$USER_HOME/kiosk.url" ]; then
    echo "  $USER_HOME/kiosk.url -> $(readlink "$USER_HOME/kiosk.url")"
else
    echo "  $USER_HOME/kiosk.url"
fi
echo ""
echo "Systemd services:"
echo "  kiosk.service          (enabled, starts on boot)"
echo "  kiosk-monitor.service  (installed, not enabled)"
echo ""
echo "Next steps:"
echo "  1. Reboot to start the kiosk: sudo reboot"
echo "  2. Edit URLs: nano $USER_HOME/kiosk.url"
echo "  3. View logs: tail -f /tmp/kiosk.log"
echo "  4. Restart kiosk: sudo systemctl restart kiosk.service"
echo ""
