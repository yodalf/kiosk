#!/bin/bash
# Script to restart the kiosk
#
# The kiosk runs as a systemd service. Use systemctl to restart it.

echo "Restarting kiosk service..."
sudo systemctl restart kiosk.service

echo "Kiosk service restarted. Check status with:"
echo "  systemctl status kiosk.service"
