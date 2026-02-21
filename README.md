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
- **One-Command Setup**: Single script goes from fresh Raspberry Pi OS to working kiosk

## Requirements

### Hardware
- Raspberry Pi (tested on Pi 5, should work on any model with video output)
- Display connected via HDMI
- Internet connection

### Software
- Raspberry Pi OS Bookworm (Debian-based Linux)
- Network configured (via Raspberry Pi Imager or manual setup)

## Quick Start

### Installation

1. Clone this repository on the Pi:
```bash
git clone https://github.com/yodalf/kiosk.git
cd kiosk
```

2. Run the setup script (do NOT run as root):
```bash
./kiosk-setup.sh
```

The setup script will:
- Install required dependencies (mpv, yt-dlp, xorg, xinit, unclutter, socat)
- Copy all scripts and URL files to your home directory
- Generate the X server wrapper (`kiosk-with-x.sh`)
- Prompt you to select a playlist (from available `.url` files)
- Install and enable the `kiosk.service` systemd service
- Configure autologin on tty1

3. Reboot to start the kiosk:
```bash
sudo reboot
```

### Configuration

Edit the URL file to change your video playlist:
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
sudo systemctl restart kiosk.service
```

**View logs:**
```bash
tail -f /tmp/kiosk.log
```

**Check service status:**
```bash
systemctl status kiosk.service
```

**Enable/disable auto-start:**
```bash
sudo systemctl enable kiosk.service   # Auto-start on boot
sudo systemctl disable kiosk.service  # Disable auto-start
```

### Multiple Playlists

The setup script copies all `.url` files from the repo and lets you choose which one to use. The selected file is symlinked as `kiosk.url`:

- `africa.url` - African wildlife camera streams
- `world.url` - World news streams

To switch playlists after setup:
```bash
rm ~/kiosk.url
ln -s ~/africa.url ~/kiosk.url
sudo systemctl restart kiosk.service
```

## Architecture

### Core Components

| File | Description |
|------|-------------|
| `kiosk.sh` | Main kiosk script - runs mpv in IPC mode, manages shuffle rotation |
| `kiosk-setup.sh` | One-time setup script - installs everything from a fresh Pi OS |
| `kiosk-with-x.sh` | X server wrapper - bridges systemd service to startx |
| `kiosk-monitor.sh` | Watchdog - restarts getty if X crashes (optional) |
| `restart-kiosk.sh` | Convenience script - restarts the kiosk service |
| `kiosk.service` | Systemd service template (USERNAME placeholder) |
| `kiosk-monitor.service` | Watchdog service template (USERNAME placeholder) |

### How It Works

1. On boot, systemd starts `kiosk.service`
2. The service runs `kiosk-with-x.sh`, which starts X on tty1
3. X runs `kiosk.sh` as the window manager
4. `kiosk.sh` launches mpv in IPC mode and loads the first URL from the shuffled playlist
5. Every N minutes, it sends a `loadfile` command via the mpv socket for a smooth transition
6. When all URLs have played, the playlist reshuffles

### Video Rotation Logic

The kiosk uses an intelligent shuffle system:
1. Reads all URLs and creates shuffled playlist in `/tmp/kiosk_shuffle.txt`
2. Tracks current position in `/tmp/kiosk_shuffle_index.txt`
3. Plays all URLs once before reshuffling (no immediate repeats)
4. Detects URL file changes and regenerates shuffle automatically

## Troubleshooting

### Kiosk not starting after reboot
```bash
systemctl status kiosk.service
sudo journalctl -u kiosk.service -n 50
```

### Videos not playing
1. Check internet connection
2. Verify URLs are valid YouTube links
3. Check mpv and yt-dlp are installed: `which mpv yt-dlp`

### Black screen or display issues
Check X server logs:
```bash
cat ~/.local/share/xorg/Xorg.0.log | grep -E '(EE|WW)'
```

### View logs
```bash
# Kiosk logs
tail -f /tmp/kiosk.log

# System logs for kiosk service
sudo journalctl -u kiosk.service -f
```

## Development

### Making Changes

The setup script copies files from the repository to your home directory. To modify the kiosk:

**Option 1: Edit directly on the Pi**
```bash
nano ~/kiosk.sh
sudo systemctl restart kiosk.service
```

**Option 2: Edit in repo and re-run setup**
```bash
cd /path/to/kiosk
nano kiosk.sh
./kiosk-setup.sh   # Safe to re-run (idempotent)
sudo systemctl restart kiosk.service
```

### Testing Changes

Create a test URL file with short rotation:
```bash
cat > ~/test.url << EOF
# 0.1
https://www.youtube.com/live/test1
https://www.youtube.com/live/test2
EOF
rm ~/kiosk.url && ln -s ~/test.url ~/kiosk.url
sudo systemctl restart kiosk.service
```

## Platform Compatibility

- Designed for Raspberry Pi OS Bookworm (Debian-based, arm64)
- Compatible with other Linux distributions using systemd and X11
- Uses platform-aware `stat` commands (supports both Linux and BSD/macOS)

## License

This project is provided as-is for personal and commercial use.

## Credits

Built with:
- [mpv](https://mpv.io/) - Video player
- [yt-dlp](https://github.com/yt-dlp/yt-dlp) - YouTube downloader
- [socat](http://www.dest-unreach.org/socat/) - Socket communication
