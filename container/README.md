# container/

Quadlet drop-ins and `.network` files for the `mybox.container` base.
Podman ≥ 5.0 merges any `<unit>.container.d/*.conf` next to the main
quadlet into the generated `.service`, same semantics as systemd
`.service.d/*.conf`.

## Drop-ins

| File | Adds |
|---|---|
| `01-persist-root.conf` | persistent `/etc` + `/var` binds from `/srv/<name>` + host-side first-boot seed — with the in-image `/usr`+`/opt` overlay the whole rootfs survives recreation |
| `02-persist-home.conf` | `/srv/<name>/home` → `/home` (`:idmap`) |
| `03-persist-srv.conf` | `/srv/<name>/srv` → `/srv` (`:idmap`, nested-quadlet volumes) |
| `05-user.conf` | runtime login user + ssh keys: `MYBOX_USER`/`UID`/`GID`/`SHELL`/`AUTHORIZED_KEYS` env (or `EnvironmentFile=/srv/<name>/container.env`) |
| `10-gui.conf` | host wayland / pipewire / pulse sockets → `/mnt/host` + env |
| `20-gpu.conf` | `/dev/dri`, `/dev/snd`, `/dev/input` (Intel/AMD stack) |
| `30-nvidia.conf` | `AddDevice=nvidia.com/gpu=all` via CDI (no in-container install needed) |
| `31-nvidia-raw.conf` | raw `/dev/nvidia*` + `mybox install-nvidia` inside (when the CDI hook fails under userns) |
| `40-virt.conf` | `/dev/kvm`, `/dev/net/tun`, `/dev/vhost-*` + NET_ADMIN/NET_RAW for libvirt+qemu |
| `45-vfio.conf` | `/dev/vfio/*` + SYS_RAWIO + IPC_LOCK + memlock for PCI passthrough TO an inner VM |
| `50-desktop.conf` | TTYs, `/dev/uinput`, SYS_TTY_CONFIG for a compositor INSIDE (host text-mode) |
| `60-shared-folder.conf` | bind `/mnt/shared` |
| `70-vpn.conf` | in-container VPN (wireguard / tailscale): NET_ADMIN + NET_RAW |
| `80-static-ip.conf` | pin a fixed IP (static IPAM networks) |
| `81-static-mac.conf` | pin the MAC → stable DHCP lease → stable LAN IP across recreates |

## Usage

`just install [drop-ins…]` symlinks the chosen set (see the repo
justfile). By hand, from the repo root:

```bash
sudo mkdir -p /etc/containers/systemd/mybox.container.d
sudo cp container/10-gui.conf container/20-gpu.conf container/30-nvidia.conf \
        /etc/containers/systemd/mybox.container.d/
sudo systemctl daemon-reload
sudo systemctl restart mybox.service
```

## Verifying a drop-in applied

```bash
systemctl cat mybox.service     # drop-ins are merged inline
/usr/lib/systemd/system-generators/podman-system-generator --dryrun
```

If a drop-in didn't merge, check the path
(`/etc/containers/systemd/mybox.container.d/` — the `.d` suffix is on
the unit name), the `.conf` extension, and the section headers.

## Drop-in merge semantics

systemd-standard:

- Read in lexicographic order — `10-` before `20-` before `30-`
- Most fields ADD (every `Volume=`, `AddDevice=`, `PodmanArgs=` line
  is additive)
- Singletons (`Image=`, `Network=`, `HostName=`) — LAST setter wins
- To REMOVE a base field, set it empty (`Volume=`), then re-add
