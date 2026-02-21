#!/bin/bash
# X server wrapper for kiosk service
# Note: setup script generates a user-specific version in $HOME
startx /home/$USER/kiosk.sh -- :0 vt1
