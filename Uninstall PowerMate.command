#!/bin/bash
# Uninstall Griffin PowerMate Daemon

set -e

BINARY_NAME="powermate-daemon"
INSTALL_PATH="/usr/local/bin/$BINARY_NAME"
PLIST_NAME="com.powermate.daemon.plist"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_NAME"

echo "========================================="
echo "  Griffin PowerMate Daemon Uninstaller"
echo "========================================="
echo ""

# Stop the daemon
if launchctl list | grep -q "com.powermate.daemon" 2>/dev/null; then
    echo "Stopping PowerMate daemon..."
    launchctl unload "$PLIST_DST" 2>/dev/null || true
fi

# Remove LaunchAgent
if [ -f "$PLIST_DST" ]; then
    echo "Removing LaunchAgent..."
    rm -f "$PLIST_DST"
fi

# Remove binary
if [ -f "$INSTALL_PATH" ]; then
    echo "Removing binary (requires admin password)..."
    sudo rm -f "$INSTALL_PATH"
fi

# Remove log
if [ -f "/tmp/powermate-daemon.log" ]; then
    rm -f "/tmp/powermate-daemon.log"
fi

echo ""
echo "========================================="
echo "  Uninstall complete!"
echo "========================================="
echo ""
echo "The Griffin PowerMate daemon has been removed."
echo ""
