#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
swiftc Sources/Policy.swift Tests/main.swift -o build/policy-tests
./build/policy-tests
bash -n Resources/install-helper.sh Resources/uninstall-helper.sh
sh -n Resources/network-helper
