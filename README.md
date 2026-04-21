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
2. Walk you through each currently-connected Bluetooth device and external monitor, asking y/N for each — "yes" marks it as an office signal
3. Save your selections to `.env`
4. Install and load a LaunchAgent to run on your configured days (defaults to Tue/Thu at a random minute in the 9 AM hour)

Monitors are identified by model + serial number, so a same-model monitor at home won't trigger detection. Bluetooth devices are matched by exact name. Re-run `install.sh` at the office to add or revise signals; items not currently connected are preserved across runs.

To run manually any time:

```
bash lunchbot.sh
```

## How it works

1. Waits for network connectivity (handles laptop wake-from-sleep)
2. Reads currently-connected Bluetooth devices (`system_profiler SPBluetoothDataType`) and displays (`ioreg`), comparing against the lists saved in `.env`
3. If any configured signal matches: auto opts in via the officelunch.app API, verifies, and shows a confirmation dialog
4. If nothing matches (or no signals are configured): prompts you with a Yes/No dialog
5. Logs everything to `lunchbot.log`
