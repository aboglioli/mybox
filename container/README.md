# mybox/container/

Quadlet drop-ins for the `mybox.container` base — parallel to incus
profile composition (`-p default -p gui -p gpu -p nvidia`).

Podman 5.x (verified 5.8.2) supports drop-ins natively: any file
under `<unit>.<type>.d/*.conf` next to the main quadlet is merged
into the generated `.service` at unit-generation time. Same merge
semantics as systemd `.service.d/*.conf`.

## Drop-ins

| File | Adds |
|---|---|
| `01-persist-root.conf` | persistent `/etc` + `/var` binds from `/srv/<name>` + host-side first-boot seeding — with the in-image `/usr`+`/opt` overlay this makes the whole rootfs survive quadlet recreation |
| `02-persist-home.conf` | `/srv/<name>/home` → `/home` (`:idmap`) |
| `05-user.conf` | runtime login user: `MYBOX_USER`/`UID`/`GID`/`SHELL` env for `mybox-user-setup.service` (or `EnvironmentFile=/srv/<name>/container.env`) |
| `10-gui.conf` | host wayland / pipewire / pulse sockets → `/mnt/host` + env |
| `20-gpu.conf` | `/dev/dri`, `/dev/snd`, `/dev/input` (Intel/AMD stack) |
| `30-nvidia.conf` | `AddDevice=nvidia.com/gpu=all` via CDI (NO `mybox install-nvidia` needed — podman is CDI-native, unlike incus) |
| `40-virt.conf` | `/dev/kvm`, `/dev/net/tun`, `/dev/vhost-*` + NET_ADMIN/NET_RAW for libvirt+qemu |
| `45-vfio.conf` | `/dev/vfio/*` + SYS_RAWIO + IPC_LOCK + memlock ulimit for PCI passthrough TO inner VM |
| `50-desktop.conf` | TTYs, `/dev/uinput`, SYS_TTY_CONFIG for a compositor INSIDE (host text-mode) |
| `60-shared-folder.conf` | bind `/mnt/shared` |
| `70-vpn.conf` | in-container VPN (wireguard / tailscale): NET_ADMIN + NET_RAW |
| `80-static-ip.conf` | pin a fixed IP (static IPAM networks) |
| `81-static-mac.conf` | pin the MAC → stable DHCP lease → stable LAN IP across quadlet recreates |

## Usage

Drop-ins live in this repo; copy or symlink the ones you want into
`~/.config/containers/systemd/mybox.container.d/`:

```bash
mkdir -p ~/.config/containers/systemd/mybox.container.d

# Compose your stack — same muscle memory as incus `-p` flags
cp ~/mybox/container/10-gui.conf \
   ~/mybox/container/20-gpu.conf \
   ~/mybox/container/30-nvidia.conf \
   ~/.config/containers/systemd/mybox.container.d/

systemctl --user daemon-reload
systemctl --user restart mybox.service
```

Or symlink for live edits:

```bash
ln -sf ~/mybox/container/10-gui.conf \
       ~/.config/containers/systemd/mybox.container.d/
```

## Composition table

Same user surface as incus profile composition:

| Want | incus | podman quadlet drop-ins |
|---|---|---|
| CLI sandbox | `-p default` | base `mybox.container` |
| GUI client of host compositor | `+ gui` | `+ 10-gui.conf` |
| Intel/AMD GPU | `+ gpu` | `+ 20-gpu.conf` |
| NVIDIA GPU (Vulkan/EGL/CUDA) | `+ nvidia` + `mybox install-nvidia` inside | `+ 30-nvidia.conf` (CDI — no in-container install) |
| KVM + libvirt | `+ virt` | `+ 40-virt.conf` |
| Inner VM w/ host GPU passthrough | n/a | `+ 40-virt.conf + 45-vfio.conf` |
| Compositor INSIDE | `+ desktop` (with host text-mode) | `+ 50-desktop.conf` (with host text-mode) |
| `/mnt/shared` bind | `+ shared-folder` | `+ 60-shared-folder.conf` |

## Verifying a drop-in applied

```bash
# Show the generated .service (drop-ins are merged inline)
systemctl --user cat mybox.service

# Or run the quadlet generator with --dryrun against your config dir
/usr/lib/systemd/user-generators/podman-user-generator --dryrun
```

If a drop-in didn't merge, check:

- Path: `~/.config/containers/systemd/mybox.container.d/` (the `.d`
  suffix is on the unit name, NOT inside `systemd/`)
- Extension: must end in `.conf`
- Syntax: same format as the base quadlet — `[Container]`, `[Unit]`,
  `[Service]`, `[Install]` sections

## Drop-in merge semantics

systemd-standard:

- Read in lexicographic order — `10-` before `20-` before `30-`
- For most fields, drop-ins ADD (every `Volume=`, `AddDevice=`,
  `PodmanArgs=` line is additive)
- For singletons (`Image=`, `Network=`, `HostName=`), the LAST
  setter wins — drop-ins override the base
- To REMOVE a field from the base, set it to empty: `Volume=` (no
  value) clears the field, all later additions start fresh
