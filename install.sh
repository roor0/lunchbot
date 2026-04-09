#!/bin/bash
# Install lunchbot — interactive setup for .env and LaunchAgent

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
PLIST_NAME="com.lunchbot.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/$PLIST_NAME"

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
        echo "Enter your officelunch.app API token:"
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

    # Write .env
    cat > "$ENV_FILE" <<EOF
LUNCHBOT_TOKEN="${token}"
LUNCHBOT_OFFICE_DEVICE="${device}"
EOF
    echo ""
    echo "Saved $ENV_FILE"
}

# ── LaunchAgent install ─────────────────────────────────────

install_launchagent() {
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
        <dict>
            <key>Weekday</key>
            <integer>2</integer>
            <key>Hour</key>
            <integer>9</integer>
            <key>Minute</key>
            <integer>20</integer>
        </dict>
        <dict>
            <key>Weekday</key>
            <integer>4</integer>
            <key>Hour</key>
            <integer>9</integer>
            <key>Minute</key>
            <integer>20</integer>
        </dict>
    </array>
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

    echo "Installed LaunchAgent: $PLIST_DEST"
    echo "Lunchbot will run at 9:20 AM on Tuesdays and Thursdays."
}

# ── Main ────────────────────────────────────────────────────

setup_env
echo ""
install_launchagent
echo ""
echo "Done! Run 'bash lunchbot.sh' to test now."
