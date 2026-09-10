#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Select the image to build.  The default retains the existing Maxbot
# development workflow; set DOCKERFILE=Dockerfile.cartographer to build the
# Cartographer development image.
DOCKERFILE="${DOCKERFILE:-Dockerfile.maxbot}"
case "${DOCKERFILE}" in
  Dockerfile.maxbot)
    DEFAULT_CONTAINER_NAME=maxbot
    DEFAULT_IMAGE_NAME=maxbot:kinetic
    REQUIRED_WORKSPACES=(leg_ws maxbot/ros_ws)
    ;;
  Dockerfile.cartographer)
    DEFAULT_CONTAINER_NAME=cartographer
    DEFAULT_IMAGE_NAME=cartographer:kinetic
    REQUIRED_WORKSPACES=(cartographer_ws)
    ;;
  *)
    echo "Error: unsupported Dockerfile: ${DOCKERFILE}" >&2
    exit 1
    ;;
esac

DOCKERFILE_PATH="${SCRIPT_DIR}/${DOCKERFILE}"
if [[ ! -f "${DOCKERFILE_PATH}" ]]; then
  echo "Error: Dockerfile does not exist: ${DOCKERFILE_PATH}" >&2
  exit 1
fi

# Container name
CONTAINER_NAME="${CONTAINER_NAME:-${DEFAULT_CONTAINER_NAME}}"
IMAGE_NAME="${IMAGE_NAME:-${DEFAULT_IMAGE_NAME}}"
HOST_USER="${SUDO_USER:-${USER:-ubuntu}}"
if ! getent passwd "${HOST_USER}" >/dev/null; then
  echo "Error: host user does not exist: ${HOST_USER}" >&2
  exit 1
fi
HOST_HOME="$(getent passwd "${HOST_USER}" | awk -F: '{print $6}')"
HOST_UID="$(id -u "${HOST_USER}")"
HOST_GID="$(id -g "${HOST_USER}")"
WORKSPACE_CONTEXT="${WORKSPACE_CONTEXT:-${HOST_HOME}/docker_ws}"
if [[ "${WORKSPACE_CONTEXT}" != /* ]]; then
  echo "Error: WORKSPACE_CONTEXT must be an absolute path: ${WORKSPACE_CONTEXT}" >&2
  exit 1
fi
START_NAVIGATION="${START_NAVIGATION:-0}"
# Navigation containers are normally supervised by systemd.  Set an explicit
# Docker restart policy only for deployments that intentionally do not use the
# systemd unit.
RESTART_POLICY="${RESTART_POLICY:-no}"
WAIT_FOR_MASTER="${WAIT_FOR_MASTER:-0}"
ROS_MASTER_URI="${ROS_MASTER_URI:-}"
ROS_HOSTNAME="${ROS_HOSTNAME:-}"
ROS_IP="${ROS_IP:-}"

case "${DOCKERFILE}" in
  Dockerfile.maxbot)
    BUILD_CONTEXT_ARGS=(--build-context "workspaces=${WORKSPACE_CONTEXT}")
    WORKSPACE_MOUNT_ARGS=(
      -v "${WORKSPACE_CONTEXT}/maxbot:/home/ubuntu/maxbot"
      -v "${WORKSPACE_CONTEXT}/maxbot_config:/home/ubuntu/maxbot_config"
      -v "${WORKSPACE_CONTEXT}/leg_ws:/home/ubuntu/leg_ws"
    )
    REQUIRED_MOUNT_PATHS=(maxbot maxbot_config leg_ws)
    ;;
  Dockerfile.cartographer)
    # The Cartographer Dockerfile needs only the source tree.  Do not upload
    # its previous builds or its locally cloned protobuf/Abseil checkouts.
    BUILD_CONTEXT_ARGS=(
      --build-context "cartographer_sources=${WORKSPACE_CONTEXT}/cartographer_ws/src"
    )
    WORKSPACE_MOUNT_ARGS=(
      -v "${WORKSPACE_CONTEXT}/cartographer_ws:/home/ubuntu/cartographer_ws"
    )
    REQUIRED_MOUNT_PATHS=(cartographer_ws)
    ;;
esac

for boolean_var in START_NAVIGATION WAIT_FOR_MASTER; do
  case "${!boolean_var}" in
    0|1) ;;
    *)
      echo "Error: ${boolean_var} must be 0 or 1." >&2
      exit 1
      ;;
  esac
done

if [[ "${START_NAVIGATION}" == '1' ]]; then
  if [[ "${DOCKERFILE}" != 'Dockerfile.maxbot' ]]; then
    echo 'Error: START_NAVIGATION=1 is supported only by Dockerfile.maxbot.' >&2
    exit 1
  fi
  for required_var in ROS_MASTER_URI ROS_HOSTNAME ROS_IP; do
    if [[ -z "${!required_var}" ]]; then
      echo "Error: ${required_var} must be set when START_NAVIGATION=1." >&2
      exit 1
    fi
  done
fi

for workspace in "${REQUIRED_WORKSPACES[@]}"; do
  if [[ ! -d "${WORKSPACE_CONTEXT}/${workspace}/src" ]]; then
    echo "Error: missing workspace source directory: ${WORKSPACE_CONTEXT}/${workspace}/src" >&2
    exit 1
  fi
done

for mount_path in "${REQUIRED_MOUNT_PATHS[@]}"; do
  if [[ ! -d "${WORKSPACE_CONTEXT}/${mount_path}" ]]; then
    echo "Error: missing workspace mount directory: ${WORKSPACE_CONTEXT}/${mount_path}" >&2
    exit 1
  fi
done

# X11 is optional because robots may run headless.
DISPLAY_ARGS=()
if [[ -n "${DISPLAY:-}" ]]; then
  DISPLAY_ARGS+=(
    --volume=/tmp/.X11-unix:/tmp/.X11-unix
    "--env=DISPLAY=${DISPLAY}"
  )
fi

# ALSA is optional because some robots do not have a sound device attached.
AUDIO_ARGS=()
if [[ -d /dev/snd ]]; then
  AUDIO_GID="$(stat -c '%g' /dev/snd/controlC0 2>/dev/null || \
    getent group audio | awk -F: '{print $3}')"
  AUDIO_ARGS+=(--device=/dev/snd)
  if [[ -n "${AUDIO_GID}" ]]; then
    AUDIO_ARGS+=(--group-add "${AUDIO_GID}")
  fi
else
  echo 'Warning: /dev/snd is not present; audio support is disabled.' >&2
fi

# Use the host PulseAudio server.  This robot runs a system PulseAudio service,
# so prefer its socket.  That matches the systemd navigation-service dependency
# and avoids selecting an intermittent per-user PulseAudio daemon when both
# servers are present.
PULSE_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${HOST_UID}}"
PULSE_SOCKET=""
for candidate in \
    "/var/run/pulse/native" \
    "${PULSE_RUNTIME_DIR}/pulse/native"; do
  if [[ -S "${candidate}" ]]; then
    PULSE_SOCKET="${candidate}"
    break
  fi
done

# Preserve support for deployments with a nonstandard Unix socket location.
if [[ -z "${PULSE_SOCKET}" ]] && command -v pactl >/dev/null 2>&1; then
  HOST_PULSE_SERVER="$(pactl info 2>/dev/null \
    | sed -n 's/^Server String: //p' | head -n 1 || true)"
  case "${HOST_PULSE_SERVER}" in
    unix:/*) PULSE_SOCKET="${HOST_PULSE_SERVER#unix:}" ;;
    /*) PULSE_SOCKET="${HOST_PULSE_SERVER}" ;;
  esac
fi

PULSE_COOKIE=""
for candidate in \
    "${HOST_HOME}/.config/pulse/cookie" \
    "${HOST_HOME}/.pulse-cookie"; do
  if [[ -f "${candidate}" ]]; then
    PULSE_COOKIE="${candidate}"
    break
  fi
done

PULSE_ARGS=()
if [[ -n "${PULSE_SOCKET}" && -S "${PULSE_SOCKET}" ]]; then
  PULSE_SOCKET_DIR="$(dirname -- "${PULSE_SOCKET}")"
  PULSE_ARGS+=(
    --volume="${PULSE_SOCKET_DIR}:${PULSE_SOCKET_DIR}:ro"
    "--env=PULSE_SERVER=unix:${PULSE_SOCKET}"
  )
  if [[ -n "${PULSE_COOKIE}" ]]; then
    PULSE_ARGS+=(
      --volume="${PULSE_COOKIE}:/home/ubuntu/.config/pulse/cookie:ro"
      --env=PULSE_COOKIE=/home/ubuntu/.config/pulse/cookie
    )
  else
    echo "Warning: PulseAudio cookie not found under ${HOST_HOME}/.config/pulse/cookie or ${HOST_HOME}/.pulse-cookie." >&2
  fi
else
  echo 'Warning: no active PulseAudio socket was found on the host.' >&2
fi

# Build the image that contains the ubuntu user before starting the container.
docker build \
  "${BUILD_CONTEXT_ARGS[@]}" \
  --build-arg "USER_UID=${HOST_UID}" \
  --build-arg "USER_GID=${HOST_GID}" \
  --file "${DOCKERFILE_PATH}" \
  --tag "${IMAGE_NAME}" \
  "${SCRIPT_DIR}"

# Run the Docker container.  START_NAVIGATION=1 creates a boot-safe container
# that runs navigation as PID 1; the default remains an interactive shell for
# development use.
DOCKER_RUN_FLAGS=(-itd)
CONTAINER_ENV_ARGS=()
CONTAINER_COMMAND=("${IMAGE_NAME}" /bin/bash)

if [[ "${DOCKERFILE}" == 'Dockerfile.cartographer' ]]; then
  # The bind mount intentionally replaces the workspace baked into the image.
  # A newly created host workspace may contain only src/, so build its missing
  # install space before opening the development shell.
  CONTAINER_COMMAND=(
    "${IMAGE_NAME}"
    /bin/bash
    -lc
    'source /opt/ros/kinetic/setup.bash && if [[ ! -f /home/ubuntu/cartographer_ws/install_isolated/setup.bash ]]; then cd /home/ubuntu/cartographer_ws && catkin_make_isolated --install --use-ninja; fi && exec /bin/bash'
  )
fi

if [[ "${START_NAVIGATION}" == '1' ]]; then
  ROS_LAUNCH_COMMAND='roslaunch maxbot_navigation nav_office.launch'
  if [[ "${WAIT_FOR_MASTER}" == '1' ]]; then
    ROS_LAUNCH_COMMAND='roslaunch --wait maxbot_navigation nav_office.launch'
  fi

  DOCKER_RUN_FLAGS=(-d "--restart=${RESTART_POLICY}")
  CONTAINER_ENV_ARGS=(
    "--env=ROS_MASTER_URI=${ROS_MASTER_URI}"
    "--env=ROS_HOSTNAME=${ROS_HOSTNAME}"
    "--env=ROS_IP=${ROS_IP}"
  )
  CONTAINER_COMMAND=(
    "${IMAGE_NAME}"
    /bin/bash
    -lc
    "source /opt/ros/kinetic/setup.bash && source /home/ubuntu/maxbot/ros_ws/devel/setup.bash && exec ${ROS_LAUNCH_COMMAND}"
  )
fi

docker run "${DOCKER_RUN_FLAGS[@]}" \
  --name="${CONTAINER_NAME}" \
  --user ubuntu \
  --network host \
  --ipc=host \
  "${WORKSPACE_MOUNT_ARGS[@]}" \
  --privileged \
  --env="QT_X11_NO_MITSHM=1" \
  --volume="/etc/localtime:/etc/localtime:ro" \
  -v /dev:/dev \
  --group-add video \
  "${AUDIO_ARGS[@]}" \
  "${PULSE_ARGS[@]}" \
  "${DISPLAY_ARGS[@]}" \
  "${CONTAINER_ENV_ARGS[@]}" \
  "${CONTAINER_COMMAND[@]}"
