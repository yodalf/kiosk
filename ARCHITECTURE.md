# Architecture

This document explains how the kiosk works, starting from the 10,000-foot view
and drilling down into the runtime internals of `kiosk.sh`.

## 1. The big picture

The kiosk is one shell script (`kiosk.sh`) driving one media player (`mpv`), wrapped
by systemd so it starts on boot and restarts on failure.

```
┌─────────────────────────────────────────────────────────────┐
│  boot → systemd → X server → kiosk.sh → mpv → HDMI display  │
└─────────────────────────────────────────────────────────────┘
```

- A **playlist** (`~/kiosk.url`) lists the URLs to show.
- `kiosk.sh` picks URLs in shuffled order and tells `mpv` which one to play next.
- `mpv` streams the URL full-screen. Transitions are seamless because `mpv` stays
  alive between videos — it never exits, it just loads a new file.
- When the playlist file changes on disk, `kiosk.sh` notices and re-shuffles.
- An optional OCR pass ("highlight monitor") periodically screenshots the video
  and skips to the next URL if a skip pattern (e.g. `HIGHLIGHT` or
  `Stream currently offline`) appears on screen.

## 2. Boot flow

```
  power on
     │
     ▼
  systemd boots
     │
     ▼
  getty@tty1 disabled, kiosk.service starts         ← kiosk.service
     │
     ▼
  kiosk-with-x.sh runs on vt1                       ← wrapper with hardcoded $USER
     │
     ▼
  startx /home/<user>/kiosk.sh -- :0 vt1            ← X server starts
     │
     ▼
  kiosk.sh runs as the X session's only program
     │
     ▼
  kiosk.sh launches mpv in IPC mode and enters main loop
```

A few notes on this chain:

- **`kiosk.service`** is the systemd unit. It uses `Conflicts=getty@tty1.service`
  so the login prompt doesn't fight for tty1, and `Restart=on-failure` so a crash
  recovers automatically. See `kiosk.service` in the repo.
- **`kiosk-with-x.sh`** exists because `startx` must be invoked by a real user,
  not as root. The setup script generates it with `$USER` hardcoded so systemd
  can `ExecStart` it directly.
- **`kiosk-monitor.service`** is a separate watchdog (installed but disabled by
  default) that kicks `getty@tty1` if the X process dies — a belt-and-suspenders
  backup for `kiosk.service`'s own `Restart=on-failure`.

## 3. Components

| File | Role |
|------|------|
| `kiosk.sh` | The runtime. Spawns mpv, manages rotation, monitors state. |
| `kiosk-setup.sh` | One-time installer. Idempotent. |
| `kiosk-with-x.sh` | Generated wrapper that starts X on vt1. |
| `kiosk.service` | Systemd unit template. `USERNAME` placeholder gets substituted at install. |
| `kiosk-monitor.sh` + `.service` | Optional watchdog that restarts getty if X dies. |
| `restart-kiosk.sh` | Convenience wrapper for `systemctl restart kiosk.service`. |
| `99-vc4.conf` | Xorg config for Raspberry Pi 5's dual-DRM GPU. |
| `*.url` | Playlists. `kiosk.url` is the active one (often a symlink to another). |

## 4. `kiosk.sh` runtime

This is where the interesting logic lives. The script is ~190 lines of bash and
does four things concurrently:

1. Runs `mpv` in the background with an IPC socket.
2. Runs a **highlight monitor** in the background.
3. Runs a **main loop** that picks URLs and reacts to events.
4. Installs a cleanup trap to tear everything down on exit.

### 4.1 Talking to mpv

`mpv` is started with `--idle --input-ipc-server=/tmp/mpvsocket`. `--idle` means
it never exits when a file ends; it just sits waiting for the next command.
Commands go in over a Unix socket using `socat`:

```bash
mpv_command() {
    echo "$1" | socat - "$MPV_SOCKET" 2>/dev/null
}
```

The two commands used are:

- `loadfile "<url>" replace` — play this URL, discarding any current one. This
  is what gives seamless transitions: `mpv` downloads and buffers the next
  stream while still rendering the current one, then swaps in place.
- `{"command": ["get_property", "idle-active"]}` — JSON form, returns whether
  `mpv` is currently showing nothing (i.e. the last `loadfile` failed). Used
  to auto-skip broken URLs.

### 4.2 Shuffle state

The shuffle is an in-memory bash array plus an integer index:

```bash
SHUFFLE=()        # current shuffled order
SHUFFLE_POS=0    # next URL to play
```

Two functions manipulate it:

- **`reshuffle`** — reads the URL file, pipes through `shuf`, loads the result
  into `SHUFFLE` via `mapfile`, resets `SHUFFLE_POS=0`.
- **`rotate_to_next "<reason>"`** — the single entry point for "play the next
  URL". It:
  1. Compares the on-disk URL list (sorted) to the cached one (sorted).
  2. If they differ, or if the cursor reached the end of the shuffle, calls `reshuffle`.
  3. Picks `SHUFFLE[$SHUFFLE_POS]`, increments the cursor, logs with the given reason.
  4. Sends `loadfile` to mpv and resets `ELAPSED=0`.

This single helper replaces four near-identical code paths that existed in
earlier versions.

### 4.3 Main loop

The loop ticks every `CHECK_INTERVAL=2` seconds and checks, in order:

1. **Is `mpv` still running?** If not, exit so systemd restarts us.
2. **Is `mpv` idle?** (URL failed to load.) If yes, `rotate_to_next` and wait 5s
   before the next tick to avoid hammering a bad playlist.
3. **Did the URL file change on disk?** Compared as sorted sets so any edit
   (add, remove, swap) is detected. If yes, `rotate_to_next`.
4. **Did the rotation interval change** (first line of the URL file)? If yes,
   log the change and `rotate_to_next`.
5. **Did the highlight monitor raise a flag?** If yes, clear the flag and
   `rotate_to_next`.
6. **Has `ELAPSED` reached the rotation interval?** If yes, `rotate_to_next`.
7. Sleep `CHECK_INTERVAL`, increment `ELAPSED` (only if >1 URL).

### 4.4 Highlight monitor

A background loop that runs every `HIGHLIGHT_CHECK_INTERVAL=15` seconds:

```
ask mpv to screenshot          (screenshot-to-file)
    │
    ▼
preprocess with ffmpeg          (4× upscale, grayscale, threshold at 180)
    │
    ▼
OCR with tesseract              (--psm 11: sparse text)
    │
    ▼
grep for SKIP_PATTERNS          ("HIGHLIGHT", "Stream currently offline", …)
    │
    ▼
if match: touch the flag file   (/tmp/kiosk_highlight_detected)
```

The flag file is how a background process signals the main loop without shared
memory. The main loop's check 5 above polls for it.

### 4.5 Logging

`log_message` prepends a timestamp and appends to `/tmp/kiosk.log`. Before each
write it checks the file size and rotates to `/tmp/kiosk.log.old` if the log
exceeds 1 MB. This keeps the kiosk safe on a read-mostly SD card without
needing `logrotate`.

### 4.6 Cleanup

A `trap` on `SIGINT`, `SIGTERM`, and `EXIT` kills the mpv and highlight-monitor
child processes, removes the IPC socket and temporary flag files, and exits.
This is important because systemd sends `SIGTERM` on restart, and a dangling
mpv process would hold tty1.

## 5. Configuration surface

Everything configurable lives at the top of `kiosk.sh` as shell variables:

| Variable | Default | Purpose |
|---|---|---|
| `URL_FILE` | `$(dirname $0)/kiosk.url` | Playlist location |
| `DEFAULT_URL` | hardcoded | Fallback if playlist is missing/empty |
| `MPV_SOCKET` | `/tmp/mpvsocket` | mpv IPC endpoint |
| `LOG_FILE` | `/tmp/kiosk.log` | Log file |
| `MAX_LOG_SIZE` | 1 MB | Rotation threshold |
| `HIGHLIGHT_CHECK_INTERVAL` | 15 s | OCR frequency |
| `SKIP_PATTERNS` | `HIGHLIGHT\|Stream\s+currently\s+offline` | Regex fed to `grep -oiE` |
| `CHECK_INTERVAL` | 2 s | Main loop tick |

The rotation interval itself is read from the first line of `URL_FILE` at
runtime (e.g. `# 5` = 5 minutes) so it can change without restarting.

## 6. Platform notes

- Targets Raspberry Pi OS Bookworm (aarch64, bash 5.2, systemd).
- Uses `shuf`, `mapfile`, and bash regex — needs bash ≥ 4.
- `stat` is called with both BSD (`-f%z`) and GNU (`-c%s`) flags so the script
  is testable on macOS, though only Linux is a supported runtime.
- Requires X11 (started via `startx` on vt1). Wayland is not supported.
