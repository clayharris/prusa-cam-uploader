#!/bin/sh
# Pushes JPEG snapshots from a camera's HTTP endpoint to Prusa Connect.
# Optionally uploads only while the printer (via PrusaLink) is in an active state.
set -u

# ---- Required ----
: "${PRUSA_CONNECT_TOKEN:?PRUSA_CONNECT_TOKEN is required}"
: "${PRUSA_CONNECT_FINGERPRINT:?PRUSA_CONNECT_FINGERPRINT is required}"
: "${CAMERA_SNAPSHOT_URL:?CAMERA_SNAPSHOT_URL is required}"

# ---- Optional ----
: "${PRUSA_CONNECT_URL:=https://connect.prusa3d.com/c/snapshot}"
: "${CAMERA_AUTH_HEADER:=}"          # e.g. "Authorization: Bearer xyz" (leave empty if token is in URL)
: "${PRUSALINK_URL:=}"               # e.g. http://192.168.1.50 ; empty = always upload
: "${PRUSALINK_USER:=maker}"
: "${PRUSALINK_PASSWORD:=}"
: "${PRUSALINK_API_KEY:=}"           # if set, used instead of digest auth
: "${UPLOAD_STATES:=PRINTING PAUSED ATTENTION}"
: "${UPLOAD_INTERVAL:=10}"           # seconds between uploads while active (Connect min ~10)
: "${IDLE_INTERVAL:=30}"             # seconds between status polls while idle
: "${MAX_FAILURES:=30}"              # consecutive capture/upload failures before exit (restart)
: "${HTTP_TIMEOUT:=15}"

SNAP=/tmp/snapshot.jpg
RESP=/tmp/upload_resp
HEARTBEAT=/tmp/heartbeat

log() { echo "$(date '+%Y-%m-%dT%H:%M:%S%z') $*"; }
die() { log "FATAL: $*"; exit 1; }

# Log only when the status message changes, to avoid flooding logs every 10s
last_status=""
report() {
    if [ "$1" != "$last_status" ]; then
        log "$1"
        last_status=$1
    fi
}

# ---- Validate config ----
case "$PRUSA_CONNECT_FINGERPRINT" in
    *[!A-Za-z0-9]*) die "fingerprint must be alphanumeric" ;;
esac
fp_len=${#PRUSA_CONNECT_FINGERPRINT}
[ "$fp_len" -ge 16 ] && [ "$fp_len" -le 40 ] || die "fingerprint must be 16-40 chars (got $fp_len)"

for v in UPLOAD_INTERVAL IDLE_INTERVAL MAX_FAILURES HTTP_TIMEOUT; do
    eval "val=\$$v"
    case "$val" in ''|*[!0-9]*) die "$v must be a positive integer" ;; esac
done

# ---- Functions ----
get_printer_state() {
    set -- -sf --connect-timeout 5 --max-time "$HTTP_TIMEOUT"
    if [ -n "$PRUSALINK_API_KEY" ]; then
        set -- "$@" -H "X-Api-Key: $PRUSALINK_API_KEY"
    else
        set -- "$@" --digest -u "$PRUSALINK_USER:$PRUSALINK_PASSWORD"
    fi
    resp=$(curl "$@" "$PRUSALINK_URL/api/v1/status") || return 1
    printf '%s' "$resp" | jq -er '.printer.state'
}

state_is_active() {
    case " $UPLOAD_STATES " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

capture() {
    rm -f "$SNAP"
    set -- -sf --connect-timeout 5 --max-time "$HTTP_TIMEOUT" -o "$SNAP"
    [ -n "$CAMERA_AUTH_HEADER" ] && set -- "$@" -H "$CAMERA_AUTH_HEADER"
    curl "$@" "$CAMERA_SNAPSHOT_URL" || return 1
    [ -s "$SNAP" ] || return 1
    # Verify JPEG magic bytes (FF D8) so we never upload an HTML error page
    magic=$(head -c 2 "$SNAP" | od -An -tx1 | tr -d ' \n')
    [ "$magic" = "ffd8" ]
}

upload() {
    code=$(curl -s -o "$RESP" -w '%{http_code}' \
        --connect-timeout 5 --max-time "$HTTP_TIMEOUT" \
        -X PUT "$PRUSA_CONNECT_URL" \
        -H "Token: $PRUSA_CONNECT_TOKEN" \
        -H "Fingerprint: $PRUSA_CONNECT_FINGERPRINT" \
        -H "Content-Type: image/jpg" \
        --data-binary "@$SNAP") || { log "upload: connection error"; return 1; }
    case "$code" in
        2??) return 0 ;;
    esac
    log "upload: HTTP $code: $(head -c 300 "$RESP" 2>/dev/null)"
    return 1
}

# Interruptible sleep so SIGTERM from Docker is handled immediately
nap() { sleep "$1" & wait $!; }

trap 'log "received stop signal, exiting"; exit 0' TERM INT

# ---- Main loop ----
log "starting: connect=$PRUSA_CONNECT_URL camera=${CAMERA_SNAPSHOT_URL%%\?*} prusalink=${PRUSALINK_URL:-<disabled>}"
failures=0

while :; do
    state="ALWAYS"
    if [ -n "$PRUSALINK_URL" ]; then
        if ! state=$(get_printer_state); then
            # Printer off or unreachable is a normal condition, not a failure
            report "PrusaLink unreachable; treating printer as idle"
            touch "$HEARTBEAT"
            nap "$IDLE_INTERVAL"
            continue
        fi
        if ! state_is_active "$state"; then
            report "printer state $state; not uploading"
            touch "$HEARTBEAT"
            failures=0
            nap "$IDLE_INTERVAL"
            continue
        fi
    fi

    if capture && upload; then
        report "printer state $state; uploading every ${UPLOAD_INTERVAL}s"
        touch "$HEARTBEAT"
        failures=0
    else
        failures=$((failures + 1))
        last_status=""   # force next success to be logged
        log "capture/upload failed ($failures/$MAX_FAILURES)"
        [ "$failures" -ge "$MAX_FAILURES" ] && die "too many consecutive failures"
    fi
    nap "$UPLOAD_INTERVAL"
done
