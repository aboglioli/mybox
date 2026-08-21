# mybox — minimal Arch Linux OCI machine image (systemd PID 1).
#
# Arch over Fedora: rolling release, single pacman syntax across
# variants, smaller base. The image bakes NO login user — one public
# image serves any box; mybox-user-setup.service creates the user at
# boot from MYBOX_* env (see container/05-user.conf).
#
# The image's /etc and /var are the LOWER layers of the overlays that
# /usr/libexec/mybox/preinit assembles at boot, so they are the live
# content of every box rather than a template to copy — nothing seeds
# anything. /usr/share/factory/{etc,var} is still snapshotted because
# systemd's own tmpfiles.d copies from it, and it stays a useful
# reference to diff a box against.

FROM docker.io/archlinux:base

# systemd is already in archlinux:base; --needed makes it a no-op.
# Groups: service stack / shell+scm / modern cli / nested podman /
# flatpak / extras.
# Nested podman is crun + pasta + netavark; slirp4netns is gone
# (podman 6 removed it) and buildah/skopeo are vendored into podman.
# fuse-overlayfs stays ONLY as the storage fallback for ephemeral runs:
# without a persistent /var bind the nested graphroot sits on the
# container's own overlay rootfs, and the kernel refuses native
# overlay-on-overlay.
RUN pacman-key --init && \
    pacman -Syu --noconfirm --needed && \
    pacman -S  --noconfirm --needed \
        systemd polkit dbus-broker openssh sudo \
        fish git just curl \
        eza bat ripgrep fzf fd zoxide starship \
        btop ncdu jq tree tmux neovim \
        rsync unzip diffutils \
        podman crun fuse-overlayfs passt \
        netavark aardvark-dns \
        flatpak xdg-utils \
        age atuin dust lazygit zellij diffnav && \
    pacman -Scc --noconfirm && \
    rm -rf /var/cache/pacman/pkg/* /var/log/* /tmp/* \
           /usr/share/doc /usr/share/info && \
    find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
         ! -name 'en*' -exec rm -rf {} + && \
    rm -rf /usr/include /usr/lib/pkgconfig /usr/share/pkgconfig /usr/lib/cmake && \
    find /usr -name '*.a' -type f -delete

# Build-time-only payload, dropped above: headers, static archives and
# pkg-config/cmake metadata are ~130 MB of a ~1.4 GB image and the image
# ships no compiler, so nothing here can consume them. install-nvidia is
# unaffected — it runs the .run with --no-kernel-modules, i.e. no toolchain.
#
# The trade: if you later install a compiler INSIDE, headers for packages
# that are already installed are gone. `pacman -S <pkg>` reinstalls them.
# Kept on purpose: /usr/share/i18n (locale-gen needs it to add a locale
# later), terminfo and zoneinfo (both runtime data).

# Overlay our config AFTER pacman so nothing clobbers the drop-ins.
COPY system/etc /etc
COPY system/usr /usr
RUN chmod +x /usr/libexec/mybox/flatpak-setup /usr/libexec/mybox/link-host-sockets \
             /usr/libexec/mybox/preinit /usr/libexec/mybox/user-setup \
             /usr/local/bin/mybox && \
    mkdir -p /.mybox

RUN locale-gen
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Rootless-podman prereq (xattrs survive podman build).
RUN setcap cap_setuid+ep /usr/bin/newuidmap && \
    setcap cap_setgid+ep /usr/bin/newgidmap

# Wire units via 50-mybox.preset; pre-create machine-id so first boot
# doesn't generate one (would fail under a persistent /var overlay).
#
# --global enable is the user-scope equivalent: it writes symlinks into
# /etc/systemd/user/, which the factory snapshot below carries, so every
# session gets them with no per-user `systemctl --user enable`. Listed
# explicitly rather than via `--global preset-all`, which pulls in the
# whole vendor set (podman.service, podman-auto-update.timer, p11-kit…)
# that this image deliberately leaves off.
#
#   podman.socket / podman-restart.service  rootless API socket +
#       resume of the user's --restart=always containers after a boot
#   mybox-host-sockets / mybox-xwayland     GUI wiring; both self-gate
#       on Condition= so they are clean no-ops in a headless container
#
# pipewire.socket is DISABLED for the opposite reason. pipewire arrives
# as a dependency and its package enables the socket globally, but the
# usual mybox GUI (10-gui.conf) is a CLIENT of the host's pipewire: the
# host sockets are bind-mounted at /mnt/host and linked into
# XDG_RUNTIME_DIR, and a nested daemon racing to create its own
# pipewire-0 there shadows them — silence, intermittently. A
# compositor-INSIDE container (50-desktop.conf) enables it explicitly.
#
# systemd-sysusers runs HERE, at build time, so the users and groups
# mybox declares are already in the /etc that every box overlays. The
# overlay makes ConditionNeedsUpdate=/etc work again at runtime (the
# new /usr lower postdates the upper's stamp), so this is now belt and
# braces rather than the only path — but it keeps a first boot from
# depending on that condition firing.
RUN systemctl preset-all && \
    systemctl --global enable podman.socket podman-restart.service \
                              mybox-host-sockets.service mybox-xwayland.service && \
    systemctl --global disable pipewire.socket pipewire.service && \
    systemd-sysusers && \
    systemd-machine-id-setup

# User linger is enabled at RUNTIME by mybox-user-setup (it knows the
# configured user name) — a build-time /var/lib/systemd/linger marker
# cannot, and is dropped by logind's StateDirectory re-provisioning.

# Mask host-kernel/hardware units preset can only disable.
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

# Mask ostree-system-generator (flatpak → ostree dep): on boot it
# generates a bogus var.mount that hides the image's /var (linger
# marker, flatpak state). mybox is never ostree-booted.
RUN mkdir -p /etc/systemd/system-generators && \
    ln -sf /dev/null /etc/systemd/system-generators/ostree-system-generator

# Root's home → /var/roothome so root state rides the persistent /var.
RUN mkdir -p /var/roothome && \
    cp -a /root/. /var/roothome/ && \
    chmod 0700 /var/roothome && \
    rm -rf /root && ln -s var/roothome /root

# Pacman db lives in /usr (SteamOS-style): the db that describes the
# image's packages travels WITH the image, and runtime installs write
# both files and db entries into the same /usr overlay upperdir — the
# two can never desync across a rebase (a persistent /var db goes stale
# the moment a new image swaps the /usr lower, and every pacman install
# then dies on "conflicting files"). /var/lib/pacman stays reachable as
# a symlink recreated every boot by tmpfiles.d/mybox.conf, so the
# stock pacman.conf DBPath keeps working.
RUN mv /var/lib/pacman /usr/lib/pacman && \
    ln -s ../../usr/lib/pacman /var/lib/pacman

# Freeze /etc and /var as factory trees. rm first: Arch's `filesystem`
# package ships a skeleton /usr/share/factory/etc — cp'ing onto it would
# nest our tree and the seeds would deliver the broken skeleton.
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
