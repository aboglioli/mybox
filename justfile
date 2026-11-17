# mybox — build the images and drive the quadlet. Everything about how
# the container is composed lives in mybox.container + container/*.conf;
# this file only builds, installs the unit files and gets you a shell.
# The container is disposable (recreated on every restart/boot); state
# persists under /srv/users/<uid>/<name>, which mybox.container binds at
# /.mybox and the pre-init turns into an overlay upper for each tree.
#
# Rootless throughout: run every recipe as the account that owns the box
# — yourself, or the isolated account (README "Isolated box"). No sudo.

set shell := ["bash", "-euo", "pipefail", "-c"]

mybox_dir := justfile_directory()

# Must match Image= in mybox.container / container/02-gaming.conf. A
# local build tags over the published reference in YOUR rootless store,
# which is the store your user quadlet reads.
mybox_image := env_var_or_default("MYBOX_IMAGE", "ghcr.io/aboglioli/mybox:latest")
gaming_image := env_var_or_default("MYBOX_GAMING_IMAGE", "ghcr.io/aboglioli/mybox-gaming:latest")

# Unit name: <name>.container → <name>.service, state at /srv/users/<uid>/<name>.
mybox_name := env_var_or_default("MYBOX_CONTAINER", "mybox")

# Default user for `enter` / `login` (created at boot by
# mybox-user-setup.service from MYBOX_* env).
mybox_username := env_var_or_default("MYBOX_USERNAME", "user")

# Default drop-in set for `just install`: a desktop box with the GPU.
# Persistence is NOT here — it is part of mybox.container itself.
mybox_dropins := env_var_or_default("MYBOX_DROPINS", "05-user 10-gui 20-gpu 30-nvidia 85-publish-ssh")

quadlet_dir := env_var_or_default("XDG_CONFIG_HOME", env_var("HOME") / ".config") / "containers/systemd"
unit := mybox_name + ".service"

default:
    @just --list --unsorted

# Build the base image into your rootless store.
build:
    podman build -t "{{mybox_image}}" "{{mybox_dir}}"

# Build the gaming variant on top of the local base.
build-gaming: build
    podman build --build-arg BASE="{{mybox_image}}" -t "{{gaming_image}}" "{{mybox_dir}}/gaming"

# Install the quadlet + chosen drop-ins as a user quadlet, then daemon-reload.
#
# COPIES, not symlinks: an isolated account cannot read your working tree,
# and a copy keeps the box independent of whatever branch is checked out.
# `just sync` pushes later repo edits.
#
# Name drop-ins to override the default set:
#   just install 01-boot 02-gaming 20-gpu 30-nvidia
install *dropins:
    #!/usr/bin/env bash
    set -euo pipefail
    SRC="{{mybox_dir}}"; QD="{{quadlet_dir}}"; DIR="$QD/{{mybox_name}}.container.d"
    LIST="{{dropins}}"; [[ -z "$LIST" ]] && LIST="{{mybox_dropins}}"
    for d in $LIST; do
      [[ -f "$SRC/container/$d.conf" ]] || { echo "ERROR: no drop-in container/$d.conf" >&2; exit 1; }
    done
    mkdir -p "$DIR"
    install -m0644 "$SRC/mybox.container" "$QD/{{mybox_name}}.container"
    for d in $LIST; do
      install -m0644 "$SRC/container/$d.conf" "$DIR/$d.conf"
    done
    # Declarative: drop what is no longer in LIST. "Ours" is decided by
    # name — hand-written local drop-ins have no counterpart in container/
    # and are left alone.
    for f in "$DIR"/*.conf; do
      [[ -e "$f" ]] || continue
      b=$(basename "$f" .conf)
      [[ -f "$SRC/container/$b.conf" ]] || continue
      grep -qw -- "$b" <<<"$LIST" || { echo "    removing stale drop-in: $b"; rm -f "$f"; }
    done
    systemctl --user daemon-reload
    echo ">>> installed $QD/{{mybox_name}}.container"
    echo "    drop-ins: $LIST"
    echo "    start:    just start"

# Re-copy the installed unit files from this repo (apply repo edits),
# without changing which drop-ins are selected.
sync:
    #!/usr/bin/env bash
    set -euo pipefail
    SRC="{{mybox_dir}}"; QD="{{quadlet_dir}}"; DIR="$QD/{{mybox_name}}.container.d"
    [[ -e "$QD/{{mybox_name}}.container" ]] || { echo "ERROR: {{mybox_name}} is not installed — run: just install" >&2; exit 1; }
    install -m0644 "$SRC/mybox.container" "$QD/{{mybox_name}}.container"
    for f in "$DIR"/*.conf; do
      [[ -e "$f" ]] || continue
      b=$(basename "$f" .conf)
      [[ -f "$SRC/container/$b.conf" ]] && install -m0644 "$SRC/container/$b.conf" "$f"
    done
    systemctl --user daemon-reload

# Start the box — systemd creates the container from the image.
start:
    systemctl --user start "{{unit}}"

# Stop the box — systemd removes the container; the state survives.
stop:
    systemctl --user stop "{{unit}}"

# Re-copies first, so edit-then-restart applies the edit.
#
# Recreate against the current image + drop-ins.
restart: sync
    systemctl --user restart "{{unit}}"

# Unit and container state.
status:
    -systemctl --user show "{{unit}}" -p ActiveState -p SubState -p ActiveEnterTimestamp
    -podman ps -a --filter "name=^{{mybox_name}}$" --format 'table {{{{.Names}}\t{{{{.Status}}\t{{{{.Image}}'

# Follow the unit journal.
logs:
    journalctl --user -f -u "{{unit}}"

# Fast shell as USER (podman exec, no PAM session).
# `runuser` inside, not `podman exec -u <name>`: podman resolves a user
# NAME against the image's /etc/passwd as seen from the host, and the image
# bakes no user — the account lives in the /etc overlay, which only exists
# inside the container's mount namespace.
enter user=mybox_username:
    podman exec -it {{mybox_name}} runuser -u "{{user}}" -- /usr/bin/fish -l

# Full PAM/logind session as USER (login -f, empty-password user).
login user=mybox_username:
    podman exec -it {{mybox_name}} login -f "{{user}}"
