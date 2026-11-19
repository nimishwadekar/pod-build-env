#!/usr/bin/env bash
set -Eeuo pipefail

WORKSPACE=${WORKSPACE:-/workspace/projects/nixl-ucx}
SRC_ROOT=${SRC_ROOT:-$WORKSPACE/src}
BUILD_ROOT=${BUILD_ROOT:-$WORKSPACE/build}
INSTALL_ROOT=${INSTALL_ROOT:-$WORKSPACE/install}
ARTIFACT_ROOT=${ARTIFACT_ROOT:-$WORKSPACE/artifacts}
JOBS=${JOBS:-8}
CUDA_HOME=${CUDA_HOME:-/usr/local/cuda}
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
VLLM_SRC="$SRC_ROOT/vllm"
UCX_PREFIX="$INSTALL_ROOT/ucx"
NIXL_PREFIX="$INSTALL_ROOT/nixl"
NIXLBENCH_PREFIX="$INSTALL_ROOT/nixlbench"
VLLM_PREFIX="$INSTALL_ROOT/vllm"

log() { printf '\n[%s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }

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
log "Preparing Python build dependencies"
python3 -m venv "$BUILD_ROOT/python-env"
source "$BUILD_ROOT/python-env/bin/activate"
python3 -m pip install --upgrade pip
python3 -m pip install meson ninja pybind11 patchelf PyYAML uv
CUDA_INDEX="cu$(nvcc --version | sed -n 's/.*release \([0-9]*\)\.\([0-9]*\),.*/\1\2/p')"
python3 -m pip install \
    --extra-index-url "https://download.pytorch.org/whl/$CUDA_INDEX" \
    -r "$VLLM_SRC/requirements/cuda.txt" \
    -r "$VLLM_SRC/requirements/build/cuda.txt" \
    -r "$VLLM_SRC/requirements/build/rust.txt"

log "Building UCX from $UCX_SRC"
if [[ "$CLEAN_BUILD" == true ]]; then
    rm -rf "$UCX_PREFIX"
    if [[ -f "$UCX_SRC/Makefile" ]]; then
        make -C "$UCX_SRC" distclean >/dev/null 2>&1 || true
    fi
fi
(
    cd "$UCX_SRC"
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
    make -j"$JOBS"
    make install
)

export PKG_CONFIG_PATH="$UCX_PREFIX/lib/pkgconfig:$NIXL_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="$UCX_PREFIX:${CMAKE_PREFIX_PATH:-}"
export LD_LIBRARY_PATH="$UCX_PREFIX/lib:$UCX_PREFIX/lib/ucx:$NIXL_PREFIX/lib/x86_64-linux-gnu:$NIXL_PREFIX/lib/x86_64-linux-gnu/plugins:$NIXLBENCH_PREFIX/lib:${LD_LIBRARY_PATH:-}"

log "Building NIXL from $NIXL_SRC"
if [[ "$CLEAN_BUILD" == true ]]; then
    rm -rf "$NIXL_PREFIX"
fi
prepare_build_dir "$BUILD_ROOT/nixl"
if [[ -f "$BUILD_ROOT/nixl/build.ninja" ]]; then
    meson setup --reconfigure "$BUILD_ROOT/nixl" "$NIXL_SRC" \
        -Dpython.platlibdir=lib/python3/site-packages \
        -Dpython.purelibdir=lib/python3/site-packages
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
    -Dpython.platlibdir=lib/python3/site-packages \
    -Dpython.purelibdir=lib/python3/site-packages \
    -Dcudapath_inc="$CUDA_HOME/include" \
        -Dcudapath_lib="$CUDA_HOME/lib64"
fi
meson compile -C "$BUILD_ROOT/nixl" -j "$JOBS"
meson install -C "$BUILD_ROOT/nixl"
# Include the Python dispatcher alongside the native backend installed by Meson.
cp -a "$BUILD_ROOT/nixl/src/bindings/python/nixl-meta/nixl" \
    "$BUILD_ROOT/nixl/src/bindings/python/nixl-meta/nixl_meta_utils.py" \
    "$NIXL_PREFIX/lib/python3/site-packages/"

log "Building NIXLBench from $NIXL_SRC/benchmark/nixlbench"
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

log "Building vLLM from $VLLM_SRC"
mkdir -p "$VLLM_PREFIX"
rm -f "$VLLM_PREFIX"/vllm-*.whl
(
    cd "$VLLM_SRC"
    export MAX_JOBS="$JOBS"
    export CARGO_BUILD_JOBS="$JOBS"
    export NVCC_THREADS=${NVCC_THREADS:-2}
    export TORCH_CUDA_ARCH_LIST=${TORCH_CUDA_ARCH_LIST:-"8.0 9.0 10.0"}
    export DEEPGEMM_PYTHON_INTERPRETERS=${DEEPGEMM_PYTHON_INTERPRETERS:-$(command -v python3)}
    export VLLM_USE_PRECOMPILED=0
    bash tools/build_rust.sh
    python3 -m build --wheel --no-isolation --outdir "$VLLM_PREFIX"
)

log "Staging runtime artifact bundle"
rm -rf "$ARTIFACT_ROOT/stage" "$ARTIFACT_ROOT/nixl-stack.tar.gz" "$ARTIFACT_ROOT/manifest.txt"
mkdir -p "$ARTIFACT_ROOT/stage"
cp -a "$UCX_PREFIX" "$NIXL_PREFIX" "$NIXLBENCH_PREFIX" "$VLLM_PREFIX" "$ARTIFACT_ROOT/stage/"
(
    cd "$ARTIFACT_ROOT/stage"
    tar -czf ../nixl-stack.tar.gz ucx nixl nixlbench vllm
)
{
    printf 'CUDA_HOME=%s\n' "$CUDA_HOME"
    printf 'NIXL_ENABLE_PLUGINS=%s\n' "$NIXL_ENABLE_PLUGINS"
    printf 'UCX_COMMIT=%s\n' "$(git -C "$UCX_SRC" rev-parse HEAD)"
    printf 'NIXL_COMMIT=%s\n' "$(git -C "$NIXL_SRC" rev-parse HEAD)"
    printf 'VLLM_COMMIT=%s\n' "$(git -C "$VLLM_SRC" rev-parse HEAD)"
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
