#!/bin/bash
# Simple script to restart the kiosk by killing X and letting autologin restart it

# Kill all X sessions
sudo pkill X

# Wait a moment
sleep 2

# If on console, autologin should restart X
# Otherwise, manually restart it
if [ -z "$DISPLAY" ]; then
    # We're on console, start X
    startx /home/realo/kiosk.sh &
fi
