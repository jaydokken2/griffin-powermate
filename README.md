# Griffin PowerMate Controller for macOS

A lightweight macOS daemon that brings the Griffin PowerMate USB knob back to life on modern macOS (Sequoia and later). No kernel extensions, no third-party drivers — just a native daemon using IOKit HID.

## Features

- **Volume control** — Rotate the knob to adjust system volume
- **Play/Pause** — Press the knob to toggle media playback (uses Apple's MediaRemote framework — no Accessibility permission needed)
- **LED** — Blue LED stays on persistently while the daemon is running, with a keep-alive timer to prevent it from turning off
- **Hot-plug support** — Automatically detects when the PowerMate is connected or disconnected
- **Launch at login** — Runs as a background LaunchAgent, starts automatically at login

## Requirements

- macOS 14+ (tested on macOS 15 Sequoia)
- Griffin PowerMate USB (corded) — Vendor ID `0x077d`, Product ID `0x0410`
- Xcode Command Line Tools (`xcode-select --install`)
- Input Monitoring permission (System Settings > Privacy & Security)

## Install

1. Double-click **Install PowerMate.app**
2. Enter your administrator password when prompted
3. Grant **Input Monitoring** permission when prompted by macOS

The installer compiles the daemon from source, installs it to `/usr/local/bin/`, and sets up a LaunchAgent to start it automatically.

## Uninstall

1. Double-click **Uninstall PowerMate.command**
2. Enter your administrator password when prompted

This stops the daemon, removes the binary, and removes the LaunchAgent.

## How It Works

The daemon uses three macOS frameworks:

- **IOKit HID** — Reads button presses and rotation events from the PowerMate USB device
- **CoreAudio** — Directly adjusts the default output device volume (no media key simulation needed for volume)
- **MediaRemote** (private framework) — Sends play/pause commands to the active media player without requiring Accessibility permission

The LED is controlled via USB vendor control requests (the same protocol used by the Linux kernel driver), implemented in a small C helper (`powermate-led`) since the USB control message macros don't bridge to Swift.

## File Structure

```
PowerMate/
  main.swift          # Main daemon source code
  powermate-led.c     # LED control helper (USB vendor requests)
Install PowerMate.app  # Double-click installer
Uninstall PowerMate.command
com.powermate.daemon.plist  # LaunchAgent configuration
```

## Troubleshooting

- **No response from knob:** Grant Input Monitoring permission to `powermate-daemon` in System Settings > Privacy & Security > Input Monitoring
- **Play/pause not working:** The daemon uses Apple's MediaRemote framework which should work without extra permissions. Check the log for errors.
- **LED not staying on:** The daemon refreshes the LED every 5 seconds. If it still turns off, check `/tmp/powermate-daemon.log` for LED errors.
- **Daemon not running:** Check `launchctl list | grep powermate` and review logs at `/tmp/powermate-daemon.log`
- **Wrong device:** This only supports the original corded USB PowerMate (VID `0x077d`, PID `0x0410`), not the Bluetooth PowerMate.

## Technical Notes

- The PowerMate reports dial rotation as HID usage `0x33` (Rx axis), not the standard `0x37` (Dial) — the daemon handles both
- LED control requires USB vendor control requests (`bmRequestType=0x41, bRequest=0x01, wValue=0x01, wIndex=brightness`) — standard HID output/feature reports are silently ignored by the device
- Volume is adjusted in ~2% increments per rotation tick via `kAudioDevicePropertyVolumeScalar`

## License

MIT
