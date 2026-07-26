# Install NVIDIA userland matching the HOST driver via the official
# .run installer (--no-kernel-modules — the host kernel owns the
# module; in-container userland must match its version exactly).
# Re-run after every host driver upgrade: the installer replaces the
# prior install in place, no uninstall/marker/reboot.
#
# Used with the raw-device path (31-nvidia-raw.conf); the CDI path
# (30-nvidia.conf) injects host userland and doesn't need this.
# Distro-agnostic via /etc/os-release ID + ID_LIKE.

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

    # Two non-obvious deps for GUI-on-Wayland:
    #   libglvnd  installed FIRST so the distro (not the .run) owns the
    #             GL/EGL dispatch libs — pairs with --no-install-libglvnd.
    #   mesa/gbm + libdrm  NVIDIA's Wayland backends dlopen libgbm.so.1 +
    #             libdrm.so.2; without them Vulkan/EGL clients SEGFAULT
    #             creating their surface.
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

    # --no-install-libglvnd is load-bearing: without it the .run drops
    # its own libEGL/libGL copies as UNOWNED files and a later
    # mesa install (pacman/dnf/apt/flatpak) aborts on "conflicting
    # files". The distro libglvnd routes to nvidia's vendor libs.
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
