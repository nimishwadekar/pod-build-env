# NIXL / UCX build workspace

This directory implements a two-image workflow for building NIXL `v1.4.1`, UCX `v1.22.0`, and NIXLBench from source on the PVC-backed Kubernetes pod, then producing a small runtime image on the host.

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
- The PVC must not be mounted by another pod while `nixl-builder` is running because it is `ReadWriteOnce`.
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
kubectl -n nwadekar-pirate wait --for=condition=Ready pod/nixl-builder --timeout=10m

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

## Source and artifact layout on the PVC

The build script uses this project directory on the shared PVC:

```text
/workspace/projects/nixl-ucx/src/{ucx,nixl}
/workspace/projects/nixl-ucx/build/{ucx,nixl,nixlbench}
/workspace/projects/nixl-ucx/install/{ucx,nixl,nixlbench}
/workspace/projects/nixl-ucx/artifacts/nixl-stack.tar.gz
```

Existing source trees are never reset, so local VS Code edits are preserved. The script clones missing trees at the pinned refs and builds the NIXL `benchmark/nixlbench` tree after installing NIXL against the private UCX prefix. Builds are incremental by default: existing UCX/Meson build directories and install prefixes are preserved.

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
kubectl -n nwadekar-pirate exec nixl-builder -- \
  env NIXL_ENABLE_PLUGINS=UCX,POSIX /usr/local/bin/build-in-pod
```

## Running NIXLBench

After the runtime pod is ready, inspect the binary and run an ASIO benchmark, for example:

```bash
kubectl -n nwadekar-pirate exec -it nixl-runner -- nixlbench --help
kubectl -n nwadekar-pirate exec -it nixl-runner -- \
  nixlbench --backend UCX
```

The runtime image contains only the staged build outputs and runtime dependencies. Build tools and source trees remain in the builder image/PVC. The runtime pod uses normal Kubernetes networking and IPC isolation; it does not use host networking or host IPC.
