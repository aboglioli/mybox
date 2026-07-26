# mybox — build the image and drive the quadlet. Everything about how
# the container is composed lives in mybox.container + container/*.conf;
# this file only builds, installs the unit files and gets you a shell.
# The container is disposable (recreated on every restart/boot); state
# persists via the 01/02/03-persist-*.conf drop-ins under /srv/<name>.

set shell := ["bash", "-euo", "pipefail", "-c"]

mybox_dir := justfile_directory()

# Image must land in the ROOTFUL store — the system quadlet reads it;
# a plain rootless `podman build` would be invisible to it.
mybox_image := env_var_or_default("MYBOX_IMAGE", "localhost/mybox:latest")

# Unit name: <name>.container → <name>.service, state at /srv/<name>.
mybox_name := env_var_or_default("MYBOX_CONTAINER", "mybox")

# Default user for `enter` / `login` (created at boot by
# mybox-user-setup.service from MYBOX_* env).
mybox_username := env_var_or_default("MYBOX_USERNAME", "user")

mybox_netfile := env_var_or_default("MYBOX_NETFILE", "mybox-bridge.network")

# Default drop-in set for `just install`. 31-nvidia-raw vs 30-nvidia
# (CDI): pick exactly ONE — both would pass the devices twice.
mybox_dropins := env_var_or_default("MYBOX_DROPINS", "01-persist-root 02-persist-home 03-persist-srv 05-user 10-gui 20-gpu 31-nvidia-raw")

quadlet_dir := "/etc/containers/systemd"
unit := mybox_name + ".service"

default:
    @just --list --unsorted

# Build the OCI image into the rootful store.
build:
    @echo ">>> building {{mybox_image}}"
    sudo podman build -t "{{mybox_image}}" "{{mybox_dir}}"
    @echo ">>> done. apply with: just restart"

# Symlink quadlet + network + drop-ins into /etc/containers/systemd.
# Symlinks (not copies) so repo edits apply on the next daemon-reload.
# Name drop-ins to override the default set:
#   just install 01-persist-root 05-user 10-gui 31-nvidia-raw
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
    # Declarative: remove previously-linked drop-ins not in LIST (only
    # symlinks into this repo — hand-written local drop-ins are kept).
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

# Fast shell as USER (podman exec, no PAM session).
enter user=mybox_username:
    sudo podman exec -it -u "{{user}}" {{mybox_name}} /usr/bin/fish -l

# Full PAM/logind session as USER (login -f, empty-password user).
login user=mybox_username:
    sudo podman exec -it {{mybox_name}} login -f "{{user}}"
