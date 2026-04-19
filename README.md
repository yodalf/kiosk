# Video Kiosk

A fullscreen video kiosk for Raspberry Pi. Auto-plays and rotates through a list of
YouTube live streams or videos using `mpv`, with smooth transitions and no black frames.

For how it all works internally, see [ARCHITECTURE.md](ARCHITECTURE.md).

## Install

On a fresh Raspberry Pi OS Bookworm install with network configured:

```bash
git clone https://github.com/yodalf/kiosk.git
cd kiosk
./kiosk-setup.sh     # do NOT run as root
sudo reboot
```

The setup installs dependencies, copies scripts to `$HOME`, enables the systemd
service, and sets up autologin on tty1. It is safe to re-run.

## Configure

Edit the playlist:

```bash
nano ~/kiosk.url
```

URL file format:

```
# 5                                  ← optional: rotation interval in minutes (default 1)
https://www.youtube.com/live/xxxxx   ← one URL per line
https://www.youtube.com/live/yyyyy
# comment lines and blank lines are ignored
```

Changes take effect within a few seconds — no restart needed.

To switch between bundled playlists (`africa.url`, `world.url`, …):

```bash
rm ~/kiosk.url
ln -s ~/africa.url ~/kiosk.url
sudo systemctl restart kiosk.service
```

## Manage

```bash
sudo systemctl restart kiosk.service    # restart
systemctl status kiosk.service          # check status
tail -f /tmp/kiosk.log                  # live logs
sudo journalctl -u kiosk.service -f     # system logs
```

## Troubleshoot

- **Won't start after boot** — `systemctl status kiosk.service` and
  `sudo journalctl -u kiosk.service -n 50`.
- **Videos won't play** — check network, confirm `mpv` and `yt-dlp` are installed,
  validate the URLs manually with `yt-dlp <url>`.
- **Black screen / display issues** — inspect `~/.local/share/xorg/Xorg.0.log`
  for `EE` / `WW` lines.

## License

Provided as-is for personal and commercial use.

## Credits

Built with [mpv](https://mpv.io/), [yt-dlp](https://github.com/yt-dlp/yt-dlp),
and [socat](http://www.dest-unreach.org/socat/).
