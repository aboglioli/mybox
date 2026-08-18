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
        └── share/mybox/
            ├── just/            # in-container recipes (install-nvidia, …)
            └── user-groups.d/   # extra groups for the runtime user
```

## Root model

Immutable image + writable state. The container is deliberately
disposable — quadlet removes and recreates it on every stop/restart/
boot; nothing of value lives inside it. The four binds below are part
of `mybox.container` itself and are **mandatory**, created on demand by
its `ExecStartPre=`:

| Host path | In container | Mechanism |
|---|---|---|
| (image) | `/`, `/usr` + `/opt` lower | pristine lower; rebuild + restart = instant rebase |
| `/srv/<name>/etc` | `/etc` | `:idmap` bind, seeded once from `/usr/share/factory/etc` |
| `/srv/<name>/var` | `/var` | `:idmap` bind, seeded once from `/usr/share/factory/var` — flatpak state, nested-podman storage, `/usr`+`/opt` diffs, root's home (pacman db rides `/usr`) |
| `/srv/<name>/srv` | `/srv` | `:idmap` bind, starts empty — service data for nested quadlets |
| `/srv/<name>/home` | `/home` | `:idmap` bind (whole `/home`; the runtime user is created inside by `useradd -m`) |
| `/srv/<name>/container.env` | env for PID 1 | optional `MYBOX_*` runtime config |

Not optional because the `/usr` overlay's upperdir has to sit on a real
filesystem — the kernel refuses overlayfs as an upperdir, so a
container without the `/var` bind gets a read-only `/usr`: no pacman,
no NVIDIA userland. Everything derives from the unit name via `%p`, so
a second instance is just `mybox-test.container` → `/srv/mybox-test`,
created on first start and `rm -rf`'d when you are done with it. There
are no ephemeral containers, only cheap ones.

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
network, GUI, GPU, devices, capabilities, runtime user — is a drop-in
in `container/` (see `container/README.md`). Persistence is not: it is
part of `mybox.container` and always on.

## Runtime user + SSH keys

The image bakes NO user. `mybox-user-setup.service` creates one at boot
from env — with no env at all you still get a default user
(`user` / 1000 / 1000 / fish), which is what makes replicating the host
account a one-liner (`MYBOX_UID` = your host uid):

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
Volume=/srv/mybox/authorized_keys:/etc/ssh/authorized_keys.d/<user>:ro
```

sshd listens on **port 2222** (port 22 belongs to the host sshd when
`Network=host`; kept consistent across all network modes). Auth is
pubkey-only; the runtime user has an empty password (console/`podman
exec` entry only) and NOPASSWD sudo.

**Creation is one-shot, group binding is every boot.** The account is
created once (and skipped when `MYBOX_UID` is already owned by someone
else — group binding then retargets to the actual owner, so a renamed
`MYBOX_USER` over a persistent `/etc` can never wedge the unit).
Supplementary groups are re-applied on every start: `wheel video render
input audio kvm libvirt` plus anything listed in
`/usr/share/mybox/user-groups.d/*.conf`. That is what makes a package
installed later into the `/usr` overlay (libvirt, docker) reach the user
without a manual `usermod` — its group exists at the next boot and gets
bound then. Variant images add their own groups by shipping a file in
that directory instead of patching the script (see its `README`).

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

**Upgrade corollary — enablement does not re-sync.** A newer image that
enables a unit ships that symlink in its FACTORY `/etc`, and a
populated bind is never re-seeded, so an existing box keeps whatever it
was seeded with. `/etc` is yours after the first boot, bootc/ostree
style. After a rebase that changed what is enabled, reconcile by hand:

```bash
diff -qr /etc/systemd /usr/share/factory/etc/systemd | grep -i wants
```

and `systemctl enable` / `systemctl --global enable` what is missing,
removing symlinks left dangling by units the new image dropped.

The pacman db is NOT part of the persistent `/var`: it lives inside
the image at `/usr/lib/pacman` (SteamOS-style; `/var/lib/pacman` is a
tmpfiles-managed symlink). Db and files travel through the same `/usr`
overlay — the image lower carries both for baked packages, your pacman
installs write both to the upperdir — so a rebase can never desync
them (a persisted db goes stale against the new `/usr` and every
install dies on "conflicting files"). Corollary: in-place upgrades of
image-shipped packages shadow the image until the overlay diff is
reset; prefer rebasing the image over upgrading it from inside.

## Enabling units: plain `enable`, no target drop-ins

mybox has no sysexts and no late-merged `/usr`, so units are enabled
the ordinary way and nothing needs `Wants=`/`Upholds=` drop-ins to
paper over a missing one:

| What | Where it is enabled |
|---|---|
| system units | `50-mybox.preset` → `systemctl preset-all` at build → symlinks in `/etc`, snapshotted into the factory tree |
| user units (all sessions) | `systemctl --global enable` at build → `/etc/systemd/user/…`, same snapshot |
| `mybox-{etc,var}-seed`, `mybox-usr-overlay` | static `.wants` symlinks under `/usr/lib/systemd/system/sysinit.target.wants/` |

The last row is the one exception, and the reason is the ordering: a
preset writes into `/etc`, and those three units are exactly the ones
that must run when `/etc` is an unseeded empty bind. Shipping their
enable symlink in `/usr` makes them independent of it. Everything else
reaches the first boot because the quadlet's `ExecStartPre=` seeds
`/etc` from the factory tree HOST-side, before PID 1 ever reads it.

**`Upholds=` is not a stronger `Wants=`** — it re-asserts "keep active"
every time a unit goes inactive, so it busy-loops on `Type=oneshot` +
`RemainAfterExit=no` and on **any unit with a failable `Condition*=`**
(a skipped start counts as inactive). Not theoretical: in the sibling
myosi project one mis-wired condition unit produced 27,380 restarts in
4.8 h. It has a legitimate use — re-asserting a unit that arrives after
the boot transaction is frozen, which is what a sysext merge does — and
that is precisely the situation mybox does not have.

**Where a service comes from decides whether `enable` sticks.** A unit
baked into the IMAGE lives in the pristine `/usr` lower, readable by
PID 1 from the first instant of boot, so `systemctl enable` behaves
exactly as it does anywhere else. A unit installed at RUNTIME
(`pacman -S` inside) lands in the `/usr` overlay upperdir, which is not
mounted until `mybox-usr-overlay.service` runs at sysinit — after PID 1
froze the boot job graph. Its enable symlink is a dangling reference
that boot drops with a warning, so it needs one `systemctl start` per
boot.

That is a property of the overlay, not a bug to route around, and it
maps cleanly onto how you are meant to use the two: **install at
runtime to try something, bake a variant image to keep it.** Layer a
`Containerfile` on `FROM ghcr.io/aboglioli/mybox`, `pacman -S` there,
`systemctl enable` there, and the unit is in `/usr` at boot like any
other. This is also why nothing optional (libvirt sockets, pipewire,
gnome-keyring) is wired in the base image: a drop-in naming
`virtqemud.socket` is evaluated on EVERY box, so one without libvirt
logs `Unit not found` per unit per boot and carries them forever in
`systemctl list-units --state=not-found` — 19 phantom units for libvirt
alone.

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
