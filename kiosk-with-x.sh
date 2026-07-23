#!/bin/bash
# X server wrapper for the kiosk service.  This is a template: kiosk-setup.sh
# substitutes USERNAME and installs the result in $HOME (same mechanism as the
# systemd unit templates).
#
# Redirect startx output to a log file instead of the TTY.  This prevents a
# first-boot race where the service's StandardInput=tty holds /dev/tty1 open
# while X is simultaneously trying to take exclusive VT control, which causes
# kiosk.sh to exit within seconds and X to shut down cleanly (exit 0).
# Restart=always in kiosk.service recovers automatically, but the redirect
# avoids the conflict entirely after the first successful start.
startx /home/USERNAME/kiosk.sh -- :0 vt1 > /tmp/kiosk-startx.log 2>&1
