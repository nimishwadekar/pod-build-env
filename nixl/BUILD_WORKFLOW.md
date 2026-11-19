# NIXL / UCX x86-64 Build Workflow

This workflow builds the existing UCX, NIXL, NIXLBench, and vLLM source trees on a Kubernetes pod, then builds and pushes a runtime image from the host. Source branches/tags are chosen manually in the pod; the build does not clone, select, or verify them.

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

The build image is defined by `Dockerfile.build`. It contains CUDA development libraries, compilers, UCX dependencies, Meson, Ninja, Python, and other build tools. The source-build command installs Python requirements from the existing vLLM checkout into a PVC-backed build virtual environment, and uses vLLM's Rust build helper.

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
  --for=condition=Ready pod/nixl-builder-a100-03 \
  --timeout=10m
```

The pod mounts the shared PVC at `/workspace`. The build script works in `/workspace/projects/nixl-ucx`. Attach VS Code to `nixl-builder-a100-03` if source changes are needed. Pod names are suffixed with their target node; the builder defaults to `a100-03` and can be moved with `BUILD_POD_NODE`.

## 5. Build UCX, NIXL, and NIXLBench in the pod

Run:

```bash
./scripts/build-and-push.sh build-in-pod
```

`scripts/build-in-pod.sh` performs the following:

1. Uses the existing `src/ucx`, `src/nixl`, and `src/vllm` checkouts as they are.
2. Installs vLLM's Python build requirements into `build/python-env`.
3. Builds UCX with CUDA, verbs, shared libraries, and multithreading.
4. Builds NIXL, including its Python bindings, against that UCX installation.
5. Builds NIXLBench from `benchmark/nixlbench`.
6. Builds vLLM's Rust artifacts and Python/CUDA wheel from source into `install/vllm`.
7. Stages UCX, NIXL, NIXLBench, and the vLLM wheel into the runtime artifact archive.

The important PVC directories are:

```text
/workspace/projects/nixl-ucx/src/{ucx,nixl,vllm}
/workspace/projects/nixl-ucx/build/{ucx,nixl,nixlbench}
/workspace/projects/nixl-ucx/install/{ucx,nixl,nixlbench,vllm}
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

The runtime image is defined by `Dockerfile.runtime`. It contains UCX, NIXL and its Python bindings, NIXLBench, the source-built vLLM wheel and its dependencies, and CUDA development libraries/tools needed for runtime JIT compilation. It does not install the PyPI NIXL backend bundle. The default command remains `sleep infinity`; invoke `vllm serve ...` when deploying the serving workload.

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

- Is named `nixl-runner-a100-03` by default, with the node suffix controlled by `RUN_POD_NODE`.
- Requests one NVIDIA GPU.
- Uses standard Kubernetes networking and IPC isolation.
- Sets the UCX transport environment.
- Starts with `sleep infinity` so commands can be executed interactively.

## 9. Run NIXLBench

Check the binary:

```bash
kubectl -n nwadekar-pirate exec -it nixl-runner-a100-03 -- nixlbench --help
```

Run an ASIO/UCX benchmark:

```bash
kubectl -n nwadekar-pirate exec -it nixl-runner-a100-03 -- \
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

## 11. Build the host-local request-tracing image

The request-tracing mode uses the existing build-and-push workflow, but does
not call the legacy `contrib/tcp-profile-build.sh` builder. It copies
`nixl-ucx/profiling/dram-dram-ucx/tools/request_trace` from the adjacent checkout to a
unique PVC directory, then builds UCX, NIXL, and NIXLBench in fresh
request-tracing build/install directories. Existing source edits, profiler
builds, and install prefixes are not cleaned or replaced.

The request-tracing source changes must already be present in the PVC source
checkouts. The helper verifies the UCX/NIXL build options and compatibility
headers before compiling. It installs the recorder, checks dynamic linkage,
and gives only the staged runtime copies RPATHs for `/opt/nixl-stack`; the
isolated builder installs remain unchanged. The runtime image includes the
recorder's library directory in its loader path.

Assign a fresh ID to every build and keep it set across the commands:

```bash
export REQUEST_TRACING=on
export TCP_PROFILING=off
export REQUEST_TRACE_BUILD_ID=rt-20261108-01

# Builds, packages and pushes; does not start runner pods or NIXLBench.
./scripts/build-and-push.sh rebuild-code
```

The image tag is
`<IMAGE_TAG>-request-trace-<REQUEST_TRACING>-<REQUEST_TRACE_BUILD_ID>`. The
request-trace archive and extracted stage have separate names, so the legacy
`nixl-stack.tar.gz` and `artifacts/stage` are preserved. `REQUEST_TRACE_SOURCE`
can override the adjacent-checkout path when the tools live elsewhere.

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

This workflow only builds and packages the image. Applying source and
destination runner pods, preflight checks, and starting the fixed 512-MiB
capture are separate steps; the build command does not start a transfer.
After a request-tracing image is pushed, its resolved digest is recorded in
`artifacts/nixl-stack-request-trace-<ID>-image.txt`. Use that immutable
`repository@sha256:...` reference when preparing the capture run.

## 12. Alternate x86-64 Ubuntu/CUDA versions

For CUDA 12.8.1 on Ubuntu 22.04:

```bash
TARGET_PLATFORM=linux/amd64 \
UBUNTU_VERSION=22.04 \
CUDA_VERSION=12.8.1 \
./scripts/build-and-push.sh all
```

The selected CUDA tag must exist in the NVIDIA CUDA registry and must be compatible with the NVIDIA driver on the target node.
