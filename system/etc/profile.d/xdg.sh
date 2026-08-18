# shellcheck shell=sh
# XDG_RUNTIME_DIR for sessions that PAM did not set up.
#
# `podman exec` (just enter) gives a bare process with no PAM and no
# logind session, so XDG_RUNTIME_DIR is unset and everything keyed off
# it — the Wayland/PipeWire/Pulse sockets mybox-host-sockets links
# there, rootless podman's runtime root — silently looks in the wrong
# place. A full login (just login) gets it from pam_systemd; this fills
# the gap for the rest.
#
# Derived from `id -u`, never hardcoded: the runtime user's uid is
# configurable through MYBOX_UID.
if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
    XDG_RUNTIME_DIR="/run/user/$(id -u)"
    export XDG_RUNTIME_DIR
fi
