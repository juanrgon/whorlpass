#!/usr/bin/env bash
# Build whorlpass and install the ctrl+option+cmd+P hotkey agent.
#
#   ./install.sh              build, install to ~/.local/bin, start the agent
#   ./install.sh --no-agent   build and install the command only
#
# Set PREFIX to install somewhere else (the binary goes in $PREFIX/bin).
set -euo pipefail

cd "$(dirname "$0")"

prefix="${PREFIX:-$HOME/.local}"
bin_dir="$prefix/bin"
bin="$bin_dir/whorlpass"
data_dir="$HOME/.local/share/whorlpass"
label="com.whorlpass.agent"
plist="$HOME/Library/LaunchAgents/$label.plist"
domain="gui/$(id -u)"

install_agent=true
for arg in "$@"; do
  case "$arg" in
    --no-agent) install_agent=false ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Install the Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

mkdir -p "$bin_dir"
mkdir -p "$data_dir"
chmod 700 "$data_dir"

echo "Building $bin"
swiftc -O -o "$bin" whorlpass.swift

if [ "$install_agent" = true ]; then
  mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$label</string>
	<key>ProgramArguments</key>
	<array>
		<string>$bin</string>
		<string>agent</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
	<key>ProcessType</key>
	<string>Interactive</string>
	<key>StandardErrorPath</key>
	<string>$data_dir/agent.log</string>
</dict>
</plist>
EOF
  plutil -lint "$plist" >/dev/null
  launchctl bootout "$domain/$label" 2>/dev/null || true
  launchctl bootstrap "$domain" "$plist"
  echo "Started $label (log: $data_dir/agent.log)"
fi

case ":$PATH:" in
  *":$bin_dir:"*) ;;
  *) echo "Note: $bin_dir is not on your PATH." ;;
esac

echo "Done. Store a secret with: whorlpass set"
