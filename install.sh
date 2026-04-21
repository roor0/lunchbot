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

    # Office hardware selection — one unified y/N list
    echo ""
    echo "--- Office hardware ---"
    echo "Lunchbot auto opts-in when any selected item is connected."
    echo "Review each currently-connected item below (Enter accepts the default)."
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

    # Build a unified candidate list. Each line: "TYPE<TAB>IDENT<TAB>LABEL"
    # TYPE is "bt" or "mon". IDENT is what we match at runtime.
    local candidates=""

    local bt_line
    while IFS= read -r bt_line; do
        [ -z "$bt_line" ] && continue
        candidates+=$'bt\t'"${bt_line}"$'\t'"${bt_line} (Bluetooth)"$'\n'
    done < <(system_profiler SPBluetoothDataType 2>/dev/null | awk '
        /^      Connected:/ { c=1; next }
        /^      Not Connected:/ { c=0; next }
        /^    [^ ]/ { c=0 }
        /^          [A-Za-z].*:$/ && c {
            name=$0; gsub(/^ +/,"",name); gsub(/:$/,"",name); print name
        }
    ')

    local mon_line
    while IFS= read -r mon_line; do
        [ -z "$mon_line" ] && continue
        local mname="${mon_line%:*}" mserial="${mon_line##*:}"
        local mlabel
        if [ -n "$mserial" ]; then
            mlabel="${mname} (Monitor, S/N ${mserial})"
        else
            mlabel="${mname} (Monitor, no serial — won't distinguish from same model elsewhere)"
        fi
        candidates+=$'mon\t'"${mon_line}"$'\t'"${mlabel}"$'\n'
    done < <(ioreg -lw0 2>/dev/null | perl -ne '
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

    if [ -n "$candidates" ]; then
        echo "Currently connected:"
        local line type ident label default_yes
        # Read candidates on FD 3 so _ask's `read` still consumes from stdin (user input)
        while IFS=$'\t' read -r type ident label <&3; do
            [ -z "$type" ] && continue
            default_yes=0
            if [ "$type" = "bt" ]; then
                _contains "$ident" "${existing_devices[@]}" && default_yes=1
            else
                _contains "$ident" "${existing_monitors[@]}" && default_yes=1
            fi
            if _ask "${label} — office hardware?" "$default_yes"; then
                if [ "$type" = "bt" ]; then
                    selected_devices+=("$ident")
                else
                    selected_monitors+=("$ident")
                fi
            fi
        done 3<<< "$candidates"
        echo ""
    else
        echo "No Bluetooth devices or external monitors connected right now."
        echo "Run install.sh again at the office to configure new signals."
        echo ""
    fi

    # Preserve previously-selected items that aren't currently connected
    local existing
    for existing in "${existing_devices[@]}"; do
        [ -z "$existing" ] && continue
        if ! printf '%s' "$candidates" | awk -F'\t' -v e="$existing" '$1=="bt" && $2==e { found=1 } END { exit !found }'; then
            selected_devices+=("$existing")
        fi
    done
    for existing in "${existing_monitors[@]}"; do
        [ -z "$existing" ] && continue
        if ! printf '%s' "$candidates" | awk -F'\t' -v e="$existing" '$1=="mon" && $2==e { found=1 } END { exit !found }'; then
            selected_monitors+=("$existing")
        fi
    done

    # Summary
    if [ ${#selected_devices[@]} -gt 0 ] || [ ${#selected_monitors[@]} -gt 0 ]; then
        echo "Configured office hardware:"
        local d m
        for d in "${selected_devices[@]}"; do echo "  ✓ $d (Bluetooth)"; done
        for m in "${selected_monitors[@]}"; do
            local n="${m%:*}" s="${m##*:}"
            if [ -n "$s" ]; then echo "  ✓ $n [S/N $s] (Monitor)"
            else echo "  ✓ $n (Monitor, no serial)"; fi
        done
    else
        echo "No office hardware selected — lunchbot will prompt you on each scheduled day."
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

    # Reload the agent via the modern bootstrap API. bootout takes the service
    # label (no .plist), not the plist filename.
    local service_label="${PLIST_NAME%.plist}"
    local domain="gui/$(id -u)"
    launchctl bootout "${domain}/${service_label}" 2>/dev/null || true
    launchctl bootstrap "$domain" "$PLIST_DEST"

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
