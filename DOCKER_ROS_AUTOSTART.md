# Start Maxbot Navigation at Boot

Run the ROS navigation stack as the foreground process of a Docker container
and let a host systemd service supervise that container.  This is the
recommended deployment for this robot because the container uses the host
system PulseAudio socket, which must be ready before ROS audio nodes start.

The container starts:

```text
maxbot_navigation/launch/nav_office.launch
```

## Directory Layout

Clone this repository into the robot's designated workspace root. The Docker
configuration is separate from the ROS source workspaces, which are mounted
into the container at runtime:

```text
/home/ubuntu/docker_ws/
├── maxbot-docker/             # this repository
├── maxbot/ros_ws/src/         # Maxbot ROS workspace source
├── leg_ws/src/                # leg ROS workspace source
└── maxbot_config/             # robot runtime configuration
```

The launcher defaults `WORKSPACE_CONTEXT` to `/home/ubuntu/docker_ws`, so
keep this layout unless its workspace and volume paths are changed together.

## Prerequisites

- Docker and the robot's system PulseAudio daemon must start at boot:

  ```bash
  sudo systemctl enable docker.service pulseaudio.service
  ```

- Run the setup command below after source or Dockerfile changes.  It builds
  the image and creates the container once; systemd starts the resulting
  container at boot and does **not** rebuild the image then.

- Before creating the container, ensure the system PulseAudio socket exists.
  This makes `build_docker.sh` mount the system socket rather than a stale
  per-user socket:

  ```bash
  sudo systemctl start pulseaudio.service
  test -S /var/run/pulse/native
  ```

## Create the Navigation Container

`build_docker.sh` uses the robot's established container configuration:
hardware access, `/dev` mount, host networking, the optional audio device,
PulseAudio socket and cookie, and optional X11 display.  Its navigation mode
uses those same settings while making `roslaunch` the foreground command:

```bash
cd /home/ubuntu/docker_ws/maxbot-docker
START_NAVIGATION=1 \
CONTAINER_NAME=maxbot-navigation \
RESTART_POLICY=no \
ROS_MASTER_URI=http://192.168.10.86:13131 \
ROS_HOSTNAME=192.168.10.86 \
ROS_IP=192.168.10.86 \
./build_docker.sh
```

`RESTART_POLICY=no` is required: systemd is the sole restart supervisor for
this container.  The command starts the container once; stop it before
enabling the systemd unit in the next section.

When this command creates the container, the script detects `/dev/snd` and an
active host PulseAudio socket and includes the same audio options used for an
interactive container.  On this robot it deliberately prefers the system
socket at `/var/run/pulse/native` over a per-user socket, matching the boot
service's `pulseaudio.service` dependency.  If no audio device or PulseAudio
server is available, the script logs a warning and safely starts without that
optional integration.  Display forwarding is handled the same way when
`DISPLAY` is set.

The image configures its PulseAudio clients with `enable-shm = no`.  They use
the mounted PulseAudio Unix socket and cookie, but do not create POSIX shared
memory objects.  This prevents the otherwise harmless
`shm_unlink(/pulse-shm-...) failed` messages emitted when a container client
stops playback.

The host-network mode is intentional: `192.168.10.86` is the robot host's
address and is directly reachable by other ROS nodes.  The three ROS settings
are passed into the container at creation time.  If the robot's address
changes, recreate the container with the updated values.

The image also appends these values to `/home/ubuntu/.bashrc`, after sourcing
the ROS and workspace setup files.  Interactive shells in the container
therefore receive the same ROS networking configuration.

ROS normally expects either `ROS_IP` or `ROS_HOSTNAME`; both are retained here
because this deployment requires them.  If remote nodes advertise or resolve
the wrong address, remove `ROS_HOSTNAME` and retain `ROS_IP`.

`nav_office.launch` does not explicitly launch `roscore`.  Standard
`roslaunch` starts a master if the configured master is not available.  If a
separate master must own `192.168.10.86:13131`, add
`WAIT_FOR_MASTER=1` to the creation command.  The navigation stack then uses
`roslaunch --wait` and waits for that master instead of starting one.

## Install the Boot Service

Install the repository's systemd unit, then enable it.  Run these commands
only after the navigation container above has been created:

```bash
docker stop maxbot-navigation

sudo install -D -m 0644 \
  /home/ubuntu/docker_ws/maxbot-docker/systemd/maxbot-navigation.service \
  /etc/systemd/system/maxbot-navigation.service
sudo systemctl daemon-reload
sudo systemctl enable --now maxbot-navigation.service
```

The unit waits for `docker.service`, `pulseaudio.service`, and
`network-online.target`.  It also verifies that `/var/run/pulse/native` is a
socket before attaching to the container.  If PulseAudio is still bringing up
its socket, systemd retries after five seconds.

## Verify and Operate

```bash
docker ps --filter name=maxbot-navigation
systemctl status maxbot-navigation.service
journalctl --follow --unit maxbot-navigation.service
docker inspect --format '{{.HostConfig.RestartPolicy.Name}}' maxbot-navigation
```

The inspection command should print `no`.  Test the boot behavior
only when it is safe to interrupt robot navigation:

```bash
sudo reboot
```

After the host is back, verify the container and ROS graph again.  With host
networking, a convenient ROS check is:

```bash
docker exec maxbot-navigation /bin/bash -lc 'source /opt/ros/kinetic/setup.bash && source /home/ubuntu/maxbot/ros_ws/devel/setup.bash && rosnode list'
```

## Disable or Re-enable Automatic Startup

Disable future systemd startup and stop the container:

```bash
sudo systemctl disable --now maxbot-navigation.service
```

Re-enable boot startup later:

```bash
sudo systemctl enable --now maxbot-navigation.service
```

Do not configure Docker `--restart` for `maxbot-navigation`; systemd is the
single supervisor for its lifecycle and starts it only after system PulseAudio
is ready.

To apply changed image, ROS, device, or audio configuration, intentionally
remove the old navigation container and rerun the creation command:

```bash
docker rm --force maxbot-navigation
```
