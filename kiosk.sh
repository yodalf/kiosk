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
HIGHLIGHT_INTERVAL=60
HIGHLIGHT_INITIAL_DELAY=5
HIGHLIGHT_DETECTED_FLAG="/tmp/kiosk_highlight_detected"
URL_STARTED_FLAG="/tmp/kiosk_url_started"
SKIP_PATTERNS="HIGHLIGHT|Stream\s+currently\s+offline|slight\s+connectivity\s+interruption"
CHECK_INTERVAL=2
STUCK_THRESHOLD=8  # consecutive frozen time-pos reads before rotating (~16s at CHECK_INTERVAL=2)

# In-memory shuffle state
SHUFFLE=()
SHUFFLE_POS=0

# Stuck-playback detection state
LAST_TIME_POS=""
STUCK_COUNT=0

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
	# Avoid replaying the URL we just had — swap with next position if needed.
	if [ ${#SHUFFLE[@]} -gt 1 ] && [ "${SHUFFLE[0]}" = "$CURRENT_URL" ]; then
		local tmp="${SHUFFLE[0]}"
		SHUFFLE[0]="${SHUFFLE[1]}"
		SHUFFLE[1]="$tmp"
	fi
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
	rm -f "$URL_STARTED_FLAG"
	ELAPSED=0
	LAST_TIME_POS=""
	STUCK_COUNT=0
}

# Background loop: screenshot via mpv, OCR it, flag if a skip pattern appears.
# Waits for mpv to confirm playback, then OCRs once ${HIGHLIGHT_INITIAL_DELAY}s
# after start, and every ${HIGHLIGHT_INTERVAL}s thereafter.
highlight_monitor() {
	log_message "Highlight monitor started (first check ${HIGHLIGHT_INITIAL_DELAY}s after playback, then every ${HIGHLIGHT_INTERVAL}s)"
	local proc="${HIGHLIGHT_SCREENSHOT%.png}_proc.png"
	local attempt=0
	local last_started_at=0
	while true; do
		# Wait for mpv to be playing.
		if ! mpv_command '{"command": ["get_property", "playback-time"]}' | grep -qE '"data":[0-9]'; then
			sleep 2
			continue
		fi

		# First confirmation after a rotate: stamp the flag as "playback start".
		[ -f "$URL_STARTED_FLAG" ] || touch "$URL_STARTED_FLAG"

		local started_at now age
		started_at=$(stat -f%m "$URL_STARTED_FLAG" 2>/dev/null || stat -c%Y "$URL_STARTED_FLAG" 2>/dev/null)

		# New URL → wait the initial delay; otherwise wait the steady-state interval.
		if [ "$started_at" != "$last_started_at" ]; then
			attempt=0
			last_started_at=$started_at
			sleep "$HIGHLIGHT_INITIAL_DELAY"
		else
			sleep "$HIGHLIGHT_INTERVAL"
		fi
		attempt=$((attempt + 1))

		now=$(date +%s)
		age=$((now - started_at))

		rm -f "$HIGHLIGHT_SCREENSHOT"
		mpv_command '{"command": ["screenshot-to-file", "'"$HIGHLIGHT_SCREENSHOT"'", "video"]}' > /dev/null
		sleep 1
		[ -f "$HIGHLIGHT_SCREENSHOT" ] || continue

		ffmpeg -y -i "$HIGHLIGHT_SCREENSHOT" -vf "scale=iw*4:ih*4,format=gray,lutyuv=y=if(gt(val\,180)\,255\,0)" "$proc" 2>/dev/null
		local ocr matched
		ocr=$(tesseract "$proc" stdout --psm 11 2>/dev/null)
		rm -f "$proc" "$HIGHLIGHT_SCREENSHOT"
		matched=$(echo "$ocr" | grep -oiE "$SKIP_PATTERNS" | head -1)
		log_message "OCR attempt=$attempt age=${age}s matched=${matched:-none}"
		if [ -n "$matched" ]; then
			touch "$HIGHLIGHT_DETECTED_FLAG"
		fi
	done
}

cleanup() {
	log_message "Shutting down kiosk"
	[ -n "$HIGHLIGHT_PID" ] && kill "$HIGHLIGHT_PID" 2>/dev/null && wait "$HIGHLIGHT_PID" 2>/dev/null
	[ -n "$MPV_PID" ] && kill "$MPV_PID" 2>/dev/null && wait "$MPV_PID" 2>/dev/null
	rm -f "$MPV_SOCKET" "$HIGHLIGHT_SCREENSHOT" "$HIGHLIGHT_DETECTED_FLAG" "$URL_STARTED_FLAG"
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

rm -f "$HIGHLIGHT_DETECTED_FLAG" "$URL_STARTED_FLAG"
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

	# Stuck playback: rotate if time-pos hasn't advanced for STUCK_THRESHOLD checks.
	TIME_POS=$(mpv_command '{"command": ["get_property", "time-pos"]}' | grep -oE '"data":[0-9.]+' | head -1 | cut -d: -f2)
	if [ -n "$TIME_POS" ]; then
		if [ "$TIME_POS" = "$LAST_TIME_POS" ]; then
			STUCK_COUNT=$((STUCK_COUNT + 1))
			if [ "$STUCK_COUNT" -ge "$STUCK_THRESHOLD" ]; then
				rotate_to_next "Stuck playback (time-pos frozen at $TIME_POS for $((STUCK_COUNT * CHECK_INTERVAL))s)"
				continue
			fi
		else
			STUCK_COUNT=0
			LAST_TIME_POS=$TIME_POS
		fi
	fi

	# Timer-based rotation (only if multiple URLs)
	if [ ${#SHUFFLE[@]} -gt 1 ] && [ "$ELAPSED" -ge "$ROTATION_INTERVAL" ]; then
		rotate_to_next "Timer rotation"
	fi

	sleep $CHECK_INTERVAL
	[ ${#SHUFFLE[@]} -gt 1 ] && ELAPSED=$((ELAPSED + CHECK_INTERVAL))
done
