#!/bin/sh
# Prepare the Strata NVFP4 build context so that a rebuild reproduces it byte-for-byte.
#
# What this does, in order:
#   1. copies the pinned fork checkout over the build context
#   2. patches the context's .dockerignore (the fork excludes third_party/llama.cpp,
#      but the engine IS compiled from that directory - the exclusion would break the build)
#   3. vendors llama.cpp (the pinned submodule of this repo) into the context
#   4. recreates the one symlink llama.cpp's build creates but git does not track
#   5. puts the Dockerfile and the entrypoint into the context
#
# Verified: after this, the context is identical to the one the running image was
# built from (diff -r reports nothing).
#
# Usage:  prepare-build-context.sh [BUILD_DIR]

set -e

SRC_DIR="/opt/strata-nvfp4/src-0.2.0"           # the fork's pinned checkout (586dc5e)
BUILD_DIR="${1:-/opt/strata-nvfp4/build-0.2.0}" # the build context
REPO_DIR="/opt/rtx-5090-strata-nvfp4-fresh"      # this repository (Dockerfile, entrypoints)
LLAMA_DIR="$REPO_DIR/third_party/llama.cpp"     # the pinned llama.cpp (3cf03257)

say() { echo "=== $* ==="; }

[ -d "$SRC_DIR" ]   || { echo "ERROR: $SRC_DIR not found" >&2; exit 1; }
[ -d "$LLAMA_DIR" ] || { echo "ERROR: $LLAMA_DIR not found" >&2; exit 1; }

say "1. the fork's tree -> the build context"
mkdir -p "$BUILD_DIR"
rsync -a --exclude '.git/' --exclude '.venv/' "$SRC_DIR/" "$BUILD_DIR/"

say "2. .dockerignore: the llama.cpp exclusion would break the build"
# The fork's .dockerignore carries "third_party/llama.cpp/". The engine is compiled
# from that directory, so the line has to go - otherwise "COPY . ." leaves the sources
# out of the image and the build fails.
if grep -qx 'third_party/llama.cpp/' "$BUILD_DIR/.dockerignore"; then
    grep -vx 'third_party/llama.cpp/' "$BUILD_DIR/.dockerignore" > "$BUILD_DIR/.dockerignore.new"
    mv "$BUILD_DIR/.dockerignore.new" "$BUILD_DIR/.dockerignore"
    echo "    removed the exclusion"
else
    echo "    already absent"
fi

say "3. llama.cpp -> the build context (pinned submodule, anchored excludes)"
# The excludes must be ANCHORED ("/.git", "/models"): an unanchored "models/" would
# also strip llama.cpp's own src/models, tools/mtmd/models and the UI's model stores.
rsync -a --delete --exclude '/.git' --exclude '/models' "$LLAMA_DIR/" "$BUILD_DIR/third_party/llama.cpp/"

say "4. the symlink llama.cpp's build creates (git does not track it)"
ln -sfn ../src/ggml-common.h "$BUILD_DIR/third_party/llama.cpp/ggml/include/ggml-common.h"

say "5. the Dockerfile and the entrypoint into the context"
cp "$REPO_DIR/Dockerfile.zen5-v020" "$BUILD_DIR/Dockerfile.zen5-v020"
cp "$REPO_DIR/entrypoints/strata-start-v020.sh" "$BUILD_DIR/strata-start-v020.sh"

say "the build context is ready: $BUILD_DIR"
echo "  build it with:  cd $BUILD_DIR && docker build -f Dockerfile.zen5-v020 -t strata-nvfp4:sm120-v020 ."
echo "  (stop the service first: the CUDA+LTO compile needs the RAM the container holds)"
