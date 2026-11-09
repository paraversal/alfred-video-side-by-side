#!/bin/bash
# Build SideBySide.alfredworkflow from the files in this folder.

set -euo pipefail

cd "$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" && pwd)"

for file in info.plist sbs.sh sbs.lua icon.png README.md; do
    if [ ! -f "$file" ]; then
        printf 'Missing %s\n' "$file" >&2
        exit 1
    fi
done

chmod +x sbs.sh
/bin/bash -n sbs.sh
/usr/bin/plutil -lint info.plist >/dev/null

TARGET="SideBySide.alfredworkflow"
/bin/rm -f "$TARGET"
/usr/bin/zip -X -r "$TARGET" \
    info.plist sbs.sh sbs.lua icon.png README.md

printf '\nBuilt %s\n' "$PWD/$TARGET"
