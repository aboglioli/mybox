# mybox — build the images and drive the quadlet. Everything about how
# the container is composed lives in mybox@.container + container/*.conf;
# this file only builds, installs the unit files and gets you a shell.
# The container is disposable (recreated on every restart/boot); state
# persists under /srv/users/<uid>/<name>, which mybox@.container binds at
# /.mybox and the pre-init turns into an overlay upper for each tree.
#
# Every box is an instance of the template: `name` below is its unit
# (mybox@<name>.service), hostname, container name and state directory.
#
# Rootless throughout: run every recipe as the account that owns the box
# — yourself, or the isolated account (README "Isolated box"). No sudo.

set shell := ["bash", "-euo", "pipefail", "-c"]

mybox_dir := justfile_directory()

# Must match Image= in mybox@.container. A
# local build tags over the published reference in YOUR rootless store,
# which is the store your user quadlet reads.
mybox_image := env_var_or_default("MYBOX_IMAGE", "ghcr.io/aboglioli/mybox:latest")

# Default box name for every recipe that takes one.
mybox_name := env_var_or_default("MYBOX_NAME", "mybox")

# Default user for `enter` / `login` (created at boot by
# mybox-user-setup.service from MYBOX_* env).
mybox_username := env_var_or_default("MYBOX_USERNAME", "user")

# Default drop-in set for `just install`: a desktop box with the GPU, up
# with your user manager and the GUI whenever a session runs.
# Persistence is NOT here — it is part of mybox@.container itself.
mybox_dropins := env_var_or_default("MYBOX_DROPINS", "01-boot 05-user 10-gui 20-gpu 30-nvidia 85-publish-ssh")

config_dir := env_var_or_default("XDG_CONFIG_HOME", env_var("HOME") / ".config")
quadlet_dir := config_dir / "containers/systemd"
host_unit_dir := config_dir / "systemd/user"

default:
    @just --list --unsorted

# Build the base image into your rootless store.
build:
    podman build -t "{{mybox_image}}" "{{mybox_dir}}"

# SYMLINKS into this checkout, so the installed units are always the
# repo's: edit, then `just restart`. Install from the checkout you keep —
# a worktree you later delete leaves dangling links, and switching its
# branch changes the box at the next restart. An isolated account clones
# its own copy (README "Isolated box").
#
# The name doubles as hostname, so it must be one: lowercase letters,
# digits and inner dashes. Name drop-ins to override the default set:
#   just install                               # box `mybox`, default set
#   just install dev                           # box `dev`, default set
#   just install games 01-boot 20-gpu 30-nvidia
#
# With 10-gui it also installs and enables host/mybox-gui.service, the
# host user unit that shares the desktop session's sockets with every box.
#
# Install the template + one box with its drop-ins, then daemon-reload.
install name=mybox_name *dropins:
    #!/usr/bin/env bash
    set -euo pipefail
    NAME="{{name}}"
    [[ "$NAME" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] ||
      { echo "ERROR: '$NAME' is not a valid hostname (a-z, 0-9, inner dashes, ≤63)" >&2; exit 1; }
    SRC="{{mybox_dir}}"; QD="{{quadlet_dir}}"; DIR="$QD/mybox@$NAME.container.d"
    LIST="{{dropins}}"; [[ -z "$LIST" ]] && LIST="{{mybox_dropins}}"
    for d in $LIST; do
      [[ -f "$SRC/container/$d.conf" ]] || { echo "ERROR: no drop-in container/$d.conf" >&2; exit 1; }
    done
    mkdir -p "$DIR"
    ln -sfn "$SRC/mybox@.container" "$QD/mybox@.container"
    ln -sfn mybox@.container "$QD/mybox@$NAME.container"
    for d in $LIST; do
      ln -sfn "$SRC/container/$d.conf" "$DIR/$d.conf"
    done
    # Declarative: drop what is no longer in LIST. "Ours" is decided by
    # name — hand-written local drop-ins have no counterpart in container/
    # and are left alone.
    for f in "$DIR"/*.conf; do
      [[ -e "$f" || -L "$f" ]] || continue
      b=$(basename "$f" .conf)
      [[ -f "$SRC/container/$b.conf" ]] || continue
      grep -qw -- "$b" <<<"$LIST" || { echo "    removing stale drop-in: $b"; rm -f "$f"; }
    done
    # 10-gui needs the host side that shares the session's sockets. One
    # unit serves every box of this account, so it stays while any
    # installed box still has 10-gui.
    if grep -qw -- 10-gui <<<"$LIST"; then
      mkdir -p "{{host_unit_dir}}"
      ln -sfn "$SRC/host/mybox-gui.service" "{{host_unit_dir}}/mybox-gui.service"
      systemctl --user daemon-reload
      systemctl --user enable mybox-gui.service
      if systemctl --user is-active -q graphical-session.target; then
        systemctl --user restart mybox-gui.service
      fi
    elif ! compgen -G "$QD/*.container.d/10-gui.conf" >/dev/null; then
      systemctl --user disable --now mybox-gui.service 2>/dev/null || true
      rm -f "{{host_unit_dir}}/mybox-gui.service"
    fi
    systemctl --user daemon-reload
    echo ">>> installed mybox@$NAME (state: /srv/users/$(id -u)/$NAME)"
    echo "    drop-ins: $LIST"
    echo "    start:    just start $NAME"

# Repoints every installed link at this checkout (and turns copies from
# older installs into links), keeping which drop-ins each box selects.
#
# Relink the template, every box's drop-ins and the host unit, then daemon-reload.
sync:
    #!/usr/bin/env bash
    set -euo pipefail
    SRC="{{mybox_dir}}"; QD="{{quadlet_dir}}"; HU="{{host_unit_dir}}/mybox-gui.service"
    [[ -e "$QD/mybox@.container" || -L "$QD/mybox@.container" ]] ||
      { echo "ERROR: mybox is not installed — run: just install" >&2; exit 1; }
    ln -sfn "$SRC/mybox@.container" "$QD/mybox@.container"
    for f in "$QD"/mybox@*.container.d/*.conf; do
      [[ -e "$f" || -L "$f" ]] || continue
      b=$(basename "$f" .conf)
      [[ -f "$SRC/container/$b.conf" ]] && ln -sfn "$SRC/container/$b.conf" "$f"
    done
    if [[ -e "$HU" || -L "$HU" ]]; then
      ln -sfn "$SRC/host/mybox-gui.service" "$HU"
    fi
    systemctl --user daemon-reload

# Start a box — systemd creates the container from the image.
start name=mybox_name:
    systemctl --user start "mybox@{{name}}.service"

# Stop a box — systemd removes the container; the state survives.
stop name=mybox_name:
    systemctl --user stop "mybox@{{name}}.service"

# Syncs first, so edit-then-restart applies the edit.
#
# Recreate a box against the current image + drop-ins.
restart name=mybox_name: sync
    systemctl --user restart "mybox@{{name}}.service"

# Unit and container state of every installed box.
status:
    #!/usr/bin/env bash
    set -uo pipefail
    printf '%-20s %-10s %s\n' BOX UNIT CONTAINER
    for f in "{{quadlet_dir}}"/mybox@?*.container; do
      [[ -e "$f" ]] || continue
      name=$(basename "$f" .container); name=${name#mybox@}
      state=$(systemctl --user is-active "mybox@$name.service")
      ctr=$(podman ps -a --filter "name=^$name$" --format '{{{{.Status}}  {{{{.Image}}')
      printf '%-20s %-10s %s\n' "$name" "$state" "${ctr:--}"
    done

# Follow a box's unit journal.
logs name=mybox_name:
    journalctl --user -f -u "mybox@{{name}}.service"

# `runuser` inside, not `podman exec -u <user>`: podman resolves a user
# NAME against the image's /etc/passwd as seen from the host, and the image
# bakes no user — the account lives in the /etc overlay, which only exists
# inside the container's mount namespace.
#
# Fast shell as USER (podman exec, no PAM session).
enter name=mybox_name user=mybox_username:
    podman exec -it "{{name}}" runuser -u "{{user}}" -- /usr/bin/fish -l

# Full PAM/logind session as USER (login -f, empty-password user).
login name=mybox_name user=mybox_username:
    podman exec -it "{{name}}" login -f "{{user}}"
