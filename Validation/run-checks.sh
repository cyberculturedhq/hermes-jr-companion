#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
validation_tmp=$(mktemp -d /tmp/hermes-validation.XXXXXX)
fixture_pid=
cleanup() {
    if [ -n "$fixture_pid" ]; then kill "$fixture_pid" 2>/dev/null || true; fi
    rm -rf "$validation_tmp"
}
trap cleanup EXIT
hermes_python=${HERMES_PYTHON:-"$HOME/.hermes/hermes-agent/venv/bin/python"}
"$hermes_python" Validation/fixture_server.py >"$validation_tmp/fixture.log" 2>&1 &
fixture_pid=$!
xcrun swiftc -parse-as-library -target arm64-apple-macosx14.0 Hermes/Models/Models.swift Hermes/Models/CompanionModels.swift \
    Hermes/Services/CompanionCrypto.swift Hermes/Services/CompanionTransport.swift Hermes/Services/HermesClient.swift \
    Validation/ProtocolSmoke.swift -module-cache-path "$validation_tmp/cache" -o "$validation_tmp/protocol-smoke"
kill -0 "$fixture_pid"
"$validation_tmp/protocol-smoke"
