#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
NAMESPACE=${NAMESPACE:-nwadekar-pirate}
BUILD_POD_NODE=${BUILD_POD_NODE:-a100-03}
BUILDER_POD=${BUILDER_POD:-nixl-builder}
BUILDER_POD_NAME="${BUILDER_POD}-${BUILD_POD_NODE}"
RUN_POD_NODE=${RUN_POD_NODE:-a100-03}
RUN_POD_NAME=${RUN_POD_NAME:-nixl-runner-${RUN_POD_NODE}}
TCP_PROFILING=${TCP_PROFILING:-off}
REQUEST_TRACING=${REQUEST_TRACING:-off}
REQUEST_TRACE_BUILD_ID=${REQUEST_TRACE_BUILD_ID:-}
JOBS=${JOBS:-8}
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
  NAMESPACE, BUILD_POD_NODE, BUILDER_POD, RUN_POD_NODE, TARGET_PLATFORM,
  CLEAN_BUILD, KUBECTL_CONTEXT, RUN_POD_NAME, TCP_PROFILING=on|off,
  REQUEST_TRACING=on|off, REQUEST_TRACE_BUILD_ID, and REQUEST_TRACE_SOURCE.
  Pod names are suffixed with their node.
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

case "$REQUEST_TRACING" in
    on|off) ;;
    *) echo 'REQUEST_TRACING must be on or off' >&2; exit 2 ;;
esac
if [[ "$REQUEST_TRACING" == on && -z "$REQUEST_TRACE_BUILD_ID" ]]; then
    REQUEST_TRACE_BUILD_ID=$(date -u +%Y%m%dT%H%M%SZ)
fi
request_trace_build_mode() {
    [[ "$REQUEST_TRACING" == on || -n "$REQUEST_TRACE_BUILD_ID" ]]
}
if request_trace_build_mode; then
    [[ "$TCP_PROFILING" == off ]] || {
        echo 'request-trace builds require TCP_PROFILING=off' >&2
        exit 2
    }
    [[ "$REQUEST_TRACE_BUILD_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
        echo 'REQUEST_TRACE_BUILD_ID contains unsupported characters' >&2
        exit 2
    }
fi

runtime_image_tag() {
    if request_trace_build_mode; then
        printf '%s-request-trace-%s-%s' "$IMAGE_TAG" "$REQUEST_TRACING" "$REQUEST_TRACE_BUILD_ID"
    else
        printf '%s' "$IMAGE_TAG"
    fi
}

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
    local image_tag=${3:-$IMAGE_TAG}
    sed \
        -e "s|\${BUILD_ENV_IMAGE}|$BUILD_ENV_IMAGE|g" \
        -e "s|\${RUNTIME_IMAGE}|$RUNTIME_IMAGE|g" \
        -e "s|\${IMAGE_TAG}|$image_tag|g" \
        -e "s|\${BUILD_POD_NODE}|$BUILD_POD_NODE|g" \
        -e "s|\${BUILDER_POD_NAME}|$BUILDER_POD_NAME|g" \
        -e "s|\${RUN_POD_NODE}|$RUN_POD_NODE|g" \
        -e "s|\${RUN_POD_NAME}|$RUN_POD_NAME|g" \
        -e "s|\${NAMESPACE}|$NAMESPACE|g" \
        "$template" > "$rendered"
}

apply_build_pod() {
    (
        local rendered
        rendered=$(mktemp)
        trap 'rm -f "$rendered"' EXIT
        render_manifest "$ROOT/k8s/build-pod.yaml" "$rendered"
        "${KUBE[@]}" apply -f "$rendered"
    )
}

build_in_pod() {
    local mode=${1:-incremental}
    if request_trace_build_mode; then
        local tools_source=${REQUEST_TRACE_SOURCE:-"$ROOT/../../nixl-ucx/profiling/dram-dram-ucx/tools/request_trace"}
        local remote_tools="/workspace/projects/nixl-ucx/request-trace-tools-$REQUEST_TRACE_BUILD_ID"
        tools_source=$(cd "$tools_source" && pwd)
        [[ -f "$tools_source/build_stack.sh" ]] || {
            echo "request-trace build helper missing under $tools_source" >&2
            return 2
        }
        [[ "$mode" == incremental ]] || {
            echo 'REQUEST_TRACING builds are already isolated; do not use build-in-pod clean' >&2
            return 2
        }
        "${KUBE[@]}" -n "$NAMESPACE" exec "$BUILDER_POD_NAME" -- \
            test '!' -e "$remote_tools"
        "${KUBE[@]}" -n "$NAMESPACE" cp "$tools_source" \
            "$BUILDER_POD_NAME:$remote_tools"
        "${KUBE[@]}" -n "$NAMESPACE" exec "$BUILDER_POD_NAME" -- \
            env "REQUEST_TRACING=$REQUEST_TRACING" TCP_PROFILING=off \
                "REQUEST_TRACE_BUILD_ID=$REQUEST_TRACE_BUILD_ID" \
                "NIXL_ENABLE_PLUGINS=${NIXL_ENABLE_PLUGINS:-UCX,POSIX}" \
                "JOBS=$JOBS" "/bin/bash" "$remote_tools/build_stack.sh"
        return
    fi
    case "$TCP_PROFILING" in
        on|off) ;;
        *) echo 'TCP_PROFILING must be on or off' >&2; return 2 ;;
    esac
    if [[ "$TCP_PROFILING" == on ]]; then
        "${KUBE[@]}" -n "$NAMESPACE" exec "$BUILDER_POD_NAME" -- \
            env "TCP_PROFILING=$TCP_PROFILING" \
            /bin/bash /workspace/projects/nixl-ucx/src/nixl/contrib/tcp-profile-build.sh "$mode"
    else
        "${KUBE[@]}" -n "$NAMESPACE" cp "$ROOT/scripts/build-in-pod.sh" \
            "$BUILDER_POD_NAME:/workspace/projects/nixl-ucx/build-in-pod.sh"
        "${KUBE[@]}" -n "$NAMESPACE" exec "$BUILDER_POD_NAME" -- \
            env "JOBS=$JOBS" "CLEAN_BUILD=$CLEAN_BUILD" \
                "NIXL_ENABLE_PLUGINS=${NIXL_ENABLE_PLUGINS:-UCX,POSIX}" \
                /bin/bash /workspace/projects/nixl-ucx/build-in-pod.sh "$mode"
    fi
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
    if request_trace_build_mode; then
        local stage remote_archive
        archive="$ROOT/artifacts/nixl-stack-request-trace-$REQUEST_TRACE_BUILD_ID.tar.gz"
        stage="$ROOT/artifacts/stage-request-trace-$REQUEST_TRACE_BUILD_ID"
        remote_archive="/workspace/projects/nixl-ucx/artifacts/request-trace/$REQUEST_TRACE_BUILD_ID/nixl-stack.tar.gz"
        [[ ! -e "$archive" && ! -e "$stage" ]] || {
            echo "refusing to overwrite request-trace artifacts for $REQUEST_TRACE_BUILD_ID" >&2
            return 2
        }
        (
            tmp=$(mktemp -d)
            trap 'rm -rf "$tmp"' EXIT
            mkdir -p "$ROOT/artifacts"
            "${KUBE[@]}" -n "$NAMESPACE" cp "$BUILDER_POD_NAME:$remote_archive" "$tmp/nixl-stack.tar.gz"
            tar -tzf "$tmp/nixl-stack.tar.gz" | grep -qx 'nixlbench/bin/nixlbench' || {
                echo 'isolated artifact archive is missing nixlbench' >&2
                exit 1
            }
            if [[ "$REQUEST_TRACING" == on ]]; then
                tar -tzf "$tmp/nixl-stack.tar.gz" | grep -qx 'request-trace/lib/librequest_trace.so' || {
                    echo 'request-trace artifact archive is missing librequest_trace.so' >&2
                    exit 1
                }
            fi
            "${KUBE[@]}" -n "$NAMESPACE" cp \
                "$BUILDER_POD_NAME:/workspace/projects/nixl-ucx/artifacts/request-trace/$REQUEST_TRACE_BUILD_ID/manifest.txt" \
                "$tmp/manifest.txt"
            mkdir "$stage"
            tar -xzf "$tmp/nixl-stack.tar.gz" -C "$stage"
            mv "$tmp/nixl-stack.tar.gz" "$archive"
            mv "$tmp/manifest.txt" "$ROOT/artifacts/nixl-stack-request-trace-$REQUEST_TRACE_BUILD_ID.manifest.txt"
        )
        return
    fi
    (
        archive="$ROOT/artifacts/nixl-stack.tar.gz"
        tmp=$(mktemp -d)
        trap 'rm -rf "$tmp"' EXIT
        mkdir -p "$ROOT/artifacts/stage"
        "${KUBE[@]}" -n "$NAMESPACE" cp "$BUILDER_POD_NAME:/workspace/projects/nixl-ucx/artifacts/nixl-stack.tar.gz" "$tmp/nixl-stack.tar.gz"
        rm -rf "$ROOT/artifacts/stage"
        mkdir -p "$ROOT/artifacts/stage"
        tar -xzf "$tmp/nixl-stack.tar.gz" -C "$ROOT/artifacts/stage"
        "${KUBE[@]}" -n "$NAMESPACE" cp "$BUILDER_POD_NAME:/workspace/projects/nixl-ucx/artifacts/manifest.txt" "$ROOT/artifacts/manifest.txt"
        mv "$tmp/nixl-stack.tar.gz" "$archive"
    )
}

build_runtime() {
    if request_trace_build_mode; then
        (
            stage="$ROOT/artifacts/stage-request-trace-$REQUEST_TRACE_BUILD_ID"
            [[ -f "$stage/nixlbench/bin/nixlbench" ]] || {
                echo "Missing isolated stack stage $stage; run copy-artifacts first" >&2
                exit 1
            }
            if [[ "$REQUEST_TRACING" == on && ! -f "$stage/request-trace/lib/librequest_trace.so" ]]; then
                echo "Missing recorder library in $stage" >&2
                exit 1
            fi
            context=$(mktemp -d)
            trap 'rm -rf "$context"' EXIT
            mkdir -p "$context/artifacts"
            cp "$ROOT/Dockerfile.runtime" "$context/Dockerfile.runtime"
            cp -a "$stage/." "$context/artifacts/stage/"
            tag=$(runtime_image_tag)
            docker build \
                --platform "$TARGET_PLATFORM" \
                --file "$context/Dockerfile.runtime" \
                --tag "$RUNTIME_IMAGE:$tag" \
                --build-arg "CUDA_VERSION=$CUDA_VERSION" \
                --build-arg "UBUNTU_VERSION=$UBUNTU_VERSION" \
                "$context"
        )
        return
    fi
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

push_runtime() {
    local tag output digest reference image_file
    tag=$(runtime_image_tag)
    if request_trace_build_mode; then
        image_file="$ROOT/artifacts/nixl-stack-request-trace-$REQUEST_TRACE_BUILD_ID-image.txt"
        [[ ! -e "$image_file" ]] || {
            echo "refusing to overwrite runtime image digest record: $image_file" >&2
            return 2
        }
    fi
    output=$(docker push "$RUNTIME_IMAGE:$tag" 2>&1) || {
        printf '%s\n' "$output" >&2
        return 1
    }
    printf '%s\n' "$output"
    if request_trace_build_mode; then
        digest=$(grep -oE 'sha256:[0-9a-f]{64}' <<<"$output" | tail -n 1 || true)
        [[ -n "$digest" ]] || {
            echo 'docker push succeeded but returned no sha256 image digest' >&2
            return 1
        }
        reference="$RUNTIME_IMAGE@$digest"
        printf '%s\n' "$reference" > "$image_file"
        printf 'immutable_runtime_image=%s\n' "$reference"
    fi
}

apply_run_pod() {
    (
        local rendered
        rendered=$(mktemp)
        trap 'rm -f "$rendered"' EXIT
        render_manifest "$ROOT/k8s/run-pod.yaml" "$rendered" "$(runtime_image_tag)"
        "${KUBE[@]}" apply -f "$rendered"
    )
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
        "${KUBE[@]}" -n "$NAMESPACE" wait --for=condition=Ready "pod/$BUILDER_POD_NAME" --timeout=10m
        build_in_pod "${2:-incremental}"
        copy_artifacts
        build_runtime
        push_runtime
        ;;
    *) usage >&2; exit 2 ;;
esac
