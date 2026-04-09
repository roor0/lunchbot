# Lunchbot

A macOS automation that opts you into office lunch on [officelunch.app](https://officelunch.app) every Tuesday and Thursday.

If you're at the office (detected by a paired Bluetooth device like a keyboard or mouse), it opts in automatically. If not, it pops up a dialog asking if you'd like to opt in anyway.

## Setup

Run the install script — it walks you through everything:

```
./install.sh
```

It will:
1. Prompt for your officelunch.app API token
2. List your paired Bluetooth devices so you can pick a match string for office detection (e.g. `"Blackthorn Magic"` matches both a keyboard and mouse)
3. Save your config to `.env`
4. Install and load a LaunchAgent to run at 9:20 AM on Tue/Thu

To run manually any time:

```
bash lunchbot.sh
```

## How it works

1. Waits for network connectivity (handles laptop wake-from-sleep)
2. Checks if an office device is connected via `hidutil list`
3. If at the office: auto opts in via the officelunch.app API, verifies, and shows a confirmation dialog
4. If not at the office: prompts you with a Yes/No dialog
5. Logs everything to `lunchbot.log`
