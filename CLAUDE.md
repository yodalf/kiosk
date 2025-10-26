# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Workflow Preferences

**IMPORTANT: Git Commit and Push Policy**
- NEVER automatically commit and push changes without explicit user instruction
- Always wait for the user to say "commit and push" or similar explicit instruction
- After making changes, show what was done and wait for approval to commit
- This preference applies to all sessions and all changes

## Project Overview

This is a video kiosk system designed for Raspberry Pi (though can run on other Linux systems). It creates a fullscreen video player that automatically plays and rotates through YouTube live streams or videos. The system uses mpv as the video player with IPC (Inter-Process Communication) for smooth transitions between videos without black screens.

## Key Architecture

### Core Components

1. **kiosk.sh** - Main kiosk script that runs mpv in IPC mode and manages video rotation
   - Uses mpv with `--input-ipc-server` for smooth video transitions via socket communication
   - Implements shuffle algorithm to ensure all URLs are played before repeating
   - Monitors for URL file changes and rotation interval updates
   - Logs to `/tmp/kiosk.log` with automatic rotation at 1MB

2. **kiosk-setup.sh** - One-time setup script that:
   - Installs dependencies (unclutter, socat, mpv, yt-dlp, xorg, xinit)
   - Creates kiosk.sh and kiosk-monitor.sh in user's home directory
   - Configures autologin on tty1
   - Sets up systemd service for monitoring X crashes
   - Adds auto-start to user's .profile

3. **kiosk-monitor.sh** - Watchdog that restarts getty@tty1 if X crashes

4. **URL files** (*.url) - Plain text files containing YouTube URLs, one per line
   - First line can optionally specify rotation interval: `# N` where N is minutes
   - Default rotation is 1 minute if not specified
   - Comments (lines starting with #) and blank lines are ignored

### Systemd Services

- **kiosk.service** - Runs the X session with kiosk.sh on tty7
- **kiosk-monitor.service** - Monitors X process and restarts getty@tty1 if it dies

### Video Rotation Logic

The kiosk uses a shuffle-based rotation system:
- Creates shuffled playlist in `/tmp/kiosk_shuffle.txt`
- Tracks position in `/tmp/kiosk_shuffle_index.txt`
- Plays all URLs once before reshuffling (avoids immediate repeats)
- Automatically detects URL list changes and regenerates shuffle
- Supports configurable rotation intervals via first line of .url file

## Development Commands

### Testing the kiosk script
```bash
# Test kiosk script directly (requires X session)
./kiosk.sh

# View logs in real-time
tail -f /tmp/kiosk.log

# Test with a specific URL file
# Edit the URL_FILE variable in kiosk.sh temporarily
```

### Managing URL files
```bash
# Edit URLs (one URL per line)
nano ~/kiosk.url  # or africa.url, world.url, etc.

# Set rotation interval (add as first line)
echo "# 5" > ~/kiosk.url  # Rotate every 5 minutes
```

### System service management
```bash
# Restart kiosk using systemctl
sudo systemctl restart kiosk.service

# Or use the restart script
./restart-kiosk.sh

# Check kiosk service status
systemctl status kiosk.service

# View kiosk monitor logs
sudo tail -f /var/log/kiosk-monitor.log

# Enable/disable auto-start
sudo systemctl enable kiosk.service   # Auto-start on boot
sudo systemctl disable kiosk.service  # Disable auto-start
```

### Installation
```bash
# Run setup (do NOT run as root)
./kiosk-setup.sh

# Reboot to start kiosk
sudo reboot
```

## Important Implementation Details

### MPV IPC Communication
- Socket path: `/tmp/mpvsocket`
- Commands sent via `socat` to avoid black screens between videos
- mpv runs in `--idle` mode to stay alive without active media
- `loadfile` command with `replace` flag used for smooth transitions

### Shuffle Algorithm
The shuffle ensures fair rotation without immediate repeats:
1. Read all URLs and create shuffled list
2. Play URLs sequentially from shuffled list
3. When all URLs played, reshuffle and repeat
4. If URL file changes, immediately reshuffle

### URL File Format
```
# 5                                    ← Optional: rotation interval in minutes
https://www.youtube.com/live/xxxxx    ← URLs, one per line
https://www.youtube.com/live/yyyyy
                                       ← Blank lines ignored
# This is a comment                    ← Comments ignored
```

### Log Rotation
- Log file: `/tmp/kiosk.log`
- Automatically rotates when exceeds 1MB
- Old log saved as `/tmp/kiosk.log.old`

## Platform Compatibility

- Designed for Raspberry Pi running Raspberry Pi OS (Debian-based)
- Uses `stat` with platform detection (`-f%z` for BSD/macOS, `-c%s` for Linux)
- Tested on Linux with X11
- Requires systemd for service management

## Testing Modifications

When modifying kiosk.sh:
1. Test in a live X session first: `./kiosk.sh`
2. Create test URL file with 2-3 URLs
3. Set short rotation interval for testing: `# 0.1` (6 seconds)
4. Monitor `/tmp/kiosk.log` for debugging
5. Test URL file changes while running
6. Verify shuffle behavior by checking log messages

When modifying kiosk-setup.sh:
1. Test in a VM or non-production system
2. Review generated files before enabling services
3. Check autologin configuration in `/etc/systemd/system/getty@tty1.service.d/`
4. Verify .profile modifications don't break existing login
