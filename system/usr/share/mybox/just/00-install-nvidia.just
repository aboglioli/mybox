# Install matched NVIDIA userland inside the container via the
# official .run installer from nvidia.com.
#
# Why a recipe and not the LXC hook:
#   incus's `nvidia.runtime: true` (libnvidia-container) injects only
#   ~75% of the host nvidia .so files and ships no Vulkan ICD / EGL
#   vendor JSON manifests. Driver init fails — Vulkan loader sees the
#   nvidia ICD but vk_icdGetInstanceProcAddr returns NULL for
#   vkCreateInstance, applications fall back to mesa/iGPU. The .run
#   installer drops the complete, matched userland in one shot.
#   mybox.nspawn has no auto-injection at all and hits the same
#   problem.
#
# Why a script and not a systemd oneshot:
#   Driver upgrades on the host (rpmfusion akmod, .run, sysupdate)
#   bump the version periodically. The kernel module is whatever the
#   host loads; in-container userland must match exactly. Re-running
#   this recipe picks up the new version from /sys/module/nvidia/
#   version and lets nvidia-installer upgrade in place — no
#   uninstall, no marker file to delete, no reboot. A first-boot
#   one-shot can't model that lifecycle cleanly.
#
# Upgrade-in-place:
#   nvidia-installer with --silent detects the previously installed
#   version under /usr/share/nvidia/nvidia-uninstaller-data and
#   replaces every file owned by the prior install before laying
#   down the new bits (`Installing 'NVIDIA Accelerated Graphics
#   Driver for Linux-x86_64' (<NEW>)` followed by
#   `An NVIDIA kernel module 'nvidia' appears to already be loaded
#   ... not installing kernel modules` because we pass
#   --no-kernel-modules). Works distro-agnostic — the installer's
#   inventory is its own ledger, not the host package manager's.
#
# Distros covered (via /etc/os-release ID + ID_LIKE fallback):
#   Arch / CachyOS / EndeavourOS / Manjaro
#   Debian / Ubuntu (and *-LTS)
#   Fedora / RHEL / Rocky / Alma
#   openSUSE / SLES
#   Alpine

[group('nvidia')]
install-nvidia:
    #!/usr/bin/env bash
    set -euo pipefail

    if [[ ! -r /sys/module/nvidia/version ]]; then
        echo "no nvidia module visible from container — host driver not loaded?" >&2
        exit 1
    fi

    VER=$(cat /sys/module/nvidia/version)
    LIB=/usr/lib64/libGLX_nvidia.so.${VER}

    INSTALLED=$(ls /usr/lib64/libGLX_nvidia.so.[0-9]* 2>/dev/null \
                | sed 's|.*libGLX_nvidia.so.||' | sort -u | head -1 || true)

    . /etc/os-release
    DISTRO=${ID:-unknown}
    DISTRO_LIKE=${ID_LIKE:-}

    # Deps per distro. Besides the .run's build/runtime deps, note two
    # non-obvious ones that the GUI-on-Wayland path needs:
    #   libglvnd  the vendor-neutral GL/EGL dispatch. Installed FIRST so
    #             it (not the .run) owns libGL/libEGL/... — paired with
    #             --no-install-libglvnd below to avoid unowned-file
    #             conflicts on later mesa/flatpak installs.
    #   mesa/gbm + libdrm  NVIDIA's Wayland presentation backends
    #             (libnvidia-egl-gbm, libnvidia-egl-wayland) dlopen
    #             libgbm.so.1 + libdrm.so.2 to allocate swapchain buffers.
    #             Without them a Vulkan/EGL Wayland client (e.g. vkcube)
    #             SEGFAULTs creating its wl surface. mesa also gives an
    #             iGPU GL/Vulkan fallback for non-offloaded apps.
    install_deps() {
        case "$1" in
            fedora|rhel|centos|rocky|almalinux)
                dnf install -y --setopt=install_weak_deps=False \
                    curl perl gcc make kernel-headers \
                    pkgconf vulkan-loader \
                    libglvnd libglvnd-glx libglvnd-egl libglvnd-opengl \
                    mesa-libgbm libdrm \
                    libXext libxcb dbus-libs xz pciutils
                ;;
            debian|ubuntu)
                export DEBIAN_FRONTEND=noninteractive
                apt-get update
                apt-get install -y --no-install-recommends \
                    curl ca-certificates perl gcc make linux-headers-generic \
                    pkg-config libvulkan1 \
                    libglvnd0 libglx0 libgl1 libegl1 \
                    libgbm1 libdrm2 \
                    libxext6 libxcb1 libdbus-1-3 xz-utils pciutils
                ;;
            arch|cachyos|endeavouros|manjaro)
                pacman -Sy --noconfirm --needed \
                    curl perl gcc make linux-headers \
                    pkgconf vulkan-icd-loader \
                    libglvnd mesa libdrm \
                    libxext libxcb dbus xz pciutils
                ;;
            opensuse*|sles|suse)
                zypper --non-interactive install -y \
                    curl perl gcc make kernel-default-devel \
                    pkgconf-pkg-config vulkan-loader \
                    libglvnd0 libgbm1 libdrm2 \
                    libXext6 libxcb1 libdbus-1-3 xz pciutils
                ;;
            alpine)
                apk add --no-cache \
                    curl perl gcc make linux-headers \
                    pkgconf vulkan-loader \
                    libglvnd mesa-gbm libdrm \
                    libxext libxcb dbus-libs xz pciutils
                ;;
            *)
                return 1
                ;;
        esac
    }

    if ! install_deps "$DISTRO"; then
        case "$DISTRO_LIKE" in
            *debian*)   install_deps debian   ;;
            *fedora*|*rhel*) install_deps fedora ;;
            *arch*)     install_deps arch     ;;
            *suse*)     install_deps opensuse ;;
            *)
                echo "unsupported distro: ID=${DISTRO} ID_LIKE=${DISTRO_LIKE}" >&2
                exit 1
                ;;
        esac
    fi

    if [[ -f "$LIB" ]]; then
        echo "nvidia userland ${VER} already matches host — dependencies refreshed"
        exit 0
    fi

    if [[ -n "$INSTALLED" ]]; then
        echo "upgrading nvidia userland: ${INSTALLED} -> ${VER}"
    else
        echo "installing nvidia userland: ${VER}"
    fi

    CACHE=/var/cache/mybox/nvidia
    mkdir -p "$CACHE"
    RUN="${CACHE}/NVIDIA-Linux-x86_64-${VER}.run"
    URL="https://download.nvidia.com/XFree86/Linux-x86_64/${VER}/NVIDIA-Linux-x86_64-${VER}.run"

    if [[ ! -f "$RUN" ]]; then
        echo "downloading ${URL}"
        curl -fL --retry 3 --connect-timeout 15 -o "$RUN" "$URL"
    fi
    chmod +x "$RUN"

    # Flag set:
    #   --no-kernel-modules            shared host kernel; container
    #                                  must not load its own
    #   --no-kernel-module-source      skip nvidia-{kmod,modprobe} src
    #   --no-distro-scripts            skip dracut / initramfs hooks
    #   --no-systemd                   skip host-style unit enabling
    #   --no-nouveau-check             nouveau is the host's concern
    #   --no-x-check                   no Xorg inside; suppress prompt
    #   --no-precompiled-interface     not building a kmod
    #   --no-install-libglvnd          the distro's libglvnd (installed
    #                                  above) owns libGL/libEGL/libGLX/
    #                                  libGLdispatch/libOpenGL. Without
    #                                  this the .run drops its OWN copies
    #                                  as UNOWNED files → a later
    #                                  `pacman/dnf/apt install mesa`
    #                                  (or flatpak, which pulls mesa)
    #                                  aborts on "conflicting files:
    #                                  libEGL.so.1 exists in filesystem".
    #                                  nvidia still installs its VENDOR
    #                                  libs (libGLX_nvidia, libEGL_nvidia,
    #                                  the Vulkan ICD) which glvnd routes.
    #   --silent                       no TUI, EULA auto-accepted;
    #                                  upgrades over prior install
    "$RUN" \
        --no-kernel-modules \
        --no-kernel-module-source \
        --no-distro-scripts \
        --no-systemd \
        --no-nouveau-check \
        --no-x-check \
        --no-precompiled-interface \
        --no-install-libglvnd \
        --silent

    ldconfig
    echo "nvidia userland ${VER} ready"
