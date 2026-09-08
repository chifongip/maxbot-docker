#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Container name
CONTAINER_NAME="${CONTAINER_NAME:-maxbot}"
IMAGE_NAME="${IMAGE_NAME:-maxbot:kinetic}"
HOST_USER="${USER:-ubuntu}"
HOST_HOME="${HOME:-/home/${HOST_USER}}"
HOST_UID="$(id -u)"
WORKSPACE_CONTEXT="${WORKSPACE_CONTEXT:-/home/${HOST_USER}/docker_ws}"
START_NAVIGATION="${START_NAVIGATION:-0}"
# Navigation containers are normally supervised by systemd.  Set an explicit
# Docker restart policy only for deployments that intentionally do not use the
# systemd unit.
RESTART_POLICY="${RESTART_POLICY:-no}"
WAIT_FOR_MASTER="${WAIT_FOR_MASTER:-0}"
ROS_MASTER_URI="${ROS_MASTER_URI:-}"
ROS_HOSTNAME="${ROS_HOSTNAME:-}"
ROS_IP="${ROS_IP:-}"

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
  for required_var in ROS_MASTER_URI ROS_HOSTNAME ROS_IP; do
    if [[ -z "${!required_var}" ]]; then
      echo "Error: ${required_var} must be set when START_NAVIGATION=1." >&2
      exit 1
    fi
  done
fi

for workspace in leg_ws maxbot/ros_ws; do
  if [[ ! -d "${WORKSPACE_CONTEXT}/${workspace}/src" ]]; then
    echo "Error: missing workspace source directory: ${WORKSPACE_CONTEXT}/${workspace}/src" >&2
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
  --build-context "workspaces=${WORKSPACE_CONTEXT}" \
  --file "${SCRIPT_DIR}/Dockerfile.maxbot" \
  --tag "${IMAGE_NAME}" \
  "${SCRIPT_DIR}"

# Run the Docker container.  START_NAVIGATION=1 creates a boot-safe container
# that runs navigation as PID 1; the default remains an interactive shell for
# development use.
DOCKER_RUN_FLAGS=(-itd)
CONTAINER_ENV_ARGS=()
CONTAINER_COMMAND=("${IMAGE_NAME}" /bin/bash)

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
  -v "/home/${HOST_USER}/docker_ws/maxbot:/home/ubuntu/maxbot" \
  -v "/home/${HOST_USER}/docker_ws/maxbot_config:/home/ubuntu/maxbot_config" \
  -v "/home/${HOST_USER}/docker_ws/leg_ws:/home/ubuntu/leg_ws" \
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
