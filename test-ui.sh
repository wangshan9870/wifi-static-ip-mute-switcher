#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/ui-check
# Compile the real delegate without its application run loop. The harness uses
# fixture state and never starts monitoring, changes preferences, or controls audio.
sed '/^let application = NSApplication.shared/,$d' Sources/main.swift > build/ui-check/AppDelegate.swift
swiftc -swift-version 5 -O Sources/Policy.swift Sources/NetworkMonitor.swift Sources/UpdateChecker.swift Sources/SpeakerAudio.swift Sources/SettingsUI.swift \
  build/ui-check/AppDelegate.swift Tests/UI/main.swift -o build/ui-check/check \
  -framework AppKit -framework SystemConfiguration -framework ServiceManagement -framework CoreAudio
./build/ui-check/check
