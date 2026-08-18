# XDG_RUNTIME_DIR for fish sessions that PAM did not set up — the fish
# half of /etc/profile.d/xdg.sh. `podman exec` (just enter) gives a bare
# process with no PAM and no logind session, so XDG_RUNTIME_DIR is unset
# and everything keyed off it (the Wayland/PipeWire/Pulse links
# mybox-host-sockets makes, rootless podman's runtime root) resolves
# wrong.
#
# Derived from `id -u`, never hardcoded: MYBOX_UID is configurable.
#
# Its OWN file, deliberately. fish resolves conf.d by BASENAME with the
# user's ~/.config/fish/conf.d winning over /etc/fish/conf.d, so
# anything added to a file a user might also have — 90-environment.fish
# is exactly that — is silently dead on any box carrying their own copy.
# A name the image alone uses cannot be shadowed by accident.

set -q XDG_RUNTIME_DIR; or set -gx XDG_RUNTIME_DIR /run/user/(id -u)
