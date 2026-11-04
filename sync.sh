#!/bin/sh
# Copies the shared sources into the app's src folder as shared_*.odin (one Odin package per folder).
# Run from the app's root; build.sh does. The copies are ignored by git: edit them in this repo.
rm -f src/shared_*.odin
for f in libs/shared/src/*.odin; do cp "$f" "src/shared_$(basename "$f")"; done
