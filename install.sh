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

    # Office presence selection — y/N per currently-connected BT device / monitor
    echo ""
    echo "--- Office presence detection ---"
    echo "Lunchbot auto opts-in when any selected device/monitor is connected."
    echo "Review each item below. Press Enter to accept the default in brackets."
    echo ""

    # Load existing selections (pipe-separated)
    local existing_devices_raw="" existing_monitors_raw=""
    if [ -f "$ENV_FILE" ]; then
        existing_devices_raw=$(grep '^LUNCHBOT_OFFICE_DEVICES=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
        existing_monitors_raw=$(grep '^LUNCHBOT_OFFICE_MONITORS=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | tr -d '"')
    fi
    local -a existing_devices=() existing_monitors=()
    if [ -n "$existing_devices_raw" ]; then
        IFS='|' read -r -a existing_devices <<< "$existing_devices_raw"
    fi
    if [ -n "$existing_monitors_raw" ]; then
        IFS='|' read -r -a existing_monitors <<< "$existing_monitors_raw"
    fi

    # Currently connected Bluetooth devices
    local bt_connected
    bt_connected=$(system_profiler SPBluetoothDataType 2>/dev/null | awk '
        /^      Connected:/ { c=1; next }
        /^      Not Connected:/ { c=0; next }
        /^    [^ ]/ { c=0 }
        /^          [A-Za-z].*:$/ && c {
            name=$0; gsub(/^ +/,"",name); gsub(/:$/,"",name); print name
        }
    ')

    # Currently connected external monitors, as "ProductName:SerialNumber"
    local monitors_connected
    monitors_connected=$(ioreg -lw0 2>/dev/null | perl -ne '
        next unless /"DisplayAttributes"\s*=/;
        my ($name) = /"ProductName"="([^"]*)"/;
        my ($serial) = /"AlphanumericSerialNumber"="([^"]*)"/;
        next unless defined $name && length $name;
        print "$name:$serial\n";
    ')

    local -a selected_devices=() selected_monitors=()

    _contains() {
        local needle="$1"; shift
        local x
        for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
        return 1
    }

    _ask() {
        local label="$1" default_yes="$2" ans
        if [ "$default_yes" = 1 ]; then
            read -r -p "  ${label} [Y/n] " ans
            [[ ! "$ans" =~ ^[Nn] ]]
        else
            read -r -p "  ${label} [y/N] " ans
            [[ "$ans" =~ ^[Yy] ]]
        fi
    }

    if [ -n "$bt_connected" ]; then
        echo "Bluetooth devices connected right now:"
        while IFS= read -r name; do
            [ -z "$name" ] && continue
            local d_default=0
            _contains "$name" "${existing_devices[@]}" && d_default=1
            if _ask "\"$name\" — office device?" "$d_default"; then
                selected_devices+=("$name")
            fi
        done <<< "$bt_connected"
        echo ""
    fi

    if [ -n "$monitors_connected" ]; then
        echo "External monitors connected right now:"
        while IFS= read -r entry; do
            [ -z "$entry" ] && continue
            local mname="${entry%:*}" mserial="${entry##*:}"
            local m_default=0
            _contains "$entry" "${existing_monitors[@]}" && m_default=1
            local label
            if [ -n "$mserial" ]; then
                label="\"$mname\" (S/N $mserial) — office monitor?"
            else
                label="\"$mname\" (no serial; won't distinguish from same model elsewhere) — office monitor?"
            fi
            if _ask "$label" "$m_default"; then
                selected_monitors+=("$entry")
            fi
        done <<< "$monitors_connected"
        echo ""
    fi

    if [ -z "$bt_connected" ] && [ -z "$monitors_connected" ]; then
        echo "No Bluetooth devices or external monitors connected right now."
        echo "Run install.sh again at the office to configure new signals."
        echo ""
    fi

    # Preserve previously-selected items that aren't currently connected
    local existing
    for existing in "${existing_devices[@]}"; do
        [ -z "$existing" ] && continue
        if ! printf '%s\n' "$bt_connected" | grep -Fqx -- "$existing"; then
            selected_devices+=("$existing")
        fi
    done
    for existing in "${existing_monitors[@]}"; do
        [ -z "$existing" ] && continue
        if ! printf '%s\n' "$monitors_connected" | grep -Fqx -- "$existing"; then
            selected_monitors+=("$existing")
        fi
    done

    # Summary
    if [ ${#selected_devices[@]} -gt 0 ] || [ ${#selected_monitors[@]} -gt 0 ]; then
        echo "Configured office signals:"
        local d m
        for d in "${selected_devices[@]}"; do echo "  ✓ $d (Bluetooth)"; done
        for m in "${selected_monitors[@]}"; do
            local n="${m%:*}" s="${m##*:}"
            if [ -n "$s" ]; then echo "  ✓ $n [S/N $s] (Monitor)"
            else echo "  ✓ $n (Monitor, no serial)"; fi
        done
    else
        echo "No office signals selected — lunchbot will prompt you on each scheduled day."
    fi

    # Join with pipe separator for .env
    local old_ifs="$IFS"
    IFS='|'
    local devices_str="${selected_devices[*]}"
    local monitors_str="${selected_monitors[*]}"
    IFS="$old_ifs"

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
# Office presence — pipe-separated lists populated by install.sh.
# DEVICES: Bluetooth device names (exact match against currently connected).
# MONITORS: "ProductName:AlphanumericSerialNumber" pairs from ioreg.
# Both may be empty — lunchbot falls back to prompting you on scheduled days.
LUNCHBOT_OFFICE_DEVICES="${devices_str}"
LUNCHBOT_OFFICE_MONITORS="${monitors_str}"
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
    <key>RunAtLoad</key>
    <true/>
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
