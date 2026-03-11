#!/usr/bin/env bash
set -euo pipefail

NAME="${NAME:-orbit-dev}"
IMAGE="${IMAGE:-nvcr.io/nvidia/isaac-sim:4.1.0}"
ISAACLAB_VERSION="${ISAACLAB_VERSION:-v1.0.0}"
CONTAINER_ISAACLAB_PATH="${CONTAINER_ISAACLAB_PATH:-/workspace/isaaclab}"
CONTAINER_WORKSPACE="/workspace/orbit-surgical"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "${SCRIPT_DIR}")"
HOST_BASE="${HOST_BASE:-${HOME}/docker/orbit-surgical}"

mkdir -p \
  "${HOST_BASE}/isaaclab" \
  "${HOST_BASE}/cache/kit" \
  "${HOST_BASE}/cache/ov" \
  "${HOST_BASE}/cache/pip" \
  "${HOST_BASE}/cache/glcache" \
  "${HOST_BASE}/cache/computecache" \
  "${HOST_BASE}/logs" \
  "${HOST_BASE}/data" \
  "${HOST_BASE}/documents"

X11_ARGS=()
if [[ -n "${DISPLAY:-}" && -S "/tmp/.X11-unix/X0" ]]; then
  X11_ARGS+=(
    -e DISPLAY
    -v /tmp/.X11-unix:/tmp/.X11-unix:rw
  )
  if [[ -f "$HOME/.Xauthority" ]]; then
    X11_ARGS+=( -v "$HOME/.Xauthority:/root/.Xauthority:ro" )
  fi
fi

# ---------------------------------------------------------------------------
# Info
# ---------------------------------------------------------------------------
echo "[run_container] Container name:  ${NAME}"
echo "[run_container] Image:           ${IMAGE}"
echo "[run_container] Project dir:     ${PROJECT_DIR}"
echo "[run_container]   -> container:  ${CONTAINER_WORKSPACE}"
echo "[run_container] IsaacLab path:   ${CONTAINER_ISAACLAB_PATH} (inside container)"
echo "[run_container] Host cache base: ${HOST_BASE}"

# ---------------------------------------------------------------------------
# Launch container (detached; entrypoint runs setup then keeps bash alive)
# Use `docker logs -f ${NAME}` to watch setup progress
# Use `docker exec -it ${NAME} bash` to open a shell once setup is done
# ---------------------------------------------------------------------------
docker run -it --rm -d \
  --name "${NAME}" \
  --gpus all \
  --network host \
  -e ACCEPT_EULA=Y \
  -e PRIVACY_CONSENT=Y \
  -e OMNI_ENV_PRIVACY_CONSENT=Y \
  -e HOME=/root \
  -e IsaacLab_PATH="${CONTAINER_ISAACLAB_PATH}" \
  "${X11_ARGS[@]}" \
  -w "${CONTAINER_WORKSPACE}" \
  -v "${PROJECT_DIR}:${CONTAINER_WORKSPACE}:rw" \
  -v "${HOST_BASE}/isaaclab:${CONTAINER_ISAACLAB_PATH}:rw" \
  -v "${HOST_BASE}/cache/kit:/isaac-sim/kit/cache:rw" \
  -v "${HOST_BASE}/cache/ov:/root/.cache/ov:rw" \
  -v "${HOST_BASE}/cache/pip:/root/.cache/pip:rw" \
  -v "${HOST_BASE}/cache/glcache:/root/.cache/nvidia/GLCache:rw" \
  -v "${HOST_BASE}/cache/computecache:/root/.nv/ComputeCache:rw" \
  -v "${HOST_BASE}/logs:/root/.nvidia-omniverse/logs:rw" \
  -v "${HOST_BASE}/data:/root/.local/share/ov/data:rw" \
  -v "${HOST_BASE}/documents:/root/Documents:rw" \
  -v "$HOME/.ssh:/root/.ssh:ro" \
  --entrypoint bash \
  --user root \
  "${IMAGE}" -lc "
    set -e
    # Ensure git and ssh are available
    if ! command -v git >/dev/null 2>&1 || ! command -v cmake >/dev/null 2>&1; then
      apt-get update -qq && apt-get install -y --no-install-recommends git openssh-client ca-certificates cmake build-essential
    fi
    # Install Isaac Lab if not already installed (persisted on host)
    if [[ ! -f ${CONTAINER_ISAACLAB_PATH}/isaaclab.sh ]]; then
      echo '[setup] Cloning Isaac Lab ${ISAACLAB_VERSION} ...'
      git clone --branch ${ISAACLAB_VERSION} https://github.com/isaac-sim/IsaacLab.git ${CONTAINER_ISAACLAB_PATH}
      ln -sfn /isaac-sim ${CONTAINER_ISAACLAB_PATH}/_isaac_sim
      # Bootstrap pip into Isaac Sim's bundled Python (not included by default)
      ISAACSIM_PY=${CONTAINER_ISAACLAB_PATH}/_isaac_sim/kit/python/bin/python3
      \${ISAACSIM_PY} -m ensurepip --upgrade || true
      \${ISAACSIM_PY} -m pip install -U pip setuptools wheel
      # Also upgrade pip via python.sh (isaaclab.sh uses this wrapper, which may resolve different site-packages)
      ${CONTAINER_ISAACLAB_PATH}/_isaac_sim/python.sh -m pip install -U pip setuptools wheel || true
      # Fix: rsl-rl renamed to rsl-rl-lib; latest rsl-rl-lib requires torch>=2.6 (conflicts with 2.2.2).
      # Pre-install without deps, then strip git URL from setup.py so pip skips version resolution.
      \${ISAACSIM_PY} -m pip install --no-deps 'rsl-rl-lib @ git+https://github.com/leggedrobotics/rsl_rl.git'
      find ${CONTAINER_ISAACLAB_PATH}/source -type f \( -name 'setup.py' -o -name 'pyproject.toml' \) \
        -exec sed -i -E 's|rsl-rl[[:space:]]*@[[:space:]]*git\+[^\"[:space:]]+|rsl-rl-lib|g' {} \;
      echo '[setup] Installing Isaac Lab ...'
      ${CONTAINER_ISAACLAB_PATH}/isaaclab.sh --install
    else
      echo '[setup] Isaac Lab already installed, skipping.'
    fi
    # Fix hostname DNS resolution (needed for Isaac Sim streaming URL menu)
    echo "127.0.0.1 $(hostname)" >> /etc/hosts || true
    # Mark the mounted workspace as safe for git
    git config --global --add safe.directory ${CONTAINER_WORKSPACE} || true
    # Ensure toml is in site-packages (not just prebundle) for editable install builds
    ${CONTAINER_ISAACLAB_PATH}/_isaac_sim/kit/python/bin/python3 -m pip install toml
    # Install ORBIT-Surgical extensions
    cd ${CONTAINER_WORKSPACE}
    bash orbitsurgical.sh
    # Install debugpy for VSCode debugger
    /isaac-sim/kit/python/bin/python3 -m pip install debugpy
    exec bash"

echo ""
echo "[run_container] Container '${NAME}' is starting in the background."
echo "  Watch setup progress : docker logs -f ${NAME}"
echo "  Open a shell         : docker exec -it ${NAME} bash"
echo "  Stop container       : docker stop ${NAME}"
