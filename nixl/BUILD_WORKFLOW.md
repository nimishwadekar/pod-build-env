# NIXL / UCX x86-64 Build Workflow

This workflow builds UCX `v1.22.0`, NIXL `v1.4.1`, and NIXLBench from source on a Kubernetes pod, then builds and pushes a runtime image from the host.

The workflow uses x86-64 Linux images by default:

- Platform: `linux/amd64`
- Ubuntu: `24.04`
- CUDA: `13.0.3`
- Build image: `quay.io/nwadekar/nixl-build-env`
- Runtime image: `quay.io/nwadekar/nixl-ucx-bench`

No etcd is used. NIXLBench is built and run with the ASIO configuration.

## 1. Prerequisites

On the host, install and configure:

- Docker with permission to push to Quay
- `kubectl` configured for the target cluster
- Existing `build-workspace` PVC in namespace `nwadekar-pirate`
- Project directory `/workspace/projects/nixl-ucx` on the shared PVC
- NVIDIA device plugin on the Kubernetes cluster
- RDMA device support if RDMA UCX transports are required

Because the PVC uses `ReadWriteOnce`, avoid attaching it to conflicting pods at the same time. The build pod intentionally does not set a fixed UID, GID, or `fsGroup`; OpenShift assigns the namespace-approved restricted security context. All NIXL/UCX files are kept under `/workspace/projects/nixl-ucx`, leaving `/workspace` available for other projects.

Log in to Quay:

```bash
docker login quay.io
```

Go to the workflow directory:

```bash
cd /Users/nwadekar/Projects/pod-build-env/nixl
```

## 2. Configure the image repositories

The default repository names and image tag are defined at the top of:

`scripts/build-and-push.sh`

```bash
BUILD_ENV_IMAGE=${BUILD_ENV_IMAGE:-quay.io/nwadekar/nixl-build-env}
RUNTIME_IMAGE=${RUNTIME_IMAGE:-quay.io/nwadekar/nixl-ucx-bench}
IMAGE_TAG=${IMAGE_TAG:-nixl-1.4.1-ucx-1.22.0}
```

They can be changed in the script or overridden for one invocation:

```bash
BUILD_ENV_IMAGE=quay.io/myorg/nixl-builder \
RUNTIME_IMAGE=quay.io/myorg/nixl-runtime \
IMAGE_TAG=test \
./scripts/build-and-push.sh all
```

## 3. Build and push the build image

The build image is defined by `Dockerfile.build`. It contains CUDA development libraries, compilers, UCX dependencies, Meson, Ninja, Python, and other build tools.

```bash
./scripts/build-and-push.sh build-env
./scripts/build-and-push.sh push-build-env
```

The default image is:

```text
quay.io/nwadekar/nixl-build-env:nixl-1.4.1-ucx-1.22.0
```

## 4. Start the Kubernetes build pod

Apply `k8s/build-pod.yaml`:

```bash
./scripts/build-and-push.sh apply-build-pod
kubectl -n nwadekar-pirate wait \
  --for=condition=Ready pod/nixl-builder \
  --timeout=10m
```

The pod mounts the shared PVC at `/workspace`. The build script works in `/workspace/projects/nixl-ucx`. Attach VS Code to `nixl-builder` if source changes are needed.

## 5. Build UCX, NIXL, and NIXLBench in the pod

Run:

```bash
./scripts/build-and-push.sh build-in-pod
```

`scripts/build-in-pod.sh` performs the following:

1. Clones UCX `v1.22.0` into `/workspace/projects/nixl-ucx/src/ucx` if it is missing.
2. Clones NIXL `v1.4.1` into `/workspace/projects/nixl-ucx/src/nixl` if it is missing.
3. Builds UCX with CUDA, verbs, shared libraries, and multithreading.
4. Builds NIXL against the private UCX installation.
5. Builds NIXLBench from `benchmark/nixlbench`.
6. Stages the runtime files into `/workspace/projects/nixl-ucx/artifacts`.

The important PVC directories are:

```text
/workspace/projects/nixl-ucx/src/{ucx,nixl}
/workspace/projects/nixl-ucx/build/{ucx,nixl,nixlbench}
/workspace/projects/nixl-ucx/install/{ucx,nixl,nixlbench}
/workspace/projects/nixl-ucx/artifacts/nixl-stack.tar.gz
```

Existing Git trees are preserved, so local edits are not reset by the script.

## 6. Copy the build artifacts to the host

```bash
./scripts/build-and-push.sh copy-artifacts
```

This copies the artifact archive from the pod and extracts it into:

```text
nixl/artifacts/stage/
```

## 7. Build and push the runtime image

The runtime image is defined by `Dockerfile.runtime`. It contains CUDA runtime libraries, UCX, NIXL, NIXLBench, and only the required runtime dependencies.

```bash
./scripts/build-and-push.sh build-runtime
./scripts/build-and-push.sh push-runtime
```

The default runtime image is:

```text
quay.io/nwadekar/nixl-ucx-bench:nixl-1.4.1-ucx-1.22.0
```

## 8. Start the runtime pod

Apply `k8s/run-pod.yaml`:

```bash
./scripts/build-and-push.sh apply-run-pod
```

The runtime pod:

- Requests one NVIDIA GPU.
- Uses standard Kubernetes networking and IPC isolation.
- Sets the UCX transport environment.
- Starts with `sleep infinity` so commands can be executed interactively.

## 9. Run NIXLBench

Check the binary:

```bash
kubectl -n nwadekar-pirate exec -it nixl-runner -- nixlbench --help
```

Run an ASIO/UCX benchmark:

```bash
kubectl -n nwadekar-pirate exec -it nixl-runner -- \
  nixlbench --backend UCX
```

## 10. One-command build flow

After `docker login quay.io`, the complete build and push flow is:

```bash
TARGET_PLATFORM=linux/amd64 \
UBUNTU_VERSION=24.04 \
CUDA_VERSION=13.0.3 \
./scripts/build-and-push.sh all
```

The `all` command:

1. Builds the build image.
2. Pushes the build image.
3. Applies the build pod.
4. Waits for the build pod to become ready.
5. Builds UCX, NIXL, and NIXLBench in the pod.
6. Copies the artifacts to the host.
7. Builds the runtime image.
8. Pushes the runtime image.

Start the runtime pod afterward:

```bash
./scripts/build-and-push.sh apply-run-pod
```

## 11. Alternate x86-64 Ubuntu/CUDA versions

For CUDA 12.8.1 on Ubuntu 22.04:

```bash
TARGET_PLATFORM=linux/amd64 \
UBUNTU_VERSION=22.04 \
CUDA_VERSION=12.8.1 \
./scripts/build-and-push.sh all
```

The selected CUDA tag must exist in the NVIDIA CUDA registry and must be compatible with the NVIDIA driver on the target node.
