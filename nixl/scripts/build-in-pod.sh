#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE=${WORKSPACE:-/workspace/projects/nixl-ucx}
SRC_ROOT=${SRC_ROOT:-$WORKSPACE/src}
BUILD_ROOT=${BUILD_ROOT:-$WORKSPACE/build}
INSTALL_ROOT=${INSTALL_ROOT:-$WORKSPACE/install}
ARTIFACT_ROOT=${ARTIFACT_ROOT:-$WORKSPACE/artifacts}
JOBS=${JOBS:-$(nproc)}
CUDA_HOME=${CUDA_HOME:-/usr/local/cuda}
UCX_REF=${UCX_REF:-v1.22.0}
NIXL_REF=${NIXL_REF:-v1.4.1}
UCX_REPOSITORY=${UCX_REPOSITORY:-https://github.com/openucx/ucx.git}
NIXL_REPOSITORY=${NIXL_REPOSITORY:-https://github.com/ai-dynamo/nixl.git}
NIXL_ENABLE_PLUGINS=${NIXL_ENABLE_PLUGINS:-UCX,POSIX}
CLEAN_BUILD=${CLEAN_BUILD:-false}
BUILD_MODE=${1:-}

if [[ "$BUILD_MODE" == clean ]]; then
    CLEAN_BUILD=true
elif [[ -n "$BUILD_MODE" && "$BUILD_MODE" != incremental ]]; then
    echo "Usage: build-in-pod [clean|incremental]" >&2
    exit 2
fi

case "$CLEAN_BUILD" in
    true|false) ;;
    *) echo "CLEAN_BUILD must be true or false" >&2; exit 2 ;;
esac

UCX_SRC="$SRC_ROOT/ucx"
NIXL_SRC="$SRC_ROOT/nixl"
UCX_PREFIX="$INSTALL_ROOT/ucx"
NIXL_PREFIX="$INSTALL_ROOT/nixl"
NIXLBENCH_PREFIX="$INSTALL_ROOT/nixlbench"

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

clone_if_missing() {
    local repository=$1 ref=$2 destination=$3
    if [[ ! -d "$destination/.git" ]]; then
        log "Cloning $repository at $ref"
        git clone --branch "$ref" --depth 1 --recurse-submodules "$repository" "$destination"
    else
        log "Using existing source tree $destination (local edits are preserved)"
        git -C "$destination" status --short
    fi
}

prepare_build_dir() {
    local directory=$1
    if [[ "$CLEAN_BUILD" == true ]]; then
        rm -rf "$directory"
    fi
    mkdir -p "$directory"
}

mkdir -p "$SRC_ROOT" "$BUILD_ROOT" "$INSTALL_ROOT" "$ARTIFACT_ROOT"
if [[ "$CLEAN_BUILD" == true ]]; then
    log "Cleaning build and install directories"
    rm -rf "$BUILD_ROOT" "$INSTALL_ROOT"
    mkdir -p "$BUILD_ROOT" "$INSTALL_ROOT"
fi
clone_if_missing "$UCX_REPOSITORY" "$UCX_REF" "$UCX_SRC"
clone_if_missing "$NIXL_REPOSITORY" "$NIXL_REF" "$NIXL_SRC"

log "Building UCX $UCX_REF"
if [[ "$CLEAN_BUILD" == true ]]; then
    rm -rf "$UCX_PREFIX"
    if [[ -f "$UCX_SRC/Makefile" ]]; then
        make -C "$UCX_SRC" distclean >/dev/null 2>&1 || true
    fi
fi
(
    cd "$UCX_SRC"
    if [[ ! -f Makefile ]]; then
        ./autogen.sh
        ./contrib/configure-release-mt \
        --prefix="$UCX_PREFIX" \
        --enable-shared \
        --disable-static \
        --disable-doxygen-doc \
        --enable-optimizations \
        --enable-cma \
        --enable-devel-headers \
        --enable-mt \
        --with-cuda="$CUDA_HOME" \
            --with-verbs \
            --with-dm
    fi
    make -j"$JOBS"
    make install
)

export PKG_CONFIG_PATH="$UCX_PREFIX/lib/pkgconfig:$NIXL_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="$UCX_PREFIX:${CMAKE_PREFIX_PATH:-}"
export LD_LIBRARY_PATH="$UCX_PREFIX/lib:$UCX_PREFIX/lib/ucx:$NIXL_PREFIX/lib/x86_64-linux-gnu:$NIXL_PREFIX/lib/x86_64-linux-gnu/plugins:$NIXLBENCH_PREFIX/lib:${LD_LIBRARY_PATH:-}"

log "Building NIXL $NIXL_REF"
if [[ "$CLEAN_BUILD" == true ]]; then
    rm -rf "$NIXL_PREFIX"
fi
prepare_build_dir "$BUILD_ROOT/nixl"
if [[ -f "$BUILD_ROOT/nixl/build.ninja" ]]; then
    meson setup --reconfigure "$BUILD_ROOT/nixl" "$NIXL_SRC"
else
    meson setup "$BUILD_ROOT/nixl" "$NIXL_SRC" \
    --prefix="$NIXL_PREFIX" \
    --buildtype=release \
    -Ducx_path="$UCX_PREFIX" \
    -Denable_plugins="$NIXL_ENABLE_PLUGINS" \
    -Ddisable_gds_backend=true \
    -Dbuild_docs=false \
    -Dbuild_tests=false \
    -Dbuild_examples=false \
    -Dcudapath_inc="$CUDA_HOME/include" \
        -Dcudapath_lib="$CUDA_HOME/lib64"
fi
meson compile -C "$BUILD_ROOT/nixl" -j "$JOBS"
meson install -C "$BUILD_ROOT/nixl"

log "Building NIXLBench from the NIXL $NIXL_REF source tree"
if [[ "$CLEAN_BUILD" == true ]]; then
    rm -rf "$NIXLBENCH_PREFIX"
fi
prepare_build_dir "$BUILD_ROOT/nixlbench"
if [[ -f "$BUILD_ROOT/nixlbench/build.ninja" ]]; then
    meson setup --reconfigure "$BUILD_ROOT/nixlbench" "$NIXL_SRC/benchmark/nixlbench"
else
    meson setup "$BUILD_ROOT/nixlbench" "$NIXL_SRC/benchmark/nixlbench" \
    --prefix="$NIXLBENCH_PREFIX" \
    --buildtype=release \
    -Dnixl_path="$NIXL_PREFIX" \
    -Dcudapath_inc="$CUDA_HOME/include" \
        -Dcudapath_lib="$CUDA_HOME/lib64"
fi
meson compile -C "$BUILD_ROOT/nixlbench" -j "$JOBS"
meson install -C "$BUILD_ROOT/nixlbench"

log "Staging runtime artifact bundle"
rm -rf "$ARTIFACT_ROOT/stage" "$ARTIFACT_ROOT/nixl-stack.tar.gz" "$ARTIFACT_ROOT/manifest.txt"
mkdir -p "$ARTIFACT_ROOT/stage"
cp -a "$UCX_PREFIX" "$NIXL_PREFIX" "$NIXLBENCH_PREFIX" "$ARTIFACT_ROOT/stage/"
(
    cd "$ARTIFACT_ROOT/stage"
    tar -czf ../nixl-stack.tar.gz ucx nixl nixlbench
)
{
    printf 'UCX_REF=%s\n' "$UCX_REF"
    printf 'NIXL_REF=%s\n' "$NIXL_REF"
    printf 'CUDA_HOME=%s\n' "$CUDA_HOME"
    printf 'NIXL_ENABLE_PLUGINS=%s\n' "$NIXL_ENABLE_PLUGINS"
    printf 'UCX_COMMIT=%s\n' "$(git -C "$UCX_SRC" rev-parse HEAD)"
    printf 'NIXL_COMMIT=%s\n' "$(git -C "$NIXL_SRC" rev-parse HEAD)"
} > "$ARTIFACT_ROOT/manifest.txt"

log "Checking NIXLBench dynamic dependencies"
while IFS= read -r -d '' executable; do
    if ldd "$executable" | grep -q 'not found'; then
        echo "Unresolved dependency in $executable" >&2
        ldd "$executable" >&2
        exit 1
    fi
done < <(find "$NIXLBENCH_PREFIX/bin" -type f -perm -u+x -print0 2>/dev/null || true)

log "Build complete"
printf 'Artifact archive: %s\nManifest: %s\n' "$ARTIFACT_ROOT/nixl-stack.tar.gz" "$ARTIFACT_ROOT/manifest.txt"
