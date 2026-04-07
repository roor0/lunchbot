#!/bin/bash
# lunchbot — Auto opt-in for office lunch on Tue/Thu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Load config from .env
if [ -f "${SCRIPT_DIR}/.env" ]; then
    source "${SCRIPT_DIR}/.env"
else
    echo "Missing .env file. Copy .env.example to .env and fill in your values." >&2
    exit 1
fi

TOKEN="${LUNCHBOT_TOKEN:?Set LUNCHBOT_TOKEN in .env}"
OFFICE_KEYBOARD="${LUNCHBOT_KEYBOARD:?Set LUNCHBOT_KEYBOARD in .env}"
API_BASE="https://officelunch.app"
API_URL="${API_BASE}/api/v1/opt-in"
DASHBOARD_URL="${API_BASE}/dashboard"
LOG_FILE="${SCRIPT_DIR}/lunchbot.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# Laptop may have just woken — wait for network connectivity
wait_for_network() {
    local attempts=0
    while [ $attempts -lt 30 ]; do
        if curl -sf --connect-timeout 3 -o /dev/null "$API_BASE"; then
            return 0
        fi
        sleep 2
        attempts=$((attempts + 1))
    done
    return 1
}

# Check if the office Bluetooth keyboard is connected
is_at_office() {
    hidutil list 2>/dev/null | grep -q "$OFFICE_KEYBOARD"
}

# POST /api/v1/opt-in — opt in for today
do_opt_in() {
    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X POST "$API_URL" \
        -H "Authorization: Bearer $TOKEN" \
        -H "Content-Type: application/json" \
        -d '{"action": "in"}')
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    log "Opt-in response: HTTP $http_code — $body"

    if echo "$body" | grep -q '"success":\s*true'; then
        return 0
    fi
    if [ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 300 ] 2>/dev/null; then
        return 0
    fi
    return 1
}

# GET /api/v1/opt-in — check today's status
verify_status() {
    local response http_code body
    response=$(curl -s -w "\n%{http_code}" \
        -X GET "$API_URL" \
        -H "Authorization: Bearer $TOKEN")
    http_code=$(echo "$response" | tail -1)
    body=$(echo "$response" | sed '$d')
    log "Status check: HTTP $http_code — $body"

    if [ "$http_code" -ge 200 ] 2>/dev/null && [ "$http_code" -lt 300 ] 2>/dev/null; then
        if echo "$body" | grep -q '"optedIn":\s*true'; then
            return 0
        fi
        if echo "$body" | grep -q '"status":\s*"opted-in"'; then
            return 0
        fi
    fi
    return 1
}

show_success() {
    osascript <<'EOF'
tell application "System Events"
    activate
    display dialog "You're in for lunch today!" buttons {"OK"} default button "OK" with title "Lunchbot" with icon note
end tell
EOF
}

show_failure() {
    local btn
    btn=$(osascript <<'EOF'
tell application "System Events"
    activate
    button returned of (display dialog "Failed to opt in for lunch.

Click below to opt in manually:" buttons {"Dismiss", "Open Dashboard"} default button "Open Dashboard" with title "Lunchbot" with icon caution)
end tell
EOF
    )
    [ "$btn" = "Open Dashboard" ] && open "https://officelunch.app/dashboard"
}

prompt_user() {
    osascript <<'EOF'
tell application "System Events"
    activate
    button returned of (display dialog "You're not at the office.

Would you like to opt in for lunch today?" buttons {"No", "Yes"} default button "Yes" with title "Lunchbot" with icon note)
end tell
EOF
}

# --- Main ---

log "=== Lunchbot starting ==="

if ! wait_for_network; then
    log "No network after 60s, showing failure"
    show_failure
    exit 1
fi

if is_at_office; then
    log "Office keyboard detected — auto opting in"

    if do_opt_in; then
        sleep 1
        if verify_status; then
            log "Verified: opted in"
            show_success
        else
            log "Opt-in call succeeded but verification failed"
            show_failure
        fi
    else
        log "Opt-in call failed"
        show_failure
    fi
else
    log "Office keyboard not detected — prompting"
    CHOICE=$(prompt_user)

    if [ "$CHOICE" = "Yes" ]; then
        log "User chose to opt in"
        if do_opt_in; then
            show_success
        else
            show_failure
        fi
    else
        log "User declined"
    fi
fi

log "=== Lunchbot finished ==="
