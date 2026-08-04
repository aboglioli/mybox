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

    # Runtime-only deps — --no-kernel-modules means no toolchain, no
    # headers, no pkgconf. What GUI-on-Wayland + GPU actually need:
    #   libglvnd  installed FIRST so the distro (not the .run) owns the
    #             GL/EGL dispatch libs — pairs with --no-install-libglvnd.
    #   gbm + libdrm  NVIDIA's Wayland backends dlopen libgbm.so.1 +
    #             libdrm.so.2; without them Vulkan/EGL clients SEGFAULT
    #             creating their surface.
    #   vulkan loader, libXext + libxcb (GLX/X11 clients),
    #   curl (fetch the .run), xz (its payload extraction).
    install_deps() {
        case "$1" in
            fedora)
                dnf install -y --setopt=install_weak_deps=False \
                    curl xz vulkan-loader \
                    libglvnd libglvnd-glx libglvnd-egl libglvnd-opengl \
                    mesa-libgbm libdrm libXext libxcb
                ;;
            debian)
                export DEBIAN_FRONTEND=noninteractive
                apt-get update
                apt-get install -y --no-install-recommends \
                    curl ca-certificates xz-utils libvulkan1 \
                    libglvnd0 libglx0 libgl1 libegl1 \
                    libgbm1 libdrm2 libxext6 libxcb1
                ;;
            arch)
                pacman -Sy --noconfirm --needed \
                    curl xz vulkan-icd-loader \
                    libglvnd mesa libdrm libxext libxcb
                ;;
            opensuse)
                zypper --non-interactive install -y \
                    curl xz vulkan-loader \
                    libglvnd0 libgbm1 libdrm2 libXext6 libxcb1
                ;;
            alpine)
                apk add --no-cache \
                    curl xz vulkan-loader \
                    libglvnd mesa-gbm libdrm libxext libxcb
                ;;
        esac
    }

    # Resolve the distro FAMILY first, then install once — a package
    # manager failure must surface as itself, not as "unsupported
    # distro" (set -e aborts with the manager's own error).
    case "$DISTRO" in
        fedora|rhel|centos|rocky|almalinux) FAMILY=fedora ;;
        debian|ubuntu)                      FAMILY=debian ;;
        arch|cachyos|endeavouros|manjaro)   FAMILY=arch ;;
        opensuse*|sles|suse)                FAMILY=opensuse ;;
        alpine)                             FAMILY=alpine ;;
        *)
            case "$DISTRO_LIKE" in
                *debian*)        FAMILY=debian ;;
                *fedora*|*rhel*) FAMILY=fedora ;;
                *arch*)          FAMILY=arch ;;
                *suse*)          FAMILY=opensuse ;;
                *)
                    echo "unsupported distro: ID=${DISTRO} ID_LIKE=${DISTRO_LIKE}" >&2
                    exit 1
                    ;;
            esac
            ;;
    esac

    install_deps "$FAMILY"

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
