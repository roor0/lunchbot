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
OFFICE_DEVICES="${LUNCHBOT_OFFICE_DEVICES:-}"
OFFICE_MONITORS="${LUNCHBOT_OFFICE_MONITORS:-}"
API_BASE="https://officelunch.app"
API_URL="${API_BASE}/api/v1/opt-in"
DASHBOARD_URL="${API_BASE}/dashboard"
LOG_FILE="${SCRIPT_DIR}/lunchbot.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

# Pull latest from origin. Skips if not a git repo, offline, or local changes
# would block a fast-forward — always non-fatal.
update_self() {
    if ! git -C "$SCRIPT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
        return
    fi
    local before after
    before=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)
    if ! git -C "$SCRIPT_DIR" pull --ff-only --quiet 2>>"$LOG_FILE"; then
        log "Self-update skipped (pull failed — local changes or conflict)"
        return
    fi
    after=$(git -C "$SCRIPT_DIR" rev-parse HEAD 2>/dev/null)
    if [ "$before" != "$after" ]; then
        log "Self-updated: ${before:0:7} → ${after:0:7}"
    fi
}

# True if install.sh has changed since the last recorded install. The installer
# writes HEAD to .installed-at-sha; we diff that range for install.sh edits.
needs_reinstall() {
    local sha_file="${SCRIPT_DIR}/.installed-at-sha"
    [ -f "$sha_file" ] || return 1
    local installed_sha
    installed_sha=$(cat "$sha_file" 2>/dev/null)
    [ -n "$installed_sha" ] || return 1
    git -C "$SCRIPT_DIR" diff --name-only "$installed_sha" HEAD 2>/dev/null \
        | grep -qx 'install.sh'
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

# Check if any configured Bluetooth device or monitor is currently connected
is_at_office() {
    if [ -n "$OFFICE_DEVICES" ]; then
        local bt_now
        bt_now=$(system_profiler SPBluetoothDataType 2>/dev/null | awk '
            /^      Connected:/ { c=1; next }
            /^      Not Connected:/ { c=0; next }
            /^    [^ ]/ { c=0 }
            /^          [A-Za-z].*:$/ && c {
                name=$0; gsub(/^ +/,"",name); gsub(/:$/,"",name); print name
            }
        ')
        local IFS='|' name
        for name in $OFFICE_DEVICES; do
            [ -z "$name" ] && continue
            if printf '%s\n' "$bt_now" | grep -Fqx -- "$name"; then
                return 0
            fi
        done
    fi

    if [ -n "$OFFICE_MONITORS" ]; then
        local mon_now
        mon_now=$(ioreg -lw0 2>/dev/null | perl -ne '
            next unless /"DisplayAttributes"\s*=/;
            my ($name) = /"ProductName"="([^"]*)"/;
            my ($serial) = /"AlphanumericSerialNumber"="([^"]*)"/;
            next unless defined $name && length $name;
            print "$name:$serial\n";
        ')
        local IFS='|' entry
        for entry in $OFFICE_MONITORS; do
            [ -z "$entry" ] && continue
            if printf '%s\n' "$mon_now" | grep -Fqx -- "$entry"; then
                return 0
            fi
        done
    fi

    return 1
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

ICON_PATH="${SCRIPT_DIR}/icon.png"

notify() {
    osascript -e "display notification \"$1\" with title \"Lunchbot\" sound name \"Glass\"" >/dev/null 2>&1
}

show_success() {
    notify "You're in for lunch today!"
    osascript <<EOF
activate
display dialog "You're in for lunch today!" buttons {"OK"} default button "OK" with title "Lunchbot" with icon (POSIX file "${ICON_PATH}")
EOF
}

show_already_opted_in() {
    notify "You're already in for lunch today"
    osascript <<EOF
activate
display dialog "You were already opted in for lunch today." buttons {"OK"} default button "OK" with title "Lunchbot" with icon (POSIX file "${ICON_PATH}")
EOF
}

show_failure() {
    notify "Failed to opt in for lunch"
    local btn
    btn=$(osascript <<EOF
activate
button returned of (display dialog "Failed to opt in for lunch.

Click below to opt in manually:" buttons {"Dismiss", "Open Dashboard"} default button "Open Dashboard" with title "Lunchbot" with icon (POSIX file "${ICON_PATH}"))
EOF
    )
    [ "$btn" = "Open Dashboard" ] && open "https://officelunch.app/dashboard"
}

prompt_user() {
    notify "Opt in for lunch today?"
    osascript <<EOF
activate
button returned of (display dialog "You're not at the office.

Would you like to opt in for lunch today?" buttons {"No", "Yes"} default button "Yes" with title "Lunchbot" with icon (POSIX file "${ICON_PATH}"))
EOF
}

prompt_reinstall() {
    notify "Lunchbot installer update available"
    local btn
    btn=$(osascript <<EOF
activate
button returned of (display dialog "Lunchbot was updated and the installer has changed.

Re-run the installer to apply LaunchAgent updates (schedule, plist format, etc)." buttons {"Later", "Run Installer"} default button "Run Installer" with title "Lunchbot Update" with icon (POSIX file "${ICON_PATH}"))
EOF
    )
    if [ "$btn" = "Run Installer" ]; then
        log "User chose to re-run installer"
        osascript \
            -e "tell application \"Terminal\" to do script \"cd '${SCRIPT_DIR}' && bash install.sh\"" \
            -e 'tell application "Terminal" to activate' >/dev/null 2>&1
    else
        log "User dismissed reinstall prompt"
    fi
}

# --- Main ---

log "=== Lunchbot starting ==="

# Only run on Tue (2) / Thu (4). Guards RunAtLoad triggers on other days.
DOW=$(date +%u)
if [ "$DOW" != "2" ] && [ "$DOW" != "4" ]; then
    log "Not a lunch day (dow=$DOW) — exiting"
    exit 0
fi

if ! wait_for_network; then
    log "No network after 60s, showing failure"
    show_failure
    exit 1
fi

update_self

if verify_status; then
    log "Already opted in today — notifying user"
    show_already_opted_in
    needs_reinstall && prompt_reinstall
    exit 0
fi

if is_at_office; then
    log "Office signal detected — auto opting in"

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
    log "No office signal detected — prompting"
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

needs_reinstall && prompt_reinstall

log "=== Lunchbot finished ==="
