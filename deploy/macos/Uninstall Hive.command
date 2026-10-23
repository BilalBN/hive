#!/bin/bash
# Removes Hive from this Mac. Your music and Hive's data (people, playlists,
# backups in ~/Library/Application Support/Hive) are kept.
echo "Removing Hive. Your music and Hive's data stay."
uid="$(id -u)"
launchctl bootout "gui/$uid/family.hive.server" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/family.hive.server.plist"
sudo rm -rf "/Applications/Hive Server"
sudo pkgutil --forget family.hive.server >/dev/null 2>&1 || true
echo "Done. Hive's data is still in $HOME/Library/Application Support/Hive"
