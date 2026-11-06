#!/usr/bin/env bash
# Stop the hotkey agent and remove the whorlpass command.
#
# Your key and encrypted secrets in ~/.local/share/whorlpass are left alone.
# Delete that folder yourself if you no longer need them. They cannot be
# recovered afterward.
set -euo pipefail

prefix="${PREFIX:-$HOME/.local}"
bin="$prefix/bin/whorlpass"
label="com.whorlpass.agent"
plist="$HOME/Library/LaunchAgents/$label.plist"

launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
rm -f "$plist" "$bin"

echo "Removed the agent and $bin."
echo "Secrets are still in $HOME/.local/share/whorlpass."
