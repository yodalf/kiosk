#!/bin/bash
xset -dpms      # Disable DPMS (Energy Star) features
xset s off      # Disable screen saver
xset s noblank  # Don't blank the video device
unclutter &     # Hide mouse cursor (install with: sudo apt install unclutter)

URL_FILE="$(dirname "$0")/kiosk.url"
DEFAULT_URL="https://www.youtube.com/watch?v=AeMUdOPFcXI"
MPV_SOCKET="/tmp/mpvsocket"
LOG_FILE="/tmp/kiosk.log"
MAX_LOG_SIZE=1048576  # 1 MB
HIGHLIGHT_SCREENSHOT="/tmp/kiosk_highlight.png"
HIGHLIGHT_CHECK_INTERVAL=15
HIGHLIGHT_DETECTED_FLAG="/tmp/kiosk_highlight_detected"
SKIP_PATTERNS="HIGHLIGHT|Stream\s+currently\s+offline"
CHECK_INTERVAL=2

# In-memory shuffle state
SHUFFLE=()
SHUFFLE_POS=0

log_message() {
	if [ -f "$LOG_FILE" ]; then
		local size
		size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)
		if [ "$size" -ge "$MAX_LOG_SIZE" ]; then
			mv "$LOG_FILE" "${LOG_FILE}.old"
		fi
	fi
	echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

mpv_command() {
	echo "$1" | socat - "$MPV_SOCKET" 2>/dev/null
}

read_rotation_interval() {
	local minutes=1
	if [ -f "$URL_FILE" ]; then
		local first_line
		first_line=$(head -n 1 "$URL_FILE")
		[[ "$first_line" =~ ^#[[:space:]]+([0-9]+) ]] && minutes="${BASH_REMATCH[1]}"
	fi
	echo "$minutes"
}

read_urls() {
	if [ -f "$URL_FILE" ]; then
		grep -v '^[[:space:]]*$' "$URL_FILE" | grep -v '^#'
	else
		echo "$DEFAULT_URL"
	fi
}

reshuffle() {
	mapfile -t SHUFFLE < <(read_urls | shuf)
	[ ${#SHUFFLE[@]} -eq 0 ] && SHUFFLE=("$DEFAULT_URL")
	SHUFFLE_POS=0
	log_message "Created new shuffle with ${#SHUFFLE[@]} URLs"
}

# Pick next URL (reshuffling as needed), load it, and reset the rotation timer.
rotate_to_next() {
	local reason="${1:-Rotating}"
	local current cached
	current=$(read_urls | sort)
	cached=$(printf '%s\n' "${SHUFFLE[@]}" | sort)
	if [ "$current" != "$cached" ] || [ "$SHUFFLE_POS" -ge "${#SHUFFLE[@]}" ]; then
		reshuffle
	fi
	CURRENT_URL="${SHUFFLE[$SHUFFLE_POS]}"
	SHUFFLE_POS=$((SHUFFLE_POS + 1))
	log_message "${reason}: $CURRENT_URL (shuffle ${SHUFFLE_POS}/${#SHUFFLE[@]})"
	mpv_command "loadfile \"$CURRENT_URL\" replace" > /dev/null
	ELAPSED=0
}

# Background loop: screenshot via mpv, OCR it, flag if a skip pattern appears.
highlight_monitor() {
	log_message "Highlight monitor started (every ${HIGHLIGHT_CHECK_INTERVAL}s)"
	local proc="${HIGHLIGHT_SCREENSHOT%.png}_proc.png"
	while true; do
		sleep "$HIGHLIGHT_CHECK_INTERVAL"
		rm -f "$HIGHLIGHT_SCREENSHOT"
		mpv_command '{"command": ["screenshot-to-file", "'"$HIGHLIGHT_SCREENSHOT"'", "video"]}' > /dev/null
		sleep 1
		[ -f "$HIGHLIGHT_SCREENSHOT" ] || continue

		ffmpeg -y -i "$HIGHLIGHT_SCREENSHOT" -vf "scale=iw*4:ih*4,format=gray,lutyuv=y=if(gt(val\,180)\,255\,0)" "$proc" 2>/dev/null
		local ocr matched
		ocr=$(tesseract "$proc" stdout --psm 11 2>/dev/null)
		rm -f "$proc" "$HIGHLIGHT_SCREENSHOT"
		matched=$(echo "$ocr" | grep -oiE "$SKIP_PATTERNS" | head -1)
		if [ -n "$matched" ]; then
			log_message "Skip pattern detected: $matched"
			touch "$HIGHLIGHT_DETECTED_FLAG"
		fi
	done
}

cleanup() {
	log_message "Shutting down kiosk"
	[ -n "$HIGHLIGHT_PID" ] && kill "$HIGHLIGHT_PID" 2>/dev/null && wait "$HIGHLIGHT_PID" 2>/dev/null
	[ -n "$MPV_PID" ] && kill "$MPV_PID" 2>/dev/null && wait "$MPV_PID" 2>/dev/null
	rm -f "$MPV_SOCKET" "$HIGHLIGHT_SCREENSHOT" "$HIGHLIGHT_DETECTED_FLAG"
	exit 0
}

trap cleanup SIGINT SIGTERM EXIT

echo "Starting mpv in kiosk mode with IPC..."
mpv --idle \
	--force-window \
	--fullscreen \
	--no-osd-bar \
	--osd-level=0 \
	--no-border \
	--ytdl-format=best \
	--input-ipc-server="$MPV_SOCKET" \
	--hwdec=auto \
	--really-quiet &
MPV_PID=$!

echo "Waiting for mpv to initialize..."
TIMEOUT=10
while [ ! -S "$MPV_SOCKET" ] && [ $TIMEOUT -gt 0 ]; do
	sleep 0.5
	TIMEOUT=$((TIMEOUT - 1))
	if ! kill -0 $MPV_PID 2>/dev/null; then
		echo "Error: mpv failed to start" >&2
		exit 1
	fi
done
[ -S "$MPV_SOCKET" ] || { echo "Error: mpv socket not created" >&2; exit 1; }
echo "mpv started successfully"

rm -f "$HIGHLIGHT_DETECTED_FLAG"
highlight_monitor &
HIGHLIGHT_PID=$!

ROTATION_MINUTES=$(read_rotation_interval)
ROTATION_INTERVAL=$((ROTATION_MINUTES * 60))
rotate_to_next "Starting kiosk"
echo "Starting kiosk with ${#SHUFFLE[@]} URLs, rotation every ${ROTATION_MINUTES} minute(s)"

ELAPSED=0
log_message "Entering main monitoring loop"
while true; do
	if ! kill -0 $MPV_PID 2>/dev/null; then
		log_message "Error: mpv process died, exiting"
		exit 1
	fi

	# mpv went idle (URL failed to load) -> skip
	if mpv_command '{"command": ["get_property", "idle-active"]}' | grep -q '"data":true'; then
		rotate_to_next "mpv idle, skipping"
		sleep 5
		continue
	fi

	# URL list or rotation interval changed on disk -> rotate now
	NEW_MINUTES=$(read_rotation_interval)
	NEW_INTERVAL=$((NEW_MINUTES * 60))
	current_sorted=$(read_urls | sort)
	cached_sorted=$(printf '%s\n' "${SHUFFLE[@]}" | sort)
	if [ "$current_sorted" != "$cached_sorted" ] || [ "$NEW_INTERVAL" != "$ROTATION_INTERVAL" ]; then
		[ "$current_sorted" != "$cached_sorted" ] && log_message "URL list changed"
		if [ "$NEW_INTERVAL" != "$ROTATION_INTERVAL" ]; then
			log_message "Rotation interval changed (${ROTATION_MINUTES} -> ${NEW_MINUTES} minute(s))"
			ROTATION_MINUTES=$NEW_MINUTES
			ROTATION_INTERVAL=$NEW_INTERVAL
		fi
		rotate_to_next "Switching after config change"
	fi

	# Highlight detected -> switch immediately
	if [ -f "$HIGHLIGHT_DETECTED_FLAG" ]; then
		rm -f "$HIGHLIGHT_DETECTED_FLAG"
		rotate_to_next "HIGHLIGHT detected"
	fi

	# Timer-based rotation (only if multiple URLs)
	if [ ${#SHUFFLE[@]} -gt 1 ] && [ "$ELAPSED" -ge "$ROTATION_INTERVAL" ]; then
		rotate_to_next "Timer rotation"
	fi

	sleep $CHECK_INTERVAL
	[ ${#SHUFFLE[@]} -gt 1 ] && ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done
