# mybox

Daily-driver system container: an Arch Linux image with systemd as
PID 1, running as a **podman quadlet** on top of an immutable host OS
(sibling projects [myos](https://github.com/aboglioli/myos) /
[myosi](https://github.com/aboglioli/myosi), or any Linux host with
podman ≥ 5). `mybox.container` plus `container/*.conf` drop-ins are
installed under `/etc/containers/systemd`, with systemd owning the
lifecycle. The `justfile` builds the image, installs the unit files and
gives you a shell; it does not drive podman by hand.

It is intended to feel like a small user OS, not an app container:
real login sessions, SSH, background services, game/http servers,
rootless podman inside, Flatpak, and optional GUI, GPU, KVM/libvirt,
WireGuard and Tailscale.

```
mybox/
├── Containerfile                # OCI image build (Arch Linux + systemd PID 1)
├── justfile                     # build image + install/drive the quadlet
├── mybox.container              # rootful quadlet (minimal base)
├── container.env.example        # MYBOX_* runtime config template
├── container/                   # quadlet drop-ins + .network files (see container/README.md)
└── system/                      # image config tree (Containerfile COPY)
    ├── etc/                     # → /etc (snapshotted to /usr/share/factory/etc)
    └── usr/                     # → /usr (immutable at runtime)
        ├── lib/systemd/         # units, presets, target drop-ins
        ├── libexec/mybox/       # boot scripts (seed, overlay, user-setup, …)
        ├── local/bin/mybox      # in-container CLI dispatcher
        └── share/mybox/just/    # in-container recipes (install-nvidia, …)
```

## Root model

Immutable image + writable state. The container is deliberately
disposable — quadlet removes and recreates it on every stop/restart/
boot; nothing of value lives inside it:

| Host path | In container | Mechanism |
|---|---|---|
| (image) | `/`, `/usr` + `/opt` lower | pristine lower; rebuild + restart = instant rebase |
| `/srv/<name>/etc` | `/etc` | `:idmap` bind, seeded once from `/usr/share/factory/etc` |
| `/srv/<name>/var` | `/var` | `:idmap` bind, seeded once from `/usr/share/factory/var` — flatpak state, nested-podman storage, `/usr`+`/opt` diffs, root's home (pacman db rides `/usr`) |
| `/srv/<name>/srv` | `/srv` | `:idmap` bind, starts empty — service data for nested quadlets |
| `/srv/<name>/home` | `/home` | `:idmap` bind (whole `/home`; the runtime user is created inside by `useradd -m`) |
| `/srv/<name>/container.env` | env for PID 1 | optional `MYBOX_*` runtime config |

Inside the container, `/usr` + `/opt` are an overlay whose upperdir
lives in `/var` (`mybox-usr-overlay.service`) — pacman installs and the
NVIDIA userland persist. `/root` symlinks to `/var/roothome`. `/run`,
`/tmp`, `/var/tmp` are tmpfs, wiped every start. Writes outside
`/etc /var /srv /home /usr /opt /root` die with the recreation — that
is the immutable-root contract.

Why the `/usr` overlay is mounted from INSIDE instead of podman's own
`Volume=vol:/:O,upperdir=…`: that path is broken under `--userns=auto`
([podman#23211](https://github.com/containers/podman/issues/23211)),
and downgrading the userns would gut the isolation model. First boot of
an empty `/etc` bind is pre-seeded HOST-side by an `ExecStartPre`
throwaway container (PID 1 reads machine-id + preset/mask symlinks
before any in-container unit could seed them); the in-container
`mybox-{etc,var}-seed.service` remain as fallback.

## Quick start

```bash
# One-time host prereqs:
echo 'containers:2000000:1000000' | sudo tee -a /etc/subuid /etc/subgid
sudo useradd -r -s /usr/sbin/nologin containers 2>/dev/null || true
sudo systemctl enable --now netavark-dhcp-proxy.socket   # for DHCP networks

just install        # symlink quadlet + network + default drop-ins
just build          # OPTIONAL: local build over the published ghcr
                    # reference, into the ROOTFUL store; skip it and
                    # the quadlet pulls ghcr.io/aboglioli/mybox instead
just start          # systemctl start mybox.service
just status
just login          # full PAM session as the runtime user
```

Quadlets cannot be `systemctl enable`d — the generator wires boot from
the unit's `[Install]` section, so one `just start` survives reboots.

| Recipe | What it does |
|---|---|
| `just build` | local build tagged over the published reference, into the rootful store |
| `just install [drop-ins…]` | symlink quadlet + `.network` + chosen drop-ins, `daemon-reload`. Declarative: removes previously-linked drop-ins not in the set |
| `just start` / `stop` | start/stop the unit — stop removes the container; `/srv/<name>` survives |
| `just restart` | recreate against the current image + drop-ins |
| `just status` / `logs` | unit + container state + LAN IP / follow journal |
| `just enter [user]` | fast shell (`podman exec`, no PAM session) |
| `just login [user]` | full PAM/logind session (`login -f`) |

Justfile knobs (env vars): `MYBOX_IMAGE`, `MYBOX_CONTAINER`,
`MYBOX_USERNAME`, `MYBOX_NETFILE`, `MYBOX_DROPINS`. Everything else —
network, GUI, GPU, devices, capabilities, persistence, runtime user —
is a drop-in in `container/` (see `container/README.md`).

## Runtime user + SSH keys

The image bakes NO user. `mybox-user-setup.service` creates one at boot
from env (defaults `user` / 1000 / 1000 / fish):

```
MYBOX_USER / MYBOX_UID / MYBOX_GID / MYBOX_SHELL
MYBOX_AUTHORIZED_KEYS      comma-separated ssh keys
```

Set them via `05-user.conf` `Environment=` lines,
`EnvironmentFile=/srv/<name>/container.env` (see
`container.env.example`), or `-e` flags. `MYBOX_AUTHORIZED_KEYS` is
synced every boot to `/etc/ssh/authorized_keys.d/<user>`; sshd reads
that alongside `~/.ssh/authorized_keys`. Local alternative — bind-mount
a host file instead:

```
Volume=/srv/mybox/authorized_keys:/etc/ssh/authorized_keys.d/user:ro
```

sshd listens on **port 2222** (port 22 belongs to the host sshd when
`Network=host`; kept consistent across all network modes). Auth is
pubkey-only; the runtime user has an empty password (console/`podman
exec` entry only) and NOPASSWD sudo.

## Network options (pick ONE .network file)

| File | Driver | LAN reach | Requires |
|---|---|---|---|
| `mybox-bridge.network` | joins existing `br0` | ✅ real LAN IP, host-reachable | `br0` on host |
| `mybox-macvlan.network` | macvlan on physical NIC | ✅ own LAN IP (host can't reach it) | NIC not enslaved, wired |
| `mybox-managed.network` | podman bridge + NAT | ⚠️ via `PublishPort=` | works anywhere |
| (none, `Network=host`) | host netns | ✅ host's IP, sshd at `<host>:2222` | works anywhere |

Switch via drop-in: `Network=` (empty) + new value. Pin the address
across recreations with `80-static-ip.conf` (static IPAM) or
`81-static-mac.conf` (stable DHCP lease).

## Security posture

Rootful only means the podman CLI runs as root — the workload is NOT
host root:

- **`--userns=auto:size=200000`** is the load-bearing control:
  container UID 0 maps to host UID ~2000000. Every capability the
  container holds is namespaced — nothing over host-owned files,
  devices or processes.

| Knob | State | Why |
|---|---|---|
| `userns=auto:size=200000` | on | container root ≠ host root; size fits the inner 100000:65536 subuid pool for nested podman |
| default seccomp | kept | biggest attack-surface cut; validated with systemd + nested podman + bwrap + flatpak |
| `/proc` masking | kept | `--systemd=always` mounts what PID 1 needs |
| `SYS_ADMIN SYS_NICE MKNOD` | kept | systemd/mounts/nesting, scheduling, nested device nodes |
| `NET_ADMIN`/`NET_RAW` | dropped from base | nothing in the base uses them (eth0 is configured host-side; nested podman gets its own in its userns). `40-virt.conf` / `70-vpn.conf` add them back |
| `/dev/fuse` + `/dev/net/tun` | kept | tun: pasta (nested rootless podman networking). fuse: flatpak document portal + fuse-overlayfs fallback. Devices only, no capabilities |
| `label=disable` | the one open item | `container_t` breaks boot on an Enforcing host; no dedicated policy module yet |

Fine for a daily-driver box running your own workloads. Run untrusted
code only nested behind mybox's own rootless podman (a second userns).
Do not expose the container's sshd to the public internet.

**Store note:** rootful and rootless podman keep SEPARATE image
stores. The system quadlet reads the rootful store — `just build` uses
`sudo podman build`; a rootless build is invisible to the unit.

## /etc factory pattern

Build-time: pacman populates `/etc`, `system/etc` overlays our
drop-ins, build steps apply presets/masks, and the final image
snapshots `/etc` and `/var` to `/usr/share/factory/{etc,var}`.

Runtime: the default (no-bind) container runs straight from the live
trees. With a persistent bind, the host-side `ExecStartPre` pre-seed
(and the in-container seed services as fallback) populate an EMPTY bind
once from the factory; a populated bind is never overwritten. Factory
reset = `rm -rf /srv/<name>/{etc,var}` while stopped.

The pacman db is NOT part of the persistent `/var`: it lives inside
the image at `/usr/lib/pacman` (SteamOS-style; `/var/lib/pacman` is a
tmpfiles-managed symlink). Db and files travel through the same `/usr`
overlay — the image lower carries both for baked packages, your pacman
installs write both to the upperdir — so a rebase can never desync
them (a persisted db goes stale against the new `/usr` and every
install dies on "conflicting files"). Corollary: in-place upgrades of
image-shipped packages shadow the image until the overlay diff is
reset; prefer rebasing the image over upgrading it from inside.

## Enabling units: `Wants=`, not `Upholds=`

`Upholds=` re-asserts "keep active" every time a unit goes inactive, so
it busy-loops two shapes: `Type=oneshot` + `RemainAfterExit=no`, and
**any unit with a failable `Condition*=`** (a skipped start counts as
inactive). Most mybox units self-gate on conditions, so they are wired
with `Wants=`; `Upholds=` is reserved for units that stay active once
started (sockets, daemons, `RemainAfterExit=yes` oneshots — see the
`sockets.target.d` drop-ins). The busy-loop is not theoretical: one
mis-wired condition unit produced 27,380 restarts in 4.8 h.

**Late-arriving units** (the `/usr` overlay corollary): PID 1 freezes
the boot job graph at startup, before `mybox-usr-overlay.service`
mounts at sysinit. A service installed INTO the overlay (`pacman -S`)
and enabled via `/etc` symlinks is therefore a dangling `Wants=` at the
next boot — dropped with a warning, never revisited, even after the
daemon-reload that follows the mount. Every unit mybox ships is baked
into the image, so this only affects overlay-installed services. Wire
those through activation that arrives as a post-mount event (`.socket`,
`.path`, `.timer`, D-Bus) or an `Upholds=` drop-in on a stay-active
unit; a plain enable needs one manual `systemctl start` per boot.

## In-container CLI

`mybox` (baked at `/usr/local/bin/mybox`) scans
`/usr/share/mybox/just/*.just` and execs `just` against a transient
justfile. Slot convention: 00-49 shipped, 50-99 local additions.

| Recipe | What it does |
|---|---|
| `install-nvidia` | installs userland matching the host driver via the official `.run` (raw-device path; the CDI drop-in doesn't need it). Re-run after host driver upgrades |

## NVIDIA

Two drop-ins, pick ONE:

- `30-nvidia.conf` — CDI (`nvidia.com/gpu=all`): podman injects devices
  AND userland. Needs `nvidia-ctk cdi generate` on the host.
- `31-nvidia-raw.conf` — raw `/dev/nvidia*` + `sudo mybox
  install-nvidia` inside. For host/driver combos where the CDI hook
  fails under userns. `/dev/nvidia-modeset` is mandatory for Vulkan —
  without it the driver segfaults inside `vkCreateDevice` while
  `nvidia-smi` still looks fine.

## Variants

Layer a sibling `Containerfile` with
`FROM ghcr.io/aboglioli/mybox:<tag>` (or a local build) for variants:
dev toolchains, gaming, CUDA compute. All inherit the CLI + recipes +
GUI environment.

## License

MIT — see [LICENSE](LICENSE).
