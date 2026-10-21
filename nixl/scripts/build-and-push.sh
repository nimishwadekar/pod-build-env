#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-nwadekar-pirate}
BUILDER_POD=${BUILDER_POD:-nixl-builder}
BUILD_ENV_IMAGE=${BUILD_ENV_IMAGE:-quay.io/nwadekar/pod-build-env}
RUNTIME_IMAGE=${RUNTIME_IMAGE:-quay.io/nwadekar/nixl-benchmark}
IMAGE_TAG=${IMAGE_TAG:-custom-nixl1.4.1-ucx1.22.0}
CUDA_VERSION=${CUDA_VERSION:-13.0.3}
UBUNTU_VERSION=${UBUNTU_VERSION:-24.04}
TARGET_PLATFORM=${TARGET_PLATFORM:-linux/amd64}
CLEAN_BUILD=${CLEAN_BUILD:-false}

usage() {
    cat <<'EOF'
Usage: scripts/build-and-push.sh <command>

Commands:
  build-env          Build the Kubernetes build-environment image
  push-build-env     Push the build-environment image to Quay
  apply-build-pod    Apply the build pod manifest
  build-in-pod       Run an incremental source build inside the pod
  build-in-pod clean  Run a clean source build inside the pod
  rebuild-code       Rebuild code, copy artifacts, build, and push runtime
  rebuild-code clean  Perform the same flow with a clean source build
  copy-artifacts     Copy the staged artifact archive from the pod
  build-runtime      Build the runtime image from copied artifacts
  push-runtime       Push the runtime image to Quay
  apply-run-pod      Apply the runtime pod manifest
  all                Run the complete build/push/copy/build/push flow

Environment overrides:
  BUILD_ENV_IMAGE, RUNTIME_IMAGE, IMAGE_TAG, CUDA_VERSION, UBUNTU_VERSION,
  NAMESPACE, BUILDER_POD, TARGET_PLATFORM, CLEAN_BUILD, and KUBECTL_CONTEXT.
EOF
}

command=${1:-}
if [[ -z "$command" ]]; then
    usage >&2
    exit 2
fi

if [[ -n "${KUBECTL_CONTEXT:-}" ]]; then
    KUBE=(kubectl --context "$KUBECTL_CONTEXT")
else
    KUBE=(kubectl)
fi

build_env() {
    docker build \
        --platform "$TARGET_PLATFORM" \
        --file "$ROOT/Dockerfile.build" \
        --tag "$BUILD_ENV_IMAGE:$IMAGE_TAG" \
        --build-arg "CUDA_VERSION=$CUDA_VERSION" \
        --build-arg "UBUNTU_VERSION=$UBUNTU_VERSION" \
        "$ROOT"
}

push_build_env() { docker push "$BUILD_ENV_IMAGE:$IMAGE_TAG"; }

render_manifest() {
    local template=$1
    local rendered=$2
    sed \
        -e "s|\${BUILD_ENV_IMAGE}|$BUILD_ENV_IMAGE|g" \
        -e "s|\${RUNTIME_IMAGE}|$RUNTIME_IMAGE|g" \
        -e "s|\${IMAGE_TAG}|$IMAGE_TAG|g" \
        "$template" > "$rendered"
}

apply_build_pod() {
    local rendered
    rendered=$(mktemp)
    trap 'rm -f "$rendered"' RETURN
    render_manifest "$ROOT/k8s/build-pod.yaml" "$rendered"
    "${KUBE[@]}" apply -f "$rendered"
    trap - RETURN
    rm -f "$rendered"
}

build_in_pod() {
    local mode=${1:-incremental}
    "${KUBE[@]}" -n "$NAMESPACE" exec "$BUILDER_POD" -- \
        /usr/local/bin/build-in-pod "$mode"
}

rebuild_code() {
    local mode=${1:-incremental}
    build_in_pod "$mode"
    copy_artifacts
    build_runtime
    push_runtime
}

copy_artifacts() {
    local archive tmp
    archive="$ROOT/artifacts/nixl-stack.tar.gz"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    mkdir -p "$ROOT/artifacts/stage"
    "${KUBE[@]}" -n "$NAMESPACE" cp "$BUILDER_POD:/workspace/projects/nixl-ucx/artifacts/nixl-stack.tar.gz" "$tmp/nixl-stack.tar.gz"
    rm -rf "$ROOT/artifacts/stage"
    mkdir -p "$ROOT/artifacts/stage"
    tar -xzf "$tmp/nixl-stack.tar.gz" -C "$ROOT/artifacts/stage"
    "${KUBE[@]}" -n "$NAMESPACE" cp "$BUILDER_POD:/workspace/projects/nixl-ucx/artifacts/manifest.txt" "$ROOT/artifacts/manifest.txt"
    mv "$tmp/nixl-stack.tar.gz" "$archive"
    trap - RETURN
    rm -rf "$tmp"
}

build_runtime() {
    [[ -d "$ROOT/artifacts/stage/nixl" ]] || {
        echo "Missing artifacts/stage; run copy-artifacts first" >&2
        exit 1
    }
    docker build \
        --platform "$TARGET_PLATFORM" \
        --file "$ROOT/Dockerfile.runtime" \
        --tag "$RUNTIME_IMAGE:$IMAGE_TAG" \
        --build-arg "CUDA_VERSION=$CUDA_VERSION" \
        --build-arg "UBUNTU_VERSION=$UBUNTU_VERSION" \
        "$ROOT"
}

push_runtime() { docker push "$RUNTIME_IMAGE:$IMAGE_TAG"; }

apply_run_pod() {
    local rendered
    rendered=$(mktemp)
    trap 'rm -f "$rendered"' RETURN
    render_manifest "$ROOT/k8s/run-pod.yaml" "$rendered"
    "${KUBE[@]}" apply -f "$rendered"
    trap - RETURN
    rm -f "$rendered"
}

case "$command" in
    build-env) build_env ;;
    push-build-env) push_build_env ;;
    apply-build-pod) apply_build_pod ;;
    build-in-pod) build_in_pod "${2:-incremental}" ;;
    rebuild-code) rebuild_code "${2:-incremental}" ;;
    copy-artifacts) copy_artifacts ;;
    build-runtime) build_runtime ;;
    push-runtime) push_runtime ;;
    apply-run-pod) apply_run_pod ;;
    all)
        build_env
        push_build_env
        apply_build_pod
        "${KUBE[@]}" -n "$NAMESPACE" wait --for=condition=Ready "pod/$BUILDER_POD" --timeout=10m
        build_in_pod "${2:-incremental}"
        copy_artifacts
        build_runtime
        push_runtime
        ;;
    *) usage >&2; exit 2 ;;
esac
