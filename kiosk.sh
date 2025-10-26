#!/bin/bash
xset -dpms      # Disable DPMS (Energy Star) features
xset s off      # Disable screen saver
xset s noblank  # Don't blank the video device
unclutter &     # Hide mouse cursor (install with: sudo apt install unclutter)

# URL file location
URL_FILE="$(dirname "$0")/kiosk.url"
DEFAULT_URL="https://www.youtube.com/watch?v=AeMUdOPFcXI"
MPV_SOCKET="/tmp/mpvsocket"
LOG_FILE="/tmp/kiosk.log"
MAX_LOG_SIZE=1048576  # 1 MB in bytes
SHUFFLE_FILE="/tmp/kiosk_shuffle.txt"
SHUFFLE_INDEX_FILE="/tmp/kiosk_shuffle_index.txt"

# Function to rotate log file if it exceeds max size
rotate_log_if_needed() {
	if [ -f "$LOG_FILE" ]; then
		local log_size=$(stat -f%z "$LOG_FILE" 2>/dev/null || stat -c%s "$LOG_FILE" 2>/dev/null)
		if [ "$log_size" -ge "$MAX_LOG_SIZE" ]; then
			mv "$LOG_FILE" "${LOG_FILE}.old"
			echo "$(date '+%Y-%m-%d %H:%M:%S') - Log rotated (was ${log_size} bytes)" > "$LOG_FILE"
		fi
	fi
}

# Function to log a message
log_message() {
	rotate_log_if_needed
	echo "$1" >> "$LOG_FILE"
}

# Function to read rotation interval from file (in minutes)
read_rotation_interval() {
	local default_minutes=1
	if [ -f "$URL_FILE" ]; then
		local first_line=$(head -n 1 "$URL_FILE")
		if [[ "$first_line" =~ ^#[[:space:]]+([0-9]+) ]]; then
			echo "${BASH_REMATCH[1]}"
		else
			echo "$default_minutes"
		fi
	else
		echo "$default_minutes"
	fi
}

# Function to read all URLs from file
read_urls() {
	if [ -f "$URL_FILE" ]; then
		grep -v '^[[:space:]]*$' "$URL_FILE" | grep -v '^#'
	else
		echo "Warning: kiosk.url file not found at $URL_FILE, using default URL" >&2
		echo "$DEFAULT_URL"
	fi
}

# Function to read current shuffle index
read_shuffle_index() {
	if [ -f "$SHUFFLE_INDEX_FILE" ]; then
		cat "$SHUFFLE_INDEX_FILE"
	else
		echo "0"
	fi
}

# Function to write shuffle index
write_shuffle_index() {
	echo "$1" > "$SHUFFLE_INDEX_FILE"
}

# Function to create a new shuffled list of URLs
create_shuffle() {
	local url_list
	url_list=$(read_urls)
	local count=$(echo "$url_list" | grep -c '^')

	if [ $count -eq 0 ]; then
		echo "$DEFAULT_URL" > "$SHUFFLE_FILE"
		write_shuffle_index 0
		return
	fi

	# Use shuf to randomize the URL list and save to shuffle file
	echo "$url_list" | shuf > "$SHUFFLE_FILE"
	write_shuffle_index 0
	log_message "$(date '+%Y-%m-%d %H:%M:%S') - Created new shuffle with ${count} URLs"
}

# Function to check if shuffle needs to be recreated (URL list changed)
check_shuffle_validity() {
	if [ ! -f "$SHUFFLE_FILE" ]; then
		return 1  # Shuffle file doesn't exist
	fi

	local current_urls
	current_urls=$(read_urls | sort)
	local shuffle_urls
	shuffle_urls=$(cat "$SHUFFLE_FILE" | sort)

	if [ "$current_urls" != "$shuffle_urls" ]; then
		return 1  # URL list has changed
	fi

	return 0  # Shuffle is still valid
}

# Function to get the next URL from the shuffle
# This ensures all URLs are shown before any repeats
get_next_url() {
	# Check if we need to create or recreate the shuffle
	if ! check_shuffle_validity; then
		create_shuffle
	fi

	local shuffle_index=$(read_shuffle_index)
	local total_urls=$(cat "$SHUFFLE_FILE" | wc -l)

	# If we've shown all URLs, create a new shuffle
	if [ $shuffle_index -ge $total_urls ]; then
		log_message "$(date '+%Y-%m-%d %H:%M:%S') - Completed full rotation, reshuffling"
		create_shuffle
		shuffle_index=0
	fi

	# Get the next URL (index is 0-based, sed is 1-based)
	local next_url=$(sed -n "$((shuffle_index + 1))p" "$SHUFFLE_FILE")
	shuffle_index=$((shuffle_index + 1))
	write_shuffle_index $shuffle_index

	echo "$next_url"
}

# Function to count URLs in file
count_urls() {
	read_urls | wc -l
}

# Function to send command to mpv via IPC
mpv_command() {
	local cmd="$1"
	echo "$cmd" | socat - "$MPV_SOCKET" 2>/dev/null > /dev/null
}

# Function to load a URL in mpv
load_url() {
	local url="$1"
	log_message "$(date '+%Y-%m-%d %H:%M:%S') - Loading URL: $url"
	mpv_command "loadfile \"$url\" replace"
	log_message "$(date '+%Y-%m-%d %H:%M:%S') - Load command sent"
}

# Cleanup function
cleanup() {
	log_message "$(date '+%Y-%m-%d %H:%M:%S') - Shutting down kiosk"
	if [ -n "$MPV_PID" ]; then
		kill $MPV_PID 2>/dev/null
		wait $MPV_PID 2>/dev/null
	fi
	rm -f "$MPV_SOCKET"
	rm -f "$SHUFFLE_FILE"
	rm -f "$SHUFFLE_INDEX_FILE"
	exit 0
}

trap cleanup SIGINT SIGTERM EXIT

# Start mpv in IPC mode
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

# Wait for mpv to start and create socket
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

if [ ! -S "$MPV_SOCKET" ]; then
	echo "Error: mpv socket not created" >&2
	exit 1
fi

echo "mpv started successfully"

# Initialize shuffle and get first URL
URL_COUNT=$(count_urls)
ROTATION_MINUTES=$(read_rotation_interval)
ROTATION_INTERVAL=$((ROTATION_MINUTES * 60))
CURRENT_URL=$(get_next_url)
log_message "$(date '+%Y-%m-%d %H:%M:%S') - Starting kiosk with URL: $CURRENT_URL (${URL_COUNT} URLs available, rotation every ${ROTATION_MINUTES} minute(s))"
echo "Starting kiosk with ${URL_COUNT} URLs, rotation every ${ROTATION_MINUTES} minute(s)"

# Load initial URL
load_url "$CURRENT_URL"

# Track time for rotation
ELAPSED=0
CHECK_INTERVAL=2

# Main monitoring loop
log_message "$(date '+%Y-%m-%d %H:%M:%S') - Entering main monitoring loop"
while true; do
	# Check if mpv is still running
	if ! kill -0 $MPV_PID 2>/dev/null; then
		log_message "$(date '+%Y-%m-%d %H:%M:%S') - Error: mpv process died, exiting"
		exit 1
	fi

	# Check if the URL file has changed (different number of URLs or rotation interval)
	NEW_URL_COUNT=$(count_urls)
	NEW_ROTATION_MINUTES=$(read_rotation_interval)
	NEW_ROTATION_INTERVAL=$((NEW_ROTATION_MINUTES * 60))

	if [ "$NEW_URL_COUNT" != "$URL_COUNT" ] || [ "$NEW_ROTATION_INTERVAL" != "$ROTATION_INTERVAL" ]; then
		if [ "$NEW_URL_COUNT" != "$URL_COUNT" ]; then
			log_message "$(date '+%Y-%m-%d %H:%M:%S') - URL file changed (${URL_COUNT} -> ${NEW_URL_COUNT} URLs)"
			URL_COUNT=$NEW_URL_COUNT
			# URL list changed, shuffle will be recreated on next get_next_url call
		fi
		if [ "$NEW_ROTATION_INTERVAL" != "$ROTATION_INTERVAL" ]; then
			log_message "$(date '+%Y-%m-%d %H:%M:%S') - Rotation interval changed (${ROTATION_MINUTES} -> ${NEW_ROTATION_MINUTES} minute(s))"
			ROTATION_MINUTES=$NEW_ROTATION_MINUTES
			ROTATION_INTERVAL=$NEW_ROTATION_INTERVAL
		fi
		CURRENT_URL=$(get_next_url)
		log_message "$(date '+%Y-%m-%d %H:%M:%S') - Switching to next URL: $CURRENT_URL"
		load_url "$CURRENT_URL"
		ELAPSED=0  # Reset timer after manual switch
	fi

	# If multiple URLs, rotate based on configured interval
	if [ "$URL_COUNT" -gt 1 ] && [ "$ELAPSED" -ge "$ROTATION_INTERVAL" ]; then
		log_message "$(date '+%Y-%m-%d %H:%M:%S') - Timer triggered (ELAPSED=$ELAPSED, ROTATION_INTERVAL=$ROTATION_INTERVAL, URL_COUNT=$URL_COUNT)"
		CURRENT_URL=$(get_next_url)
		# Read index after get_next_url to get the updated position
		if [ -f "$SHUFFLE_INDEX_FILE" ]; then
			current_position=$(cat "$SHUFFLE_INDEX_FILE")
		else
			current_position="0"
		fi
		log_message "$(date '+%Y-%m-%d %H:%M:%S') - Rotating to next URL: $CURRENT_URL (shuffle position: $current_position/$URL_COUNT)"
		load_url "$CURRENT_URL"
		ELAPSED=0  # Reset timer
	fi

	sleep $CHECK_INTERVAL

	# Only increment timer if we have multiple URLs
	if [ "$URL_COUNT" -gt 1 ]; then
		ELAPSED=$((ELAPSED + CHECK_INTERVAL))
	fi
done
