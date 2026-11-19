# NIXL / UCX / vLLM build workspace

This directory builds the existing UCX, NIXL, NIXLBench, and vLLM source trees on the PVC-backed Kubernetes pod, then packages them in a runtime image on the host. Choose the branches/tags yourself in the pod; the build does not clone, select, or verify source refs.

## CUDA versions

Both Dockerfiles accept the following build arguments:

```text
CUDA_VERSION=13.0.3
UBUNTU_VERSION=24.04
```

For example, to use CUDA 12.8.1 on Ubuntu 22.04:

```bash
CUDA_VERSION=12.8.1 UBUNTU_VERSION=22.04 ./scripts/build-and-push.sh build-env
```

The selected CUDA tag must exist in the NVIDIA CUDA registry and must match the host's NVIDIA driver compatibility. The build script defaults to the x86-64 Docker platform `linux/amd64`, suitable for the A100 node.

## Prerequisites

- Docker with permission to push to `quay.io/nwadekar`.
- `kubectl` configured for the target cluster.
- The `build-workspace` PVC in namespace `nwadekar-pirate`.
- The PVC must not be mounted by another pod while `nixl-builder-a100-03` is running because it is `ReadWriteOnce`.
- The cluster must provide the NVIDIA device plugin for the runtime pod's GPU request. RDMA devices should be provided by the cluster's RDMA/device plugin.

## Workflow

From this directory:

```bash
# Log in once on the host.
docker login quay.io

# Build and push the build environment.
./scripts/build-and-push.sh build-env
./scripts/build-and-push.sh push-build-env

# Start the builder (or use `all` for the complete flow).
./scripts/build-and-push.sh apply-build-pod
kubectl -n nwadekar-pirate wait --for=condition=Ready pod/nixl-builder-a100-03 --timeout=10m

# Run this from the host after editing source on the PVC through VS Code.
./scripts/build-and-push.sh build-in-pod

# Copy the tarball and manifest to this checkout, then build/push the runtime image.
./scripts/build-and-push.sh copy-artifacts
./scripts/build-and-push.sh build-runtime
./scripts/build-and-push.sh push-runtime

# Start the runtime pod.
./scripts/build-and-push.sh apply-run-pod
```

The one-command flow is:

```bash
./scripts/build-and-push.sh all
```

Override registry names, tags, CUDA version, or namespace without editing files:

```bash
CUDA_VERSION=12.8.1 \
TARGET_PLATFORM=linux/amd64 \
IMAGE_TAG=my-test \
BUILD_ENV_IMAGE=quay.io/nwadekar/nixl-build-env \
RUNTIME_IMAGE=quay.io/nwadekar/nixl-ucx-bench \
./scripts/build-and-push.sh all
```

Pod names include their target node as a suffix. The builder defaults to `nixl-builder-a100-03`; the runtime pod defaults to `nixl-runner-a100-03`. Set `BUILD_POD_NODE` or `RUN_POD_NODE` to change the respective target node and name. For example:

```bash
RUN_POD_NODE=a100-04 ./scripts/build-and-push.sh apply-run-pod
```

## Source and artifact layout on the PVC

The build script uses this project directory on the shared PVC:

```text
/workspace/projects/nixl-ucx/src/{ucx,nixl}
/workspace/projects/nixl-ucx/build/{ucx,nixl,nixlbench}
/workspace/projects/nixl-ucx/install/{ucx,nixl,nixlbench}
/workspace/projects/nixl-ucx/artifacts/nixl-stack.tar.gz
```

The vLLM checkout lives at `/workspace/projects/nixl-ucx/src/vllm`. Its wheel is built into `install/vllm/` and included in the artifact archive. Python build dependencies use `build/python-env/`; their versions come from the vLLM checkout's requirements, not from this workflow. Rust dependencies are built through vLLM's own build helper.

Existing source trees and local edits are preserved. The build installs NIXL against the private UCX prefix and includes NIXL's native Python bindings and dispatcher. The runtime installs the source-built vLLM wheel and its Python dependencies, and uses the staged NIXL/UCX stack rather than PyPI's NIXL/UCX bundle. The CUDA development toolkit remains in the image for vLLM's runtime JIT compilation.

The default `build-in-pod` / `rebuild-code` / `all` flow includes vLLM. Explicit TCP-profiling and request-tracing modes retain their existing build paths. Use a clean build when changing native library versions to avoid reusing older build outputs.

### TCP diagnostic profiling (forked source trees)

The forked NIXL tree provides `contrib/tcp-profile-build.sh`. Select the whole
stack's build mode with one variable; no builder-image rebuild is needed:

```bash
TCP_PROFILING=on ./scripts/build-and-push.sh rebuild-code
TCP_PROFILING=off ./scripts/build-and-push.sh rebuild-code
```

OFF (the default) compiles out the added instrumentation. ON records bounded
per-thread binary traces and adds profiling overhead. The helper currently
supports incremental builds only and rejects `clean` before modifying outputs.
Use separate image tags to distinguish ON and OFF runtime images. An ON
NIXLBench writes its trace on normal exit to `/tmp/nixl-tcp-profile.bin` inside
the pod; `NIXL_TCP_PROFILE_FILE` selects a different output path.

### Host-local request tracing

`REQUEST_TRACING=on` builds a separate recorder and instrumented UCX/NIXL/
NIXLBench stack. It requires the matching request-trace source changes to be
present in the PVC checkouts under `/workspace/projects/nixl-ucx/src/{ucx,nixl}`;
the build helper checks for them and stops rather than producing a partial
stack. The helper is copied from the adjacent
`nixl-ucx/profiling/dram-dram-ucx/tools/request_trace` checkout before building. Set
`REQUEST_TRACE_SOURCE` if that checkout lives elsewhere.

Use a new build ID each time. Build and install directories, staged artifacts,
and the runtime image tag are unique to that ID, so existing profiler builds
and images are left alone. The old TCP profiler must be off:

```bash
export REQUEST_TRACING=on
export TCP_PROFILING=off
export REQUEST_TRACE_BUILD_ID=rt-20261108-01

./scripts/build-and-push.sh rebuild-code
```

This builds, packages, and pushes a uniquely tagged runtime image. It does
**not** apply runner pods or start NIXLBench. For separate build/package
commands, keep those environment values set to the same ID. The runtime bundle
includes `librequest_trace.so` and its loader path. Captures remain subject to
the fixed 512-MiB workload, separate source/destination files, and the
correctness and overhead gates in `nixl-ucx/profiling/dram-dram-ucx/PROFILING_PLAN.md`.
Do not use the legacy TCP-profiling smoke path for request traces.
After the push, the resolved immutable image reference is saved as
`artifacts/nixl-stack-request-trace-<ID>-image.txt`; use that reference for the
two-host capture driver rather than the mutable tag.

To build an isolated tracing-OFF control from the same instrumented source
trees, keep a new build ID set and change only the mode:

```bash
export REQUEST_TRACING=off
export TCP_PROFILING=off
export REQUEST_TRACE_BUILD_ID=rt-20261108-off-01
./scripts/build-and-push.sh rebuild-code
```

`REQUEST_TRACING=off` without a build ID continues to use the existing default
build workflow.

Override `NAMESPACE` when applying pods on another cluster. `RUN_POD_NAME`
optionally overrides the node-suffixed name, allowing isolated profiling pods.

Use a clean build only when needed:

```bash
./scripts/build-and-push.sh build-in-pod clean
```

The default is incremental. You can also run the build directly inside the pod:

```bash
/usr/local/bin/build-in-pod clean
```

To rebuild the code and publish a new runtime image in one command:

```bash
./scripts/build-and-push.sh rebuild-code
```

For a clean code rebuild:

```bash
./scripts/build-and-push.sh rebuild-code clean
```

`rebuild-code` runs the source build, copies the artifact bundle, builds the runtime image, and pushes it to Quay. It does not recreate an already-running runtime pod.

The default NIXL plugin set is `UCX,POSIX`. Override it when additional dependencies are installed:

```bash
kubectl -n nwadekar-pirate exec nixl-builder-a100-03 -- \
  env NIXL_ENABLE_PLUGINS=UCX,POSIX /usr/local/bin/build-in-pod
```

## Running NIXLBench

After the runtime pod is ready, inspect the binary and run an ASIO benchmark, for example:

```bash
kubectl -n nwadekar-pirate exec -it nixl-runner-a100-03 -- nixlbench --help
kubectl -n nwadekar-pirate exec -it nixl-runner-a100-03 -- \
  nixlbench --backend UCX
```

The runtime image contains the staged build outputs, vLLM's Python dependencies, and CUDA JIT tools. Source trees remain on the builder PVC. The runtime pod uses normal Kubernetes networking and IPC isolation; it does not use host networking or host IPC. Launch serving explicitly with `vllm serve ...`; the default image command remains `sleep infinity`.
