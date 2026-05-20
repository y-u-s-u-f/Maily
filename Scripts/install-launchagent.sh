#!/usr/bin/env bash
set -euo pipefail

# install-launchagent.sh <path-to-maily-binary>
# Installs dev.yusuf.maily.helper into ~/Library/LaunchAgents.
# Idempotent: unloads any existing copy before loading the new one.

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <path-to-maily-binary>" >&2
    exit 2
fi

EXEC_PATH="$1"

if [[ ! -x "$EXEC_PATH" ]]; then
    echo "error: $EXEC_PATH is not an executable file" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/../Resources/launchd/dev.yusuf.maily.helper.plist"
TARGET_DIR="$HOME/Library/LaunchAgents"
TARGET="$TARGET_DIR/dev.yusuf.maily.helper.plist"

if [[ ! -f "$TEMPLATE" ]]; then
    echo "error: missing template at $TEMPLATE" >&2
    exit 1
fi

mkdir -p "$TARGET_DIR"

# Render template (substitute ${EXEC_PATH}).
sed "s|\${EXEC_PATH}|${EXEC_PATH}|g" "$TEMPLATE" > "$TARGET"

# Idempotent: unload an existing copy if present, then load.
launchctl unload "$TARGET" 2>/dev/null || true
launchctl load "$TARGET"

echo "installed: $TARGET"
