#!/bin/bash
# wifi-watchdog.sh - self-heal a flaky Wi-Fi link on the kiosk / Pi-hole Pi.
#
# Run by wifi-watchdog.timer once a minute as root. Each run performs three
# link-level checks on the wireless interface:
#   1. NetworkManager reports the device as connected
#   2. the default gateway answers ping
#   3. the radio still receives other hosts' broadcasts (ARP / mDNS). The
#      brcmfmac firmware has been seen to silently stop receiving broadcasts
#      while outbound traffic keeps working, which makes the Pi unreachable
#      from the LAN even though every "normal" local check passes.
#
# Consecutive failures escalate:
#   BOUNCE_AFTER  -> restart the Wi-Fi connection and tailscaled
#   REBOOT_AFTER  -> reboot (guard rails: not within MIN_UPTIME_MIN of boot,
#                    at most one watchdog reboot per REBOOT_COOLDOWN_MIN)
# While a reboot is held back by the guard rails, the connection is bounced
# again every BOUNCE_AFTER failures.
#
# Independently, if tailscaled is not in the "Running" state for BOUNCE_AFTER
# runs, only tailscaled is restarted. That never triggers a reboot: an
# unreachable coordination server is not a local fault.
#
# Everything is logged to the journal under the tag "wifi-watchdog":
#   journalctl -t wifi-watchdog
#
# Environment overrides (for testing):
#   DRY_RUN=1     log what would happen, but do not bounce or reboot
#   FORCE_FAIL=1  treat the link checks as failed

set -u

IFACE="${IFACE:-wlan0}"
BOUNCE_AFTER="${BOUNCE_AFTER:-3}"
REBOOT_AFTER="${REBOOT_AFTER:-6}"
MIN_UPTIME_MIN="${MIN_UPTIME_MIN:-10}"
REBOOT_COOLDOWN_MIN="${REBOOT_COOLDOWN_MIN:-60}"
BCAST_WAIT_SEC="${BCAST_WAIT_SEC:-40}"
DRY_RUN="${DRY_RUN:-0}"
FORCE_FAIL="${FORCE_FAIL:-0}"

STATE_DIR=/run/wifi-watchdog        # per-boot counters (cleared by a reboot)
PERSIST_DIR=/var/lib/wifi-watchdog  # survives reboots (last reboot time)

mkdir -p "$STATE_DIR" "$PERSIST_DIR"

# Never let two runs overlap (a healthy check can take up to BCAST_WAIT_SEC).
exec 9>"$STATE_DIR/lock"
flock -n 9 || exit 0

log() { logger -t wifi-watchdog -- "$*"; echo "$*"; }
read_n() { local v; v=$(cat "$1" 2>/dev/null); echo "${v:-0}"; }
dry() { [[ "$DRY_RUN" == "1" ]]; }

bounce() {
    local con
    con=$(nmcli -t -f NAME,DEVICE con show --active 2>/dev/null \
          | awk -F: -v i="$IFACE" '$2==i{print $1; exit}')
    log "bouncing Wi-Fi on $IFACE (connection '${con:-none active}') and restarting tailscaled"
    dry && return 0
    if [[ -n "$con" ]]; then
        nmcli con down "$con" >/dev/null 2>&1
        sleep 3
        nmcli con up "$con" >/dev/null 2>&1
    else
        # Nothing active: cycle the radio so NetworkManager autoconnects.
        nmcli radio wifi off
        sleep 3
        nmcli radio wifi on
    fi
    command -v tailscale >/dev/null && systemctl restart tailscaled
    return 0
}

try_reboot() {
    local up_min last now
    up_min=$(( $(cut -d. -f1 /proc/uptime) / 60 ))
    last=$(read_n "$PERSIST_DIR/last-reboot")
    now=$(date +%s)
    if (( up_min < MIN_UPTIME_MIN )); then
        log "reboot wanted, but uptime ${up_min}m < ${MIN_UPTIME_MIN}m: holding"
        return 1
    fi
    if (( now - last < REBOOT_COOLDOWN_MIN * 60 )); then
        log "reboot wanted, but last watchdog reboot was $(( (now - last) / 60 ))m ago (< ${REBOOT_COOLDOWN_MIN}m): holding"
        return 1
    fi
    log "REBOOTING: link failed $fails consecutive checks (${reasons[*]})"
    dry && return 0
    echo "$now" > "$PERSIST_DIR/last-reboot"
    sync
    systemctl reboot
    return 0
}

# ── Link checks ──────────────────────────────────────────────────────────────

fails=$(read_n "$STATE_DIR/fails")
reasons=()

# 1. NetworkManager device state
state=$(nmcli -t -f DEVICE,STATE dev 2>/dev/null | awk -F: -v i="$IFACE" '$1==i{print $2}')
[[ "$state" == "connected" ]] || reasons+=("nm-state=${state:-unknown}")

# 2. Default gateway answers ping
gw=$(ip -4 route show default dev "$IFACE" 2>/dev/null | awk '{print $3; exit}')
if [[ -z "$gw" ]]; then
    reasons+=("no-default-route")
elif ! ping -c 2 -W 2 -I "$IFACE" "$gw" >/dev/null 2>&1; then
    reasons+=("gateway-unreachable:$gw")
fi

# 3. Broadcast reception (only meaningful when the link otherwise looks fine)
if [[ ${#reasons[@]} -eq 0 ]]; then
    mac=$(cat "/sys/class/net/$IFACE/address")
    if ! timeout "$BCAST_WAIT_SEC" tcpdump -i "$IFACE" -c 1 -n -q -p \
            "(arp or (udp port 5353)) and not ether src $mac" >/dev/null 2>&1; then
        reasons+=("no-broadcasts-in-${BCAST_WAIT_SEC}s")
    fi
fi

[[ "$FORCE_FAIL" == "1" ]] && reasons+=("forced-by-FORCE_FAIL")

if [[ ${#reasons[@]} -eq 0 ]]; then
    (( fails > 0 )) && log "link healthy again after $fails failed check(s)"
    echo 0 > "$STATE_DIR/fails"
else
    fails=$(( fails + 1 ))
    echo "$fails" > "$STATE_DIR/fails"
    log "check failed ($fails/$REBOOT_AFTER): ${reasons[*]}"
    if (( fails >= REBOOT_AFTER )) && try_reboot; then
        exit 0
    elif (( fails % BOUNCE_AFTER == 0 )); then
        bounce
    fi
fi

# ── Tailscale daemon health (restart only, never reboot) ─────────────────────

if command -v tailscale >/dev/null; then
    ts_fails=$(read_n "$STATE_DIR/ts_fails")
    ts_state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState // empty' 2>/dev/null)
    if [[ "$ts_state" == "Running" ]]; then
        (( ts_fails > 0 )) && log "tailscaled running again after $ts_fails bad check(s)"
        echo 0 > "$STATE_DIR/ts_fails"
    else
        ts_fails=$(( ts_fails + 1 ))
        echo "$ts_fails" > "$STATE_DIR/ts_fails"
        log "tailscaled state '${ts_state:-unknown}' ($ts_fails/$BOUNCE_AFTER)"
        if (( ts_fails >= BOUNCE_AFTER )); then
            log "restarting tailscaled"
            dry || systemctl restart tailscaled
            echo 0 > "$STATE_DIR/ts_fails"
        fi
    fi
fi

exit 0
