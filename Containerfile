# =====================================================================
# mybox — minimal OCI "machine" container (Arch Linux base).
# =====================================================================
#
# Why Arch (vs Fedora):
#   * Rolling release — latest upstream package versions, no waiting
#     for a Fedora release cycle.
#   * Single `pacman` syntax shared with our gaming / dev variants.
#   * Smaller base image (~150 MiB) than Fedora's `:latest`.
#
# Build:
#   podman build -t localhost/mybox:latest ~/mybox
#
# The image bakes NO login user — one generic image serves any box.
# mybox-user-setup.service creates the user at boot from MYBOX_USER /
# MYBOX_UID / MYBOX_GID / MYBOX_SHELL env vars (quadlet Environment=
# drop-in, EnvironmentFile=/srv/<name>/container.env, or `-e` flags);
# defaults user/1000/1000/fish.
#
# /etc factory tree (myosi pattern):
#   1. system/etc/* is COPY'd onto pacman's freshly-installed /etc as
#      our overrides (drop-ins, locale config).
#   2. User setup, sudoers, masking, preset are applied — every write
#      lands in /etc.
#   3. Final RUN snapshots the now-populated /etc and /var to
#      /usr/share/factory/{etc,var} as the immutable factory trees
#      (systemd's standard factory location). /etc stays populated, so
#      the default (no bind) container works out of the box.
#   4. mybox-etc-seed.service repopulates /etc from the factory ONLY
#      when /etc is empty (user bind-mounted an empty volume).
#      Same `ConditionDirectoryNotEmpty=!/etc` pattern as
#      myosi-etc-seed.service.
# =====================================================================

FROM docker.io/archlinux:base

# ---------------------------------------------------------------------
# Sync repos + install. archlinux:base ships:
#   bash, coreutils, util-linux, shadow, sudo, gawk, sed, grep, less,
#   tar, gzip, xz, zstd, file, findutils, iputils, libgcc, e2fsprogs,
#   ncurses, ca-certificates, AND systemd 260+ (verified).
#
# `systemd` is listed explicitly below for clarity, --needed makes it
# a no-op when already present.
#
# Categories:
#   service stack   systemd + polkit + dbus-broker + sshd
#   shell + scm     fish + git + just + curl
#   modern cli      eza/bat/ripgrep/fzf/fd/zoxide/starship
#                   /btop/ncdu/jq/tree/tmux/neovim
#   archive         rsync, unzip
#   rootless podman podman/buildah/skopeo + crun + fuse-overlayfs +
#                   slirp4netns + passt + netavark/aardvark-dns for
#                   nested containers.
# ---------------------------------------------------------------------
RUN pacman-key --init && \
    pacman -Syu --noconfirm --needed && \
    pacman -S  --noconfirm --needed \
        systemd polkit dbus-broker openssh sudo \
        fish git just curl \
        eza bat ripgrep fzf fd zoxide starship \
        btop ncdu jq tree tmux neovim \
        rsync unzip \
        podman buildah skopeo crun fuse-overlayfs slirp4netns passt \
        netavark aardvark-dns \
        flatpak xdg-utils \
        age atuin dust lazygit zellij diffnav && \
    pacman -Scc --noconfirm && \
    rm -rf /var/cache/pacman/pkg/* /var/log/* /tmp/* \
           /usr/share/doc /usr/share/info && \
    find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
         ! -name 'en*' -exec rm -rf {} +

# ---------------------------------------------------------------------
# Layer mybox overrides on top of pacman's freshly-installed /etc.
# system/etc/* contains drop-ins (sshd, systemd PID 1) + locale config
# that packages don't own. Order matters: this RUNS AFTER pacman so
# nothing pacman ships clobbers our drop-ins.
#
# system/usr/* ships the etc-seed service + the preset file under /usr.
# ---------------------------------------------------------------------
COPY system/etc /etc
COPY system/usr /usr
RUN chmod +x /usr/libexec/mybox/flatpak-setup /usr/libexec/mybox/link-host-sockets \
             /usr/libexec/mybox/user-setup /usr/libexec/mybox/usr-overlay

# ---------------------------------------------------------------------
# mybox CLI + recipes + GUI environment are baked into the image as
# part of system/ (COPY system/usr → /usr, COPY system/etc → /etc
# above). No separate COPY lines needed:
#
#   system/usr/local/bin/mybox             → /usr/local/bin/mybox
#   system/usr/share/mybox/just/*.just     → /usr/share/mybox/just/
#   system/etc/environment.d/gui.conf      → /etc/environment.d/gui.conf
#
# For live-recipe development, override via a runtime bind-mount
# (Volume= in a container.d drop-in, or :readonly on incus/nspawn).
# ---------------------------------------------------------------------
RUN chmod +x /usr/local/bin/mybox

# Locale — config came in via /etc/locale.{conf,gen} above.
RUN locale-gen
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# ---------------------------------------------------------------------
# NO baked user. mybox-user-setup.service (enabled via preset) creates
# the login user at boot from MYBOX_USER / MYBOX_UID / MYBOX_GID /
# MYBOX_SHELL env vars — wheel + NOPASSWD sudo, empty password (auth
# runs through ssh keys on port 2222 or `podman exec`), and APPENDS its
# subuid/subgid range so pre-existing ranges survive. See
# system/usr/libexec/mybox/user-setup.
#
# Rootless-podman prereq that stays build-time: setcap on newuidmap /
# newgidmap (xattrs preserved by podman build).
# ---------------------------------------------------------------------
RUN setcap cap_setuid+ep /usr/bin/newuidmap && \
    setcap cap_setgid+ep /usr/bin/newgidmap

# ---------------------------------------------------------------------
# Apply mybox preset (50-mybox.preset) to wire enable / disable for
# every unit. Pre-create machine-id so systemd doesn't generate one
# at first boot (would fail under a persistent /var overlay).
# ---------------------------------------------------------------------
RUN systemctl preset-all && \
    systemd-machine-id-setup

# User linger (user@<UID>.service → /run/user/<UID> + user D-Bus
# at boot, so nested rootless `podman exec -u user` doesn't hit
# "RunRoot not writable") is enabled at RUNTIME by mybox-linger.service.
# A build-time /var/lib/systemd/linger/<user> marker does NOT survive:
# systemd-logind.service declares StateDirectory=systemd/linger, so
# logind re-provisions that dir on start and drops the marker. The
# boot oneshot runs `loginctl enable-linger` after logind instead.

# ---------------------------------------------------------------------
# Mask units preset can only `disable` (preset can't truly mask).
# These belong to the host kernel / hardware management; never useful
# inside a container. Masking = symlink to /dev/null under
# /etc/systemd/system.
# ---------------------------------------------------------------------
RUN for u in \
        systemd-firstboot.service \
        systemd-hwdb-update.service \
        systemd-tmpfiles-setup-dev.service \
        systemd-binfmt.service \
        systemd-machine-id-commit.service \
        systemd-modules-load.service \
        systemd-sysctl.service \
        systemd-udevd.service \
        systemd-udevd-control.socket \
        systemd-udevd-kernel.socket \
        systemd-udev-trigger.service \
        dev-hugepages.mount \
        sys-kernel-config.mount \
        sys-fs-fuse-connections.mount \
        sys-kernel-debug.mount \
        sys-kernel-tracing.mount \
        proc-sys-fs-binfmt_misc.automount; do \
        ln -sf /dev/null /etc/systemd/system/$u; \
    done

# ---------------------------------------------------------------------
# Mask ostree-system-generator (pulled in as a flatpak → ostree dep).
# On a non-ostree host it still runs at boot and generates a bogus
# `var.mount` that binds /var to /sysroot/ostree/deploy/default/var —
# mounting an empty overlay OVER the image's /var and hiding EVERYTHING
# under it: the pacman database (→ no in-container package installs,
# `mybox install-nvidia` fails with "could not find or read directory
# dbpath /var/lib/pacman"), the user linger marker, etc. mybox is
# never ostree-booted, so the generator is pure breakage here. Mask via
# the generator override dir (systemd honours <dir>/<gen> → /dev/null).
RUN mkdir -p /etc/systemd/system-generators && \
    ln -sf /dev/null /etc/systemd/system-generators/ostree-system-generator

# ---------------------------------------------------------------------
# Root's home → /var/roothome (ostree-style symlink) so root state
# rides the persistent /var bind like everything else.
# ---------------------------------------------------------------------
RUN mkdir -p /var/roothome && \
    cp -a /root/. /var/roothome/ && \
    chmod 0700 /var/roothome && \
    rm -rf /root && ln -s var/roothome /root

# ---------------------------------------------------------------------
# Freeze the populated /etc and /var as the immutable factory trees:
#   /etc → /usr/share/factory/etc   (mybox-etc-seed.service)
#   /var → /usr/share/factory/var   (mybox-var-seed.service)
# ONE pattern for both — and /usr/share/factory/ is the systemd-blessed
# factory location (systemd-tmpfiles `C` lines copy from it by
# default). FINAL steps before the image is sealed so the factories
# capture every drop-in, mask symlink, preset state and the pacman
# database.
#
# /etc and /var stay populated alongside their factories — the default
# (no bind) container runs straight from them and both seed services
# are no-ops (ConditionDirectoryNotEmpty=!). The seeds only fire when a
# persistent bind is mounted EMPTY, repopulating it on first boot.
# ---------------------------------------------------------------------
# rm first: Arch's `filesystem` package already ships a skeleton
# /usr/share/factory/etc — cp'ing onto it would nest our tree at
# factory/etc/etc and the seeds would deliver the 26-file skeleton
# instead (no machine-id → firstboot fires, skeleton pam.d → user@
# fails at PAM). Our full snapshot supersedes it.
RUN rm -rf /usr/share/factory/etc /usr/share/factory/var && \
    mkdir -p /usr/share/factory && \
    cp -a /etc /usr/share/factory/etc && \
    cp -a /var /usr/share/factory/var

LABEL org.opencontainers.image.title="mybox" \
      org.opencontainers.image.description="Minimal Arch Linux systemd-PID-1 OCI machine" \
      org.opencontainers.image.source="https://github.com/aboglioli/mybox" \
      org.opencontainers.image.licenses="MIT" \
      io.containers.autoupdate="registry"

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
