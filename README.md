# Maxbot and Cartographer Docker Images

`build_docker.sh` builds an image and creates its development container. It
selects the image with `DOCKERFILE`; Maxbot remains the default.

```bash
cd /home/ubuntu/docker_ws/maxbot-docker

# Maxbot
./build_docker.sh

# Cartographer
DOCKERFILE=Dockerfile.cartographer ./build_docker.sh
```

The script requires Docker BuildKit because the Dockerfiles use named build
contexts and bind mounts during the image build.

## Workspace layout

By default, `WORKSPACE_CONTEXT` is the invoking user's `docker_ws` directory.
Set it to an absolute path to use another location.

```text
docker_ws/
├── maxbot-docker/                 # This repository
├── maxbot/
│   └── ros_ws/src/                # Maxbot source workspace
├── maxbot_config/                 # Maxbot runtime configuration
├── leg_ws/src/                    # Leg source workspace
└── cartographer_ws/src/           # Cartographer and cartographer_ros source
```

The script checks required source and mount directories before invoking Docker.
The selected container receives only the workspace mounts it needs:

| Image | Host paths mounted in the container |
| --- | --- |
| `Dockerfile.maxbot` | `maxbot`, `maxbot_config`, and `leg_ws` |
| `Dockerfile.cartographer` | `cartographer_ws` |

The images' `ubuntu` user is built with the invoking user's UID and GID, so
files generated in mounted workspaces retain the correct host ownership.

## Cartographer

`Dockerfile.cartographer` is based on ROS Kinetic. It installs the common
development tools from the Maxbot image, GCC 9, protobuf 3, and Abseil, then
installs Cartographer's rosdep dependencies and builds the workspace with
Ninja.

The unavailable `libabsl-dev`, `libqt5widgets5t64`, `libqt5gui5t64`, and
`libqt5core5t64` dependencies (and their corresponding Qt rosdep keys) are
intentionally skipped. Abseil is supplied by Cartographer's install script.

At runtime the host `cartographer_ws` directory replaces the copy built into
the image. A newly created host workspace may contain only `src/`; in that
case, the container builds `install_isolated` on first start:

```bash
docker logs -f cartographer
docker exec -it cartographer bash
```

Later starts reuse the host `install_isolated/setup.bash`. To force a clean
Cartographer build, remove or rename that install space on the host and start
the container again.

## Maxbot navigation mode

`START_NAVIGATION=1` is supported only with `Dockerfile.maxbot`; it starts
`maxbot_navigation` rather than an interactive shell. See
[DOCKER_ROS_AUTOSTART.md](DOCKER_ROS_AUTOSTART.md) for the systemd deployment
workflow and required ROS environment variables.
