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
