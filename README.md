# Video Kiosk System

A fullscreen video kiosk system designed for Raspberry Pi that automatically plays and rotates through YouTube live streams or videos. Perfect for digital signage, monitoring dashboards, or continuous video displays.

## Features

- **Smooth Video Transitions**: Uses mpv with IPC (Inter-Process Communication) for seamless video switching without black screens
- **Smart Rotation**: Shuffle-based algorithm ensures all videos play before repeating
- **Auto-Restart**: Systemd integration with watchdog monitoring for reliable 24/7 operation
- **Configurable Intervals**: Set custom rotation times per playlist
- **Live URL Updates**: Automatically detects and applies changes to video lists without restart
- **Lightweight**: Minimal resource usage, optimized for Raspberry Pi
- **Auto-Login**: Boots directly into kiosk mode on startup

## Requirements

### Hardware
- Raspberry Pi (any model with video output)
- Display connected via HDMI
- Internet connection

### Software
- Raspberry Pi OS (Debian-based Linux)
- Systemd for service management
- X11 display server

## Quick Start

### Installation

**Note:** The setup script must be run from within a cloned copy of this repository, as it copies the kiosk scripts from the repo to your home directory.

1. Clone this repository:
```bash
git clone https://github.com/yodalf/kiosk.git
cd kiosk
```

2. Run the setup script (do NOT run as root):
```bash
./kiosk-setup.sh
```

The setup script will:
- Install required dependencies (mpv, yt-dlp, xorg, unclutter, socat)
- Copy `kiosk.sh` and `kiosk-monitor.sh` from the repository to your home directory
- Create a default `kiosk.url` file if one doesn't exist
- Configure autologin on tty1
- Set up systemd services for monitoring

3. Reboot to start the kiosk:
```bash
sudo reboot
```

### Configuration

Edit the URL file to add your YouTube videos:
```bash
nano ~/kiosk.url
```

#### URL File Format

```
# 5                                    ← Optional: rotation interval in minutes
https://www.youtube.com/live/xxxxx    ← YouTube URLs, one per line
https://www.youtube.com/live/yyyyy
                                       ← Blank lines are ignored
# This is a comment                    ← Comments (lines starting with #) are ignored
```

**Rotation Interval:**
- First line can specify rotation time: `# N` where N is minutes
- Default is 1 minute if not specified
- Example: `# 5` rotates every 5 minutes
- For testing: `# 0.1` rotates every 6 seconds

## Usage

### Managing the Kiosk

**Restart the kiosk:**
```bash
./restart-kiosk.sh
# or
sudo pkill X
```

**View logs:**
```bash
tail -f /tmp/kiosk.log
```

**Check service status:**
```bash
systemctl status kiosk.service
systemctl status kiosk-monitor.service
```

**Enable/disable auto-start:**
```bash
sudo systemctl enable kiosk.service   # Auto-start on boot
sudo systemctl disable kiosk.service  # Disable auto-start
```

### Multiple Playlists

You can create different URL files for different purposes:
- `africa.url` - African news streams
- `world.url` - World news streams
- `kiosk.url` - Default playlist

Edit `kiosk.sh` to change which playlist is active by modifying the `URL_FILE` variable.

## Architecture

### Core Components

**kiosk.sh** - Main kiosk script
- Runs mpv in IPC mode with socket communication
- Implements shuffle algorithm for fair video rotation
- Monitors for URL file changes
- Logs to `/tmp/kiosk.log` with automatic rotation at 1MB

**kiosk-setup.sh** - One-time setup script
- Installs all dependencies
- Copies kiosk scripts from repository to home directory
- Configures autologin and systemd services
- Creates default URL file if needed

**kiosk-monitor.sh** - Watchdog service
- Monitors X server process
- Automatically restarts getty if X crashes
- Ensures kiosk stays running 24/7

### Video Rotation Logic

The kiosk uses an intelligent shuffle system:
1. Reads all URLs and creates shuffled playlist in `/tmp/kiosk_shuffle.txt`
2. Tracks current position in `/tmp/kiosk_shuffle_index.txt`
3. Plays all URLs once before reshuffling (no immediate repeats)
4. Detects URL file changes and regenerates shuffle automatically

### Systemd Services

**kiosk.service** - Runs X session with kiosk on tty7

**kiosk-monitor.service** - Monitors X process and restarts on crash

## Troubleshooting

### Kiosk not starting after reboot
Check if services are enabled:
```bash
systemctl status kiosk.service
sudo journalctl -u kiosk.service -f
```

### Videos not playing
1. Check internet connection
2. Verify URLs are valid YouTube links
3. Check mpv and yt-dlp are installed:
```bash
which mpv yt-dlp
```

### Black screen or display issues
Check X server logs:
```bash
cat ~/.local/share/xorg/Xorg.0.log
```

### Monitor logs
```bash
# Kiosk logs
tail -f /tmp/kiosk.log

# Monitor service logs
sudo tail -f /var/log/kiosk-monitor.log

# System logs
sudo journalctl -f
```

## Development

### Making Changes

The setup script copies files from the repository to your home directory. If you want to modify the kiosk behavior:

**Option 1: Test changes directly in home directory**
```bash
# Edit the installed script
nano ~/kiosk.sh

# Test it (requires X session)
~/kiosk.sh
```

**Option 2: Modify in repo and re-copy**
```bash
# Edit in the repository
cd /path/to/kiosk
nano kiosk.sh

# Copy to home directory
cp kiosk.sh ~/kiosk.sh

# Or re-run setup (will preserve existing kiosk.url)
./kiosk-setup.sh
```

### Testing Changes

Create a test URL file with short rotation for development:
```bash
cat > ~/test.url << EOF
# 0.1
https://www.youtube.com/live/test1
https://www.youtube.com/live/test2
EOF
```

Edit `~/kiosk.sh` to change `URL_FILE` to point to `test.url`, then run `~/kiosk.sh`.

### Log Rotation

- Log file: `/tmp/kiosk.log`
- Automatically rotates when exceeds 1MB
- Old log saved as `/tmp/kiosk.log.old`

## Platform Compatibility

- Designed for Raspberry Pi OS (Debian-based)
- Compatible with other Linux distributions using systemd
- Uses platform-aware `stat` commands (supports both Linux and BSD/macOS)

## License

This project is provided as-is for personal and commercial use.

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## Credits

Built with:
- [mpv](https://mpv.io/) - Video player
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) - YouTube downloader
- [socat](http://www.dest-unreach.org/socat/) - Socket communication
