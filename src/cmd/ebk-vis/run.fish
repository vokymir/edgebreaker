#!/usr/bin/env fish

set -l RAYLIB_DIR "$HOME/.local/lib/raylib-6.0/usr/lib"

env LD_LIBRARY_PATH="$RAYLIB_DIR" odin run . --debug $argv
