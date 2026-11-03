#!/bin/zsh
# Builds Teleprompter.app into ./build and (optionally) copies it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/Teleprompter.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Teleprompter "$APP/Contents/MacOS/Teleprompter"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --identifier au.edu.adelaide.teleprompter "$APP"
echo "Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/Teleprompter.app
  cp -R "$APP" ~/Applications/
  echo "Installed to ~/Applications/Teleprompter.app"
fi
