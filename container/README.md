# container/

Quadlet drop-ins and `.network` files for the `mybox.container` base.
Podman ≥ 5.0 merges any `<unit>.container.d/*.conf` next to the main
quadlet into the generated `.service`, same semantics as systemd
`.service.d/*.conf`.

Host-side units are **not** here either — the GUI start trigger lives in
`host/` (see `host/README.md`), because it is a plain systemd unit on the
machine, not a quadlet drop-in.

Persistence is **not** here. `mybox.container` binds `/srv/<name>` at
`/.mybox` and `/usr/libexec/mybox/preinit` builds `/etc`, `/var`, `/usr`
and `/opt` on top of it as overlays before systemd starts, plus plain
binds for `/home` and `/srv`. None of it is optional — without the state
bind every tree stays at its read-only image content. A throwaway
instance gets its own unit name — `mybox-test.container` →
`/srv/mybox-test` — and you `rm -rf` that directory when done.

## Drop-ins

| File | Adds |
|---|---|
| `05-user.conf` | template for pinning `MYBOX_USER`/`UID`/`GID`/`SHELL`/`AUTHORIZED_KEYS` in the repo — all commented, since per-box identity belongs in `/srv/<name>/container.env`, which the quadlet loads already |
| `10-gui.conf` | host wayland / pipewire / pulse sockets → `/mnt/host` + env, and the `BindsTo=` that ends the session. The one drop-in **not** shared: it installs into `<name>@gui.container.d/` and is the whole difference between the headless and GUI instances (`host/README.md`) |
| `20-gpu.conf` | `/dev/dri`, `/dev/snd`, `/dev/input` (Intel/AMD stack) |
| `30-nvidia.conf` | `AddDevice=nvidia.com/gpu=all` via CDI (no in-container install needed) |
| `31-nvidia-raw.conf` | raw `/dev/nvidia*` + `mybox install-nvidia` inside (when the CDI hook fails under userns) |
| `40-virt.conf` | `/dev/kvm`, `/dev/net/tun`, `/dev/vhost-*` + NET_ADMIN/NET_RAW for libvirt+qemu |
| `45-vfio.conf` | `/dev/vfio/*` + SYS_RAWIO + IPC_LOCK + memlock for PCI passthrough TO an inner VM |
| `50-desktop.conf` | TTYs, `/dev/uinput`, SYS_TTY_CONFIG for a compositor INSIDE (host text-mode) |
| `60-shared-folder.conf` | bind `/mnt/shared` |
| `70-vpn.conf` | in-container VPN (wireguard / tailscale): NET_ADMIN + NET_RAW |
| `85-publish-ssh.conf` | expose the container's sshd at `<host>:2222` — for `mybox-nat.network`, remove it on `mybox-lan.network` |
| `80-static-ip.conf` | pin a fixed IP (static IPAM networks) |
| `81-static-mac.conf` | pin the MAC → stable DHCP lease → stable LAN IP across recreates |

## Usage

`just install [drop-ins…]` copies the chosen set and enables the start
trigger (see the repo justfile). It substitutes nothing, so copying by hand
gives exactly the same result — the full file-by-file table is under
**Installing by hand** in the repo README. From the repo root:

```bash
sudo mkdir -p /etc/containers/systemd/mybox@.container.d
sudo cp container/20-gpu.conf container/30-nvidia.conf \
        /etc/containers/systemd/mybox@.container.d/
sudo systemctl daemon-reload
sudo systemctl restart mybox@headless.service
```

`mybox@.container.d/` — with the `@` — is the shared drop-in dir both
instances read. `10-gui.conf` is the exception: it belongs to
`mybox@gui.container.d/` alone, because copying it into the shared dir
would boot-start a container whose sockets do not exist yet. See
`host/README.md`.

**Copy, never symlink** — least of all into a working tree under `/home`.
The quadlet generator runs before any filesystem is mounted, so a link
there resolves to nothing and NO unit is generated at all (`Unit
mybox@headless.service could not be found`). See "Start model" in the repo README.

## Verifying a drop-in applied

```bash
systemctl cat mybox@gui.service # drop-ins are merged inline
/usr/lib/systemd/system-generators/podman-system-generator --dryrun
```

If a drop-in didn't merge, check the path — `mybox@.container.d/` for the
shared set, `mybox@gui.container.d/` for `10-gui.conf`; the `.d` suffix is
on the unit name, and the `@` is part of it — plus the `.conf` extension
and the section headers. `--dryrun` lists every file quadlet actually read,
which settles it in one line:

```bash
sudo /usr/lib/systemd/system-generators/podman-system-generator --dryrun \
  | grep Loading
```

## Drop-in merge semantics

systemd-standard:

- Read in lexicographic order — `10-` before `20-` before `30-`
- Most fields ADD (every `Volume=`, `AddDevice=`, `PodmanArgs=` line
  is additive)
- Singletons (`Image=`, `Network=`, `HostName=`) — LAST setter wins
- To REMOVE a base field, set it empty (`Volume=`), then re-add
