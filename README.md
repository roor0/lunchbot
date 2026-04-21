# Lunchbot

A macOS automation that opts you into office lunch on [officelunch.app](https://officelunch.app) every Tuesday and Thursday.

If you're at the office (detected by a paired Bluetooth device like a keyboard or mouse, or by a specific external monitor), it opts in automatically. If not — or if you haven't configured either signal — it pops up a dialog asking if you'd like to opt in anyway.

## Setup

Run the install script — it walks you through everything:

```
./install.sh
```

It will:
1. Prompt for your officelunch.app API token
2. List your paired Bluetooth devices so you can pick a match string for office detection (e.g. `"Blackthorn Magic"` matches both a keyboard and mouse) — optional
3. List connected external monitors so you can pick one as a fallback signal — optional
4. Save your config to `.env`
5. Install and load a LaunchAgent to run on your configured days (defaults to Tue/Thu at a random minute in the 9 AM hour)

To run manually any time:

```
bash lunchbot.sh
```

## How it works

1. Waits for network connectivity (handles laptop wake-from-sleep)
2. Checks for a configured office Bluetooth device (`hidutil list`) and/or external monitor (`system_profiler SPDisplaysDataType`)
3. If at the office: auto opts in via the officelunch.app API, verifies, and shows a confirmation dialog
4. If not at the office (or no signals are configured): prompts you with a Yes/No dialog
5. Logs everything to `lunchbot.log`
