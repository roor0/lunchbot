#!/bin/bash
# Install lunchbot — interactive setup for .env and LaunchAgent

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
PLIST_NAME="com.lunchbot.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

DAY_NAMES=(unused Monday Tuesday Wednesday Thursday Friday Saturday Sunday)

# ── .env setup ──────────────────────────────────────────────

setup_env() {
    echo ""
    echo "=== Lunchbot Setup ==="
    echo ""

    # API token
    local token=""
    if [ -f "$ENV_FILE" ]; then
        token=$(grep '^LUNCHBOT_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
    fi
    if [ -n "$token" ] && [ "$token" != "olm_your_token_here" ]; then
        echo "API token: already configured"
    else
        echo "Enter your officelunch.app API token."
        echo "Create one at: https://officelunch.app/tokens"
        echo ""
        echo "Token:"
        read -r token
        if [ -z "$token" ]; then
            echo "Error: token is required." >&2
            exit 1
        fi
    fi

    # Office device
    echo ""
    echo "Paired Bluetooth devices:"
    echo ""

    local devices
    devices=$(system_profiler SPBluetoothDataType 2>/dev/null | awk '
        /^      Connected:/ { section="connected"; next }
        /^      Not Connected:/ { section="paired"; next }
        /^    [^ ]/ { section="" }
        /^          [A-Za-z]/ && section {
            if (name != "") {
                if (type != "") print name " [" type ", " prev_section "]"
                else print name " [" prev_section "]"
            }
            name=$0; gsub(/^ +/,"",name); gsub(/:$/,"",name)
            type=""
            prev_section=section
        }
        /Minor Type:/ {
            type=$0; gsub(/.*Minor Type: /,"",type); gsub(/^ +| +$/,"",type)
        }
        END {
            if (name != "") {
                if (type != "") print name " [" type ", " prev_section "]"
                else print name " [" prev_section "]"
            }
        }
    ')

    local i=1
    while IFS= read -r line; do
        printf "  %2d) %s\n" "$i" "$line"
        i=$((i + 1))
    done <<< "$devices"

    echo ""
    echo "Enter a search string that matches your office device(s)."
    echo "Tip: use a substring common to multiple devices, e.g. \"Blackthorn Magic\""
    echo "     to match both a keyboard and mouse."
    echo ""

    local device=""
    if [ -f "$ENV_FILE" ]; then
        device=$(grep '^LUNCHBOT_OFFICE_DEVICE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
    fi
    if [ -n "$device" ] && [ "$device" != "Your Device Name" ]; then
        local matches
        matches=$(echo "$devices" | grep -c "$device" || true)
        echo "Current match string: \"$device\" ($matches device(s) matched)"
        echo "Press Enter to keep, or type a new string:"
    else
        echo "Match string:"
    fi
    read -r new_device
    if [ -n "$new_device" ]; then
        device="$new_device"
    fi
    if [ -z "$device" ]; then
        echo "Error: device match string is required." >&2
        exit 1
    fi

    # Show what will match
    local matches
    matches=$(echo "$devices" | grep "$device" || true)
    if [ -n "$matches" ]; then
        echo ""
        echo "Matched devices:"
        echo "$matches" | sed 's/^/  ✓ /'
    else
        echo ""
        echo "Warning: no currently visible devices match \"$device\"."
        echo "This is OK if the device isn't connected right now."
    fi

    # Schedule — read existing or generate defaults
    local days="" hour="" minute=""
    if [ -f "$ENV_FILE" ]; then
        days=$(grep '^LUNCHBOT_DAYS=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
        hour=$(grep '^LUNCHBOT_HOUR=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
        minute=$(grep '^LUNCHBOT_MINUTE=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
    fi

    # Default: Tue/Thu, random minute between 9:00–9:59
    if [ -z "$days" ]; then
        days="2,4"
    fi
    if [ -z "$hour" ] || [ -z "$minute" ]; then
        hour="9"
        minute=$((RANDOM % 60))
    fi

    # Format day names for display
    local day_display=""
    IFS=',' read -ra day_nums <<< "$days"
    for d in "${day_nums[@]}"; do
        if [ -n "$day_display" ]; then day_display+=", "; fi
        day_display+="${DAY_NAMES[$d]}"
    done

    echo ""
    echo "Schedule: ${day_display} at ${hour}:$(printf '%02d' "$minute")"

    # Write .env
    cat > "$ENV_FILE" <<EOF
LUNCHBOT_TOKEN="${token}"
LUNCHBOT_OFFICE_DEVICE="${device}"
# Schedule is baked into the LaunchAgent at install time.
# To change when lunchbot runs, edit these values and re-run install.sh.
LUNCHBOT_DAYS="${days}"
LUNCHBOT_HOUR="${hour}"
LUNCHBOT_MINUTE="${minute}"
EOF
    echo ""
    echo "Saved $ENV_FILE"
}

# ── LaunchAgent install ─────────────────────────────────────

install_launchagent() {
    # Read schedule from .env
    local days hour minute
    days=$(grep '^LUNCHBOT_DAYS=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')
    hour=$(grep '^LUNCHBOT_HOUR=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')
    minute=$(grep '^LUNCHBOT_MINUTE=' "$ENV_FILE" | cut -d= -f2- | tr -d '"')

    # Build calendar interval entries
    local intervals=""
    IFS=',' read -ra day_nums <<< "$days"
    for d in "${day_nums[@]}"; do
        intervals+="        <dict>
            <key>Weekday</key>
            <integer>${d}</integer>
            <key>Hour</key>
            <integer>${hour}</integer>
            <key>Minute</key>
            <integer>${minute}</integer>
        </dict>
"
    done

    mkdir -p "$HOME/Library/LaunchAgents"

    cat > "$PLIST_DEST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.lunchbot</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${SCRIPT_DIR}/lunchbot.sh</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
${intervals}    </array>
    <key>StandardOutPath</key>
    <string>${SCRIPT_DIR}/launchd-stdout.log</string>
    <key>StandardErrorPath</key>
    <string>${SCRIPT_DIR}/launchd-stderr.log</string>
</dict>
</plist>
EOF

    # Load the agent (unload first if already loaded)
    launchctl bootout "gui/$(id -u)/$PLIST_NAME" 2>/dev/null || true
    launchctl load "$PLIST_DEST"

    # Format day names for display
    local day_display=""
    for d in "${day_nums[@]}"; do
        if [ -n "$day_display" ]; then day_display+=", "; fi
        day_display+="${DAY_NAMES[$d]}"
    done

    echo "Installed LaunchAgent: $PLIST_DEST"
    echo "Lunchbot will run at ${hour}:$(printf '%02d' "$minute") on ${day_display}."
}

# ── Main ────────────────────────────────────────────────────

setup_env
echo ""
install_launchagent
echo ""
echo "Done! Run 'bash lunchbot.sh' to test now."
