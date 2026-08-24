# mybox — build the image and drive the quadlet. Everything about how
# the container is composed lives in mybox.container + container/*.conf;
# this file only builds, installs the unit files and gets you a shell.
# The container is disposable (recreated on every restart/boot); state
# persists under /srv/<name>, which mybox.container binds at /.mybox and
# the pre-init turns into an overlay upper for each image-owned tree.

set shell := ["bash", "-euo", "pipefail", "-c"]

mybox_dir := justfile_directory()

# Must match Image= in mybox.container — the published ghcr reference.
# `just build` tags a LOCAL build over it in the ROOTFUL store (the
# system quadlet reads that store; a rootless build is invisible to it).
# Skipping `just build` makes the quadlet pull the published image.
mybox_image := env_var_or_default("MYBOX_IMAGE", "ghcr.io/aboglioli/mybox:latest")

# Unit name: <name>.container → <name>.service, state at /srv/<name>.
mybox_name := env_var_or_default("MYBOX_CONTAINER", "mybox")

# Default user for `enter` / `login` (created at boot by
# mybox-user-setup.service from MYBOX_* env).
mybox_username := env_var_or_default("MYBOX_USERNAME", "user")

# Network: read OUT of mybox.container, not configured here. That file
# already names the network it wants, so copying it by hand is a complete
# install with nothing left to generate. To switch from mybox-nat.network
# (podman bridge + NAT, works anywhere) to mybox-lan.network (macvlan — the
# container is its own host on the LAN), edit that one Network= line.
mybox_netfile := `sed -n 's/^Network=//p' mybox.container | tail -1`

# Default drop-in set for `just install`. Persistence is NOT here —
# /srv/<name>/{etc,var,home,srv} is part of mybox.container itself and
# cannot be opted out of. 31-nvidia-raw vs 30-nvidia (CDI): pick
# exactly ONE — both would pass the devices twice.
mybox_dropins := env_var_or_default("MYBOX_DROPINS", "05-user 10-gui 20-gpu 31-nvidia-raw 85-publish-ssh")

quadlet_dir := "/etc/containers/systemd"

# Two mutually exclusive instances of ONE template. Both are <name>, so
# they share /srv/<name>, the container name and every drop-in in
# <name>@.container.d; only <name>@gui.container.d/10-gui.conf differs.
headless := mybox_name + "@headless.service"
gui := mybox_name + "@gui.service"

default:
    @just --list --unsorted

# Build the OCI image into the rootful store.
build:
    @echo ">>> building {{mybox_image}}"
    sudo podman build -t "{{mybox_image}}" "{{mybox_dir}}"
    @echo ">>> done. apply with: just restart"

# Install quadlet + network + drop-ins into /etc/containers/systemd.
#
# COPIES, not symlinks: generators run before any mount, so a link into
# /home is unreadable at boot and NO unit is generated. Use `just sync`
# to push repo edits afterwards.
#
# Name drop-ins to override the default set:
#   just install 05-user 10-gui 31-nvidia-raw
#
# Copy quadlet + network + drop-ins to /etc, wire the start trigger.
install *dropins:
    #!/usr/bin/env bash
    set -euo pipefail
    SRC="{{mybox_dir}}"; NAME="{{mybox_name}}"; QD="{{quadlet_dir}}"
    NETFILE="{{mybox_netfile}}"
    [[ -n "$NETFILE" ]] || { echo "ERROR: mybox.container has no Network= line" >&2; exit 1; }
    LIST="{{dropins}}"; [[ -z "$LIST" ]] && LIST="{{mybox_dropins}}"
    for d in $LIST; do
      [[ -f "$SRC/container/$d.conf" ]] || { echo "ERROR: no drop-in container/$d.conf" >&2; exit 1; }
    done
    # 10-gui is the one drop-in that is NOT shared: it belongs to the gui
    # instance alone, because its bind sources are session sockets that do
    # not exist at boot. QLIST is the shared set; GUI adds the instance.
    GUI=0; QLIST=""
    for d in $LIST; do
      if [[ "$d" == "10-gui" ]]; then GUI=1; else QLIST="$QLIST $d"; fi
    done
    BASE="$QD/$NAME@.container.d"; GUID="$QD/$NAME@gui.container.d"
    sudo mkdir -p "$BASE"
    # Superseded by the two instances; a leftover would start a third
    # container on the same /srv state.
    sudo rm -rf "$QD/$NAME.container" "$QD/$NAME.container.d"
    # rm first: install(1) follows an existing symlink and would truncate
    # its target - i.e. clobber this repo on a box installed by the old
    # symlinking version of this recipe.
    sudo rm -f "$BASE/00-base.conf" "$QD/$NAME@headless.container" "$QD/$NETFILE"
    # The shared definition is a DROP-IN, not a unit file: a drop-in dir is
    # the only thing two instances of a template both read.
    sudo install -m0644 "$SRC/mybox.container" "$BASE/00-base.conf"
    sudo install -m0644 "$SRC/mybox@headless.container" "$QD/$NAME@headless.container"
    sudo install -m0644 "$SRC/container/$NETFILE" "$QD/$NETFILE"
    # Left over from when this recipe generated a Network= drop-in. The
    # base file names its own network now, so this would only duplicate it.
    sudo rm -f "$BASE/00-network.conf"
    for d in $QLIST; do
      sudo rm -f "$BASE/$d.conf"
      sudo install -m0644 "$SRC/container/$d.conf" "$BASE/$d.conf"
    done
    # Declarative: drop what is no longer in LIST. A copy carries no link
    # back to the repo, so "ours" is decided by name — hand-written local
    # drop-ins have no counterpart in container/ and are left alone.
    for f in "$BASE"/*.conf; do
      [[ -e "$f" ]] || continue
      b=$(basename "$f" .conf)
      [[ -f "$SRC/container/$b.conf" ]] || continue
      grep -qw -- "$b" <<<"$QLIST" || { echo "    removing stale drop-in: $b"; sudo rm -f "$f"; }
    done
    # Same for .network files, and not cosmetic: ONE unreadable entry makes
    # the generator abort the whole run, mybox.service included.
    for f in "$QD"/*.network; do
      [[ -e "$f" ]] || continue
      b=$(basename "$f")
      [[ "$b" == "$NETFILE" ]] && continue
      [[ -f "$SRC/container/$b" ]] || continue
      echo "    removing stale network: $b"
      sudo rm -f "$f"
    done
    # The GUI instance exists only on a GUI box: same base, one extra
    # drop-in, plus the .path that swaps the box over at session time.
    if [[ "$GUI" == 1 ]]; then
      sudo mkdir -p "$GUID"
      sudo rm -f "$QD/$NAME@gui.container" "$GUID/10-gui.conf"
      sudo install -m0644 "$SRC/mybox@gui.container" "$QD/$NAME@gui.container"
      sudo install -m0644 "$SRC/container/10-gui.conf" "$GUID/10-gui.conf"
      # Nothing to substitute: the .path takes its target from its own
      # filename and watches a glob, so it is correct as copied.
      sudo rm -f "/etc/systemd/system/$NAME@gui.path"
      sudo install -m0644 "$SRC/host/mybox@gui.path" "/etc/systemd/system/$NAME@gui.path"
      # Superseded name from before the .path derived its own target.
      if [[ -e "/etc/systemd/system/$NAME-gui.path" ]]; then
        sudo systemctl disable --now "$NAME-gui.path" 2>/dev/null || true
        sudo rm -f "/etc/systemd/system/$NAME-gui.path"
      fi
      sudo systemctl daemon-reload
      sudo systemctl enable --now "$NAME@gui.path"
      echo "    instances: $NAME@headless (boot) + $NAME@gui (wayland socket)"
    else
      if [[ -e "$QD/$NAME@gui.container" ]]; then
        echo "    removing GUI instance: $NAME@gui"
        sudo systemctl disable --now "$NAME@gui.path" "$NAME-gui.path" 2>/dev/null || true
        sudo systemctl stop "$NAME@gui.service" 2>/dev/null || true
        sudo rm -f "/etc/systemd/system/$NAME@gui.path" "/etc/systemd/system/$NAME-gui.path" "$QD/$NAME@gui.container"
        sudo rm -rf "$GUID"
      fi
      echo "    instances: $NAME@headless only (boot-start)"
    fi
    sudo systemctl daemon-reload
    echo ">>> installed $NAME@.container.d/00-base.conf"
    echo "    drop-ins: $LIST"
    echo "    start:    just start"

# Recreate the podman network from its .network file.
#
# Quadlet creates a network object only when it is MISSING and never
# reconciles an existing one against the file, so editing a .network — or
# switching to a different one that reuses the name — silently keeps the old
# object. Symptom: the container lands on a subnet the file no longer
# mentions. This deletes it so the next start builds it fresh.
net-reset:
    #!/usr/bin/env bash
    set -euo pipefail
    NETFILE="{{mybox_netfile}}"
    name=$(sed -n 's/^NetworkName=//p' "{{mybox_dir}}/container/$NETFILE")
    netunit="$(basename "$NETFILE" .network)-network.service"
    echo ">>> rebuilding podman network '$name' from $NETFILE"
    sudo systemctl stop "{{gui}}" "{{headless}}" || true
    # The generated network unit is RemainAfterExit=yes, so it stays active
    # after creating the network and would NOT re-run: deleting the network
    # underneath it just leaves the container starting against nothing.
    sudo systemctl stop "$netunit" || true
    sudo podman network rm -f "$name" 2>/dev/null || true
    # Clear the start-rate limit a failed attempt may have tripped.
    sudo systemctl reset-failed "{{gui}}" "{{headless}}" "$netunit" 2>/dev/null || true
    just start
    echo ">>> done:"
    sudo podman network inspect "$name" --format '    {{{{.Name}}  driver={{{{.Driver}}  {{{{range .Subnets}}{{{{.Subnet}} gw {{{{.Gateway}}{{{{end}}'

# With a session up the .path unit would swap to @gui anyway; picking it
# directly avoids starting @headless just to conflict it out.
#
# Start whichever instance fits the box right now.
start:
    #!/usr/bin/env bash
    set -euo pipefail
    if [[ -e "{{quadlet_dir}}/{{mybox_name}}@gui.container" ]]; then
      # Re-arm the trigger first: `just stop` disarms it, and without this
      # the box would never swap again after a stop/start cycle. It fires
      # immediately if a session is already up, so there is nothing to
      # probe here.
      sudo systemctl start "{{mybox_name}}@gui.path"
    fi
    # Skipped by ConditionPathExistsGlob= when a session is up and the
    # trigger above has taken the box.
    sudo systemctl start "{{headless}}"

# Sequential and gui-first on purpose: @gui carries OnSuccess=@headless, so
# stopping it hands the box back, and @headless has to be stopped after
# that. Disarming the .path first stops a live session re-triggering @gui.
#
# Stop the box — systemd removes the container; /srv state survives.
stop:
    -sudo systemctl stop "{{mybox_name}}@gui.path"
    -sudo systemctl stop "{{gui}}"
    sudo systemctl stop "{{headless}}"

# Refresh what is already installed, without changing which drop-ins are
# selected — safe on a box whose set differs from the default below.
#
# Re-copy installed unit files from this repo (apply repo edits).
sync:
    #!/usr/bin/env bash
    set -euo pipefail
    SRC="{{mybox_dir}}"; NAME="{{mybox_name}}"; QD="{{quadlet_dir}}"
    BASE="$QD/$NAME@.container.d"; GUID="$QD/$NAME@gui.container.d"
    [[ -e "$BASE/00-base.conf" ]] || { echo "ERROR: $NAME is not installed — run: just install" >&2; exit 1; }
    refresh() { sudo rm -f "$2"; sudo install -m0644 "$1" "$2"; echo "    refreshed: ${2#$QD/}"; }
    refresh "$SRC/mybox.container" "$BASE/00-base.conf"
    refresh "$SRC/mybox@headless.container" "$QD/$NAME@headless.container"
    for f in "$BASE"/*.conf; do
      [[ -e "$f" ]] || continue
      b=$(basename "$f" .conf)
      [[ -f "$SRC/container/$b.conf" ]] || continue
      refresh "$SRC/container/$b.conf" "$f"
    done
    for f in "$QD"/*.network; do
      [[ -e "$f" ]] || continue
      b=$(basename "$f")
      [[ -f "$SRC/container/$b" ]] || continue
      refresh "$SRC/container/$b" "$f"
    done
    # ...and the GUI instance, if this box has one.
    if [[ -e "$QD/$NAME@gui.container" ]]; then
      refresh "$SRC/mybox@gui.container" "$QD/$NAME@gui.container"
      refresh "$SRC/container/10-gui.conf" "$GUID/10-gui.conf"
      refresh "$SRC/host/mybox@gui.path" "/etc/systemd/system/$NAME@gui.path"
    fi
    sudo systemctl daemon-reload

# Re-copies first, so edit-then-restart applies the edit.
#
# Recreate against the current image + drop-ins.
# Restarts ONLY the instance that currently holds the box. Never both:
# they share ContainerName, and quadlet adds --replace, so a second
# instance starting while the first is up deletes the first's container
# out from under it. That marks the loser failed, Restart=on-failure
# brings it back 100ms later, it replaces the winner in turn, and the two
# destroy each other in a loop until something is killed by hand.
#
# This is also how you pick up a new wayland socket after restarting the
# compositor within one session.
#
# Re-copies first, so edit-then-restart applies the edit.
restart: sync
    #!/usr/bin/env bash
    set -euo pipefail
    for u in "{{gui}}" "{{headless}}"; do
      if [[ "$(systemctl is-active "$u")" == active ]]; then
        echo ">>> restarting $u"
        sudo systemctl restart "$u"
        exit 0
      fi
    done
    echo ">>> nothing running — use: just start"

# Unit state, container state, LAN IP.
status:
    -systemctl list-units --no-pager --no-legend '{{mybox_name}}@*.service' '{{mybox_name}}@gui.path'
    -sudo podman ps -a --filter "name=^{{mybox_name}}$" --format 'table {{{{.Names}}\t{{{{.Status}}\t{{{{.Networks}}'
    -sudo podman exec {{mybox_name}} ip -o -4 addr show eth0

# Follow the unit journal.
logs:
    journalctl -f -u "{{gui}}" -u "{{headless}}"

# Fast shell as USER (podman exec, no PAM session).
# `runuser` inside, not `podman exec -u <name>`: podman resolves a user
# NAME against the image's /etc/passwd as seen from the host, and the image
# bakes no user — the account lives in the /etc overlay, which only exists
# inside the container's mount namespace. `-u 1000` would work; resolving
# the name in there keeps this recipe taking a name.
enter user=mybox_username:
    sudo podman exec -it {{mybox_name}} runuser -u "{{user}}" -- /usr/bin/fish -l

# Full PAM/logind session as USER (login -f, empty-password user).
login user=mybox_username:
    sudo podman exec -it {{mybox_name}} login -f "{{user}}"
