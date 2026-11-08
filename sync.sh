#!/bin/sh
# Copies the shared sources into the app's src folder as shared_*.odin (one Odin package per folder).
# It finds the app from its own location (this repo is the app's libs/shared), so it can be run from any folder;
# build.sh runs it. The copies are ignored by git: edit them in this repo.
set -e
shared="$(cd "$(dirname "$0")" && pwd)"
app="$(cd "$shared/../.." && pwd)"
if [ "$(basename "$(dirname "$shared")")" != libs ] || [ ! -d "$app/src" ]; then
	echo "sync.sh copies into an app: run the copy at libs/shared/sync.sh inside a Pangolin app, not this repo's own." >&2
	exit 1
fi
rm -f "$app"/src/shared_*.odin
for f in "$shared"/src/*.odin; do cp "$f" "$app/src/shared_$(basename "$f")"; done
