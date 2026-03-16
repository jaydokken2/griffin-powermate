#!/bin/bash
# Install Griffin PowerMate Daemon
# Controls system volume with rotation, play/pause with button press

set -e

# Resolve the .app bundle path (works whether run directly or via Terminal redirect)
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
BUNDLE_DIR="$(dirname "$(dirname "$SCRIPT_PATH")")"
RESOURCES_DIR="$BUNDLE_DIR/Resources"
SOURCE_FILE="$RESOURCES_DIR/main.swift"
BINARY_NAME="powermate-daemon"
INSTALL_PATH="/usr/local/bin/$BINARY_NAME"
PLIST_NAME="com.powermate.daemon.plist"
PLIST_SRC="$RESOURCES_DIR/$PLIST_NAME"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"

echo "========================================="
echo "  Griffin PowerMate Daemon Installer"
echo "========================================="
echo ""

# Check for source file
if [ ! -f "$SOURCE_FILE" ]; then
    echo "ERROR: Source file not found at $SOURCE_FILE"
    echo ""
    echo "Expected: $SOURCE_FILE"
    echo "Bundle dir: $BUNDLE_DIR"
    echo ""
    echo "Press any key to exit..."
    read -n 1
    exit 1
fi

# Check for Xcode command line tools
if ! xcode-select -p &>/dev/null; then
    echo "ERROR: Xcode Command Line Tools required."
    echo "Install with: xcode-select --install"
    echo "Press any key to exit..."
    read -n 1
    exit 1
fi

# Unload existing daemon if running
if launchctl list | grep -q "com.powermate.daemon" 2>/dev/null; then
    echo "Stopping existing PowerMate daemon..."
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    sleep 1
fi

# Kill any lingering process
killall powermate-daemon 2>/dev/null || true
sleep 1

# Compile
echo "Compiling PowerMate daemon..."
STAGING_DIR=$(mktemp -d "/tmp/powermate_install_XXXXXX")
swiftc "$SOURCE_FILE" \
    -framework IOKit \
    -framework Cocoa \
    -O \
    -o "$STAGING_DIR/$BINARY_NAME"

echo "Compiled successfully."

# Install binary
echo "Installing binary to $INSTALL_PATH (requires admin password)..."
sudo mkdir -p /usr/local/bin
sudo cp "$STAGING_DIR/$BINARY_NAME" "$INSTALL_PATH"
sudo chmod 755 "$INSTALL_PATH"
sudo chown root:wheel "$INSTALL_PATH"

# Install LaunchAgent
echo "Installing LaunchAgent..."
mkdir -p "$HOME/Library/LaunchAgents"
cp "$PLIST_SRC" "$PLIST_DST"

# Clean up staging
rm -rf "$STAGING_DIR"

# Clear old log
> /tmp/powermate-daemon.log

# Load the daemon
echo "Starting PowerMate daemon..."
launchctl load "$PLIST_DST"

# Wait a moment and show initial log
sleep 2
echo ""
echo "Initial log output:"
cat /tmp/powermate-daemon.log 2>/dev/null || echo "(no output yet)"

echo ""
echo "========================================="
echo "  Installation complete!"
echo "========================================="
echo ""
echo "The PowerMate daemon is now running."
echo "  - Rotate the knob to adjust system volume"
echo "  - Press the knob to toggle play/pause"
echo "  - LED brightness reflects current volume"
echo ""
echo "IMPORTANT: You may need to grant Input Monitoring"
echo "permission in System Settings > Privacy & Security"
echo "for the daemon to receive PowerMate events."
echo ""
echo "Logs: /tmp/powermate-daemon.log"
echo ""
echo "Press any key to close..."
read -n 1
