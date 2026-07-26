# mybox — minimal Arch Linux OCI machine image (systemd PID 1).
#
# Arch over Fedora: rolling release, single pacman syntax across
# variants, smaller base. The image bakes NO login user — one public
# image serves any box; mybox-user-setup.service creates the user at
# boot from MYBOX_* env (see container/05-user.conf).
#
# /etc factory pattern: pacman populates /etc, system/etc overlays our
# drop-ins, then the final RUN snapshots /etc and /var to
# /usr/share/factory/{etc,var}. The default container runs straight from
# the live trees; mybox-{etc,var}-seed.service repopulate a persistent
# bind only when it is mounted empty.

FROM docker.io/archlinux:base

# systemd is already in archlinux:base; --needed makes it a no-op.
# Groups: service stack / shell+scm / modern cli / nested podman /
# flatpak / extras.
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

# Overlay our config AFTER pacman so nothing clobbers the drop-ins.
COPY system/etc /etc
COPY system/usr /usr
RUN chmod +x /usr/libexec/mybox/flatpak-setup /usr/libexec/mybox/link-host-sockets \
             /usr/libexec/mybox/user-setup /usr/libexec/mybox/usr-overlay \
             /usr/local/bin/mybox

RUN locale-gen
ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# Rootless-podman prereq (xattrs survive podman build).
RUN setcap cap_setuid+ep /usr/bin/newuidmap && \
    setcap cap_setgid+ep /usr/bin/newgidmap

# Wire units via 50-mybox.preset; pre-create machine-id so first boot
# doesn't generate one (would fail under a persistent /var overlay).
RUN systemctl preset-all && \
    systemd-machine-id-setup

# User linger is enabled at RUNTIME by mybox-linger.service — a
# build-time /var/lib/systemd/linger marker is dropped by logind's
# StateDirectory re-provisioning.

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
# generates a bogus var.mount that hides the image's /var (pacman db,
# linger marker). mybox is never ostree-booted.
RUN mkdir -p /etc/systemd/system-generators && \
    ln -sf /dev/null /etc/systemd/system-generators/ostree-system-generator

# Root's home → /var/roothome so root state rides the persistent /var.
RUN mkdir -p /var/roothome && \
    cp -a /root/. /var/roothome/ && \
    chmod 0700 /var/roothome && \
    rm -rf /root && ln -s var/roothome /root

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
