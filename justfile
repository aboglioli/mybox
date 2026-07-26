# =====================================================================
# mybox justfile — build the image and drive the quadlet.
# =====================================================================
#
#   just build      build the OCI image into the rootful store
#   just install    symlink quadlet + drop-ins into /etc/containers/systemd
#   just start      systemctl start   (systemd creates the container)
#   just stop       systemctl stop    (systemd REMOVES the container)
#   just restart    systemctl restart (recreate — state survives)
#   just status     unit + container + LAN IP
#   just logs       journalctl -fu <unit>
#   just enter      fast shell (podman exec, no PAM session)
#   just login      full PAM/logind session (login -f)
#
# mybox runs as a PODMAN QUADLET system container: mybox.container plus
# container/*.conf drop-ins under /etc/containers/systemd, with systemd
# owning the lifecycle. This file does NOT run podman by hand — it builds
# the image, installs the unit files, and gets you a shell.
#
# The container is deliberately disposable; quadlet recreates it on every
# restart and every boot. State persistence is the quadlet's job:
#
#   01-persist-root.conf  /srv/<name>/{etc,var} → /etc, /var  (:idmap,
#                         seeded from the image factories on first boot)
#   02-persist-home.conf  /srv/<name>/home → /home
#   03-persist-srv.conf   /srv/<name>/srv  → /srv
#
# plus mybox-usr-overlay.service inside, which mounts a writable /usr +
# /opt overlay whose upperdir lives in /var. So pacman installs, the
# nvidia userland from `mybox install-nvidia`, and /etc edits all outlive
# recreation, while /usr's lower stays the live image — rebuild + restart
# rebases in place.
#
# Everything else (network, GUI sockets, GPU, devices, caps, runtime user)
# is quadlet configuration, NOT justfile configuration. Edit the drop-ins
# in container/ or /srv/<name>/container.env.
# =====================================================================

set shell := ["bash", "-euo", "pipefail", "-c"]

mybox_dir := justfile_directory()

# OCI tag to build. Must land in the ROOTFUL store — that is the one the
# system quadlet pulls from (rootful and rootless podman keep separate
# stores, so a plain `podman build` would be invisible to it).
mybox_image := env_var_or_default("MYBOX_IMAGE", "localhost/mybox:latest")

# Quadlet unit name: <name>.container → <name>.service, and every path
# inside the quadlet derives from it via %p (state at /srv/<name>). Copy
# the unit under another name to run a second box.
mybox_name := env_var_or_default("MYBOX_CONTAINER", "mybox")

# Default user for `enter` / `login`. The user itself is created at boot
# by mybox-user-setup.service from the MYBOX_USER/UID/GID/SHELL env in
# 05-user.conf or /srv/<name>/container.env.
mybox_username := env_var_or_default("MYBOX_USERNAME", "user")

# .network file installed alongside the quadlet. The base unit references
# mybox-bridge.network; switch with a drop-in carrying `Network=` (empty)
# plus the new value.
mybox_netfile := env_var_or_default("MYBOX_NETFILE", "mybox-bridge.network")

# Drop-ins installed by `just install` when none are named on the command
# line. Space-separated basenames from container/, without the .conf.
#
# 31-nvidia-raw (raw /dev/nvidia*) is the default because it is the
# verified-working path here. 30-nvidia (CDI) is the tidier one — it
# injects the devices AND the userland, so `mybox install-nvidia` becomes
# unnecessary. Pick exactly ONE of the two; installing both passes the
# devices twice.
mybox_dropins := env_var_or_default("MYBOX_DROPINS", "01-persist-root 02-persist-home 03-persist-srv 05-user 10-gui 20-gpu 31-nvidia-raw")

quadlet_dir := "/etc/containers/systemd"
unit := mybox_name + ".service"

default:
    @just --list --unsorted

# Build the OCI image into the rootful store (the one the quadlet reads).
build:
    @echo ">>> building {{mybox_image}}"
    sudo podman build -t "{{mybox_image}}" "{{mybox_dir}}"
    @echo ">>> done. apply with: just restart"

# Symlinks rather than copies, so edits in this repo take effect on the
# next daemon-reload. Idempotent. Name drop-ins to override the default
# set:  just install 01-persist-root 05-user 10-gui 31-nvidia-raw

# Symlink quadlet + network + drop-ins into /etc/containers/systemd.
install *dropins:
    #!/usr/bin/env bash
    set -euo pipefail
    SRC="{{mybox_dir}}"; NAME="{{mybox_name}}"; QD="{{quadlet_dir}}"
    LIST="{{dropins}}"; [[ -z "$LIST" ]] && LIST="{{mybox_dropins}}"
    for d in $LIST; do
      [[ -f "$SRC/container/$d.conf" ]] || { echo "ERROR: no drop-in container/$d.conf" >&2; exit 1; }
    done
    sudo mkdir -p "$QD/$NAME.container.d"
    sudo ln -sfn "$SRC/mybox.container" "$QD/$NAME.container"
    sudo ln -sfn "$SRC/container/{{mybox_netfile}}" "$QD/{{mybox_netfile}}"
    for d in $LIST; do
      sudo ln -sfn "$SRC/container/$d.conf" "$QD/$NAME.container.d/$d.conf"
    done
    # Declarative: drop any drop-in we previously linked that is not in
    # LIST, so the installed set matches exactly. Without this, switching
    # e.g. 31-nvidia-raw -> 30-nvidia would leave BOTH active and pass the
    # NVIDIA devices twice. Only symlinks pointing into this repo's
    # container/ dir are removed — hand-written local drop-ins are kept.
    for f in "$QD/$NAME.container.d"/*.conf; do
      [[ -L "$f" ]] || continue
      case "$(readlink -f "$f")" in "$SRC/container/"*) ;; *) continue ;; esac
      b=$(basename "$f" .conf)
      grep -qw -- "$b" <<<"$LIST" || { echo "    removing stale drop-in: $b"; sudo rm -f "$f"; }
    done
    sudo systemctl daemon-reload
    echo ">>> installed $NAME.container"
    echo "    drop-ins: $LIST"
    echo "    start:    just start"

# Start the unit — systemd creates the container.
start:
    sudo systemctl start {{unit}}

# Stop the unit — systemd removes the container; /srv state survives.
stop:
    sudo systemctl stop {{unit}}

# Recreate against the current image + drop-ins.
restart:
    sudo systemctl daemon-reload
    sudo systemctl restart {{unit}}

# Unit state, container state, LAN IP.
status:
    -systemctl status {{unit}} --no-pager -n 0
    -sudo podman ps -a --filter "name=^{{mybox_name}}$" --format 'table {{{{.Names}}\t{{{{.Status}}\t{{{{.Networks}}'
    -sudo podman exec {{mybox_name}} ip -o -4 addr show eth0

# Follow the unit journal.
logs:
    journalctl -fu {{unit}}

# No PAM session (XDG_SESSION_ID empty), but /run/user/<uid> and the user
# manager are already up via lingering, so rootless podman and flatpak work.

# Fast shell as USER (podman exec).
enter user=mybox_username:
    sudo podman exec -it -u "{{user}}" {{mybox_name}} /usr/bin/fish -l

# `login -f` runs pam_systemd, so XDG_SESSION_ID, pam_env and pam_limits
# all apply — the podman analog of `machinectl shell`. `-f` skips auth
# (the runtime user has an empty password).

# Full PAM/logind session as USER.
login user=mybox_username:
    sudo podman exec -it {{mybox_name}} login -f "{{user}}"
