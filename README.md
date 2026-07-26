# mybox

Daily-driver system container: an Arch Linux image with systemd as
PID 1, designed to run on top of an immutable host OS (sibling
projects [myos](https://github.com/aboglioli/myos) /
[myosi](https://github.com/aboglioli/myosi), or any Linux host).
**A podman quadlet is the primary runtime** — `mybox.container` plus
`container/*.conf` drop-ins installed under `/etc/containers/systemd`,
with systemd owning the lifecycle. The `justfile` builds the image,
installs those unit files and gives you a shell; it does not drive podman
by hand. The same image also runs under systemd-nspawn and incus
(`mybox.nspawn`, `nspawn/`, `incus.yaml`), kept in the tree for
manual use.

```
mybox/
├── README.md
├── Containerfile                # OCI image build (Arch Linux + systemd PID 1)
├── justfile                     # build image + install/drive the quadlet
├── mybox.container              # rootful quadlet (system-level — minimal base)
├── mybox.nspawn                 # systemd-nspawn machine config (secondary runtime)
├── incus.yaml                   # incus preseed — profiles for the manual incus runtime
├── container.env.example        # MYBOX_* runtime config template (/srv/<name>/container.env)
├── container/                  # podman quadlet — .network files + drop-ins
│   ├── 01-persist-root.conf    # /srv/<name>/{etc,var} binds + host-side first-boot seed
│   ├── 02-persist-home.conf    # /srv/<name>/home → /home (:idmap)
│   ├── 03-persist-srv.conf     # /srv/<name>/srv → /srv (:idmap, nested-quadlet volumes)
│   ├── 05-user.conf            # runtime user env (MYBOX_USER/UID/GID/SHELL)
│   ├── 10-gui.conf             # host wayland/pulse/pipewire sockets → /mnt/host
│   ├── 20-gpu.conf             # /dev/dri + /dev/snd + /dev/input
│   ├── 30-nvidia.conf          # CDI nvidia.com/gpu=all
│   ├── 31-nvidia-raw.conf      # raw /dev/nvidia* (when the CDI hook fails under userns)
│   ├── 40-virt.conf            # /dev/kvm + /dev/net/tun + vhost-*
│   ├── 45-vfio.conf, 50-desktop.conf, 60-shared-folder.conf
│   ├── 70-vpn.conf              # wireguard / tailscale (NET_ADMIN+NET_RAW)
│   ├── 80-static-ip.conf       # pin macvlan/bridge IP
│   └── 81-static-mac.conf      # pin MAC → stable DHCP lease across recreates
├── system/                     # myosi-style base config tree (Containerfile COPY)
│   ├── etc/                    # → /etc (→ /usr/share/factory/etc at end)
│   │   ├── environment.d/gui.conf
│   │   ├── locale.conf, locale.gen, nsswitch.conf
│   │   ├── profile.d/{editor,gpg}.sh
│   │   ├── ssh/sshd_config.d/50-mybox.conf
│   │   ├── sudoers.d/wheel
│   │   └── systemd/{system.conf.d,resolved.conf.d}/50-mybox.conf
│   └── usr/                    # → /usr (baked, immutable at runtime)
│       ├── lib/systemd/
│       │   ├── system-preset/50-mybox.preset
│       │   ├── system/mybox-{etc-seed,var-seed,usr-overlay,user-setup,linger}.service
│       │   ├── system/{flatpak-setup,proc-unmask}.service
│       │   ├── system/{sysinit,multi-user,sockets}.target.d/50-mybox-*.conf
│       │   └── user/{sockets,default}.target.d/50-mybox-*.conf
│       ├── lib/{sysusers.d,tmpfiles.d,environment.d}/
│       ├── libexec/mybox/{flatpak-setup,link-host-sockets,user-setup,usr-overlay}
│       ├── local/bin/mybox          # CLI dispatcher (baked in)
│       ├── share/mybox/just/        # recipe modules (baked in)
│       ├── share/containers/{containers.conf.d,storage.conf}
│       └── share/polkit-1/rules.d/10-flatpak-wheel.rules
└── nspawn/                     # nspawn-specific systemd drop-ins
    ├── 40-gpu-nvidia.service.conf   # cgroup DeviceAllow= for /dev/nvidia*
    ├── 50-input.service.conf        # DeviceAllow= for /dev/input + /dev/tty*
    ├── 60-virt.service.conf         # DeviceAllow= for /dev/kvm + vhost-*
    └── 70-tun.service.conf          # DeviceAllow= for /dev/net/tun
```

**The podman quadlet is the primary path.** Incus
(`incus.yaml`) and nspawn (`mybox.nspawn`) run the same image
manually — their configs are kept in the tree but are not wired into the
`just` recipes. Raw LXC was removed (see the design notes below). CLI + GUI
environment are baked into the mybox image (`system/usr/local/bin/
mybox`, `system/usr/share/mybox/just/`, `system/etc/environment.d/
gui.conf`). For vanilla `images:archlinux` containers, incus profiles
include commented bind-device entries pointing at the same `system/`
paths.

## System container target

`mybox` is intended to be a daily-driver system container: systemd as
PID 1, real login sessions, SSH, background services, game/http servers,
rootless Podman, Flatpak, and optional GUI, GPU, KVM/libvirt, WireGuard,
and Tailscale. It should feel like a small user OS running on top of
`myos` or `myosi`, not like an app container.

### Why incus/nspawn over raw LXC

Podman (via `just`) is the primary path; incus and nspawn run the same
image manually. Both run nearly identical kernel containers (userns +
idmap + cgroup + a rootfs with systemd PID 1) — the difference is the
management layer around them. Raw LXC was tried and removed because, for
this GUI + nested-podman workload, it loses on the two things that matter
without buying anything back:

- **Idmapped host mounts** (compositor sockets, GPU nodes, state dirs):
  incus does them as the real-root daemon (`shift=true`), so they "just
  work". `systemd-nspawn` does them inline (`Bind=...:idmap`). Raw
  `lxc-start` does its mount step as the container's *mapped* root, which
  can't reach the compositor's `0700 /run/user/1000` — so it needed a
  bespoke real-root `pre-start` hook for every such socket.
- **Flatpak / nested crun**: incus masks `/proc` via lxcfs + LSM denials,
  so bubblewrap's nested `/proc` mount is allowed — no workaround. nspawn
  over-masks `/proc`, so it needs `proc-unmask.service`. Raw LXC needed it
  too.

incus also gives lxcfs (container-aware `/proc`/`/sys`), a clean device
model (`type: gpu`), and is the most battle-tested runtime for running
rootless+rootful podman and VMs inside a container. nspawn is kept for
when you want a daemonless, file-only, bring-your-own-image setup and
accept the `proc-unmask` service + manual `DeviceAllow=` drop-ins.

The base image keeps systemd presets and user drop-ins in a single
`mybox/system/` tree. We wire optional units in the base image even when
their packages are absent — a not-found reference shows up in
`systemctl status` but starts nothing, and one system tree is simpler
than maintaining separate desktop rootfs overlays.

**Wire them with `Wants=`, not `Upholds=`.** `Upholds=` is a continuous
"keep this unit active" assertion that pid1 re-evaluates every time the
unit goes inactive, so two shapes loop forever under it: `Type=oneshot`
with `RemainAfterExit=no` (returns to inactive the instant it succeeds),
and **any unit with a failable `Condition*=`** (a skipped start leaves it
inactive; `RemainAfterExit=yes` only applies to a start that actually
ran).

The second is the trap here, since most mybox units self-gate —
`mybox-etc-seed`, `mybox-host-sockets`, `mybox-xwayland`,
`flatpak-setup`. Such a unit is a clean no-op under `Wants=` and a
busy-loop under `Upholds=`; on the myosi side the same mistake produced
27,380 restarts in 4.8 h. Reserve `Upholds=` for units that stay active
once started (`.socket`s, daemons, `RemainAfterExit=yes` oneshots —
`virtqemud`, `wireplumber`, `podman.socket`, `podman-restart` all
qualify). Full write-up in
[myosi’s README → Enabling units without presets](https://github.com/aboglioli/myosi#enabling-units-without-presets-wants-not-upholds).

The root model is immutable image plus writable state — **implemented**
on the podman path by the quadlet drop-ins `01`/`02`/`03-persist-*.conf`
plus the in-container `mybox-usr-overlay.service`. The container itself is
deliberately disposable: quadlet removes and recreates it on every
stop/restart/boot, and nothing of value lives inside it.

## Directory map

**Host side — all per-box state under `/srv/<name>/`** (one rule; the
`just` rootless fallback uses `~/.local/share/mybox/<name>/` with the
same layout):

| Host path | In container | Mechanism |
|---|---|---|
| (image) | `/`, `/usr` + `/opt` lower | pristine lower; rebuild + restart = instant rebase |
| `/srv/<name>/etc` | `/etc` | `:idmap` bind, seeded once from `/usr/share/factory/etc` |
| `/srv/<name>/var` | `/var` | `:idmap` bind, seeded once from `/usr/share/factory/var` — pacman db, flatpak state, nested-podman storage, `/usr`+`/opt` diffs, root's home |
| `/srv/<name>/srv` | `/srv` | `:idmap` bind, starts empty — service data for nested quadlets (e.g. `Volume=/srv/users/%U/valheim/...` in a game-server quadlet) |
| `/srv/<name>/home` | `/home` | `:idmap` bind (whole `/home` — the runtime user is created inside by `useradd -m`) |
| `/srv/<name>/container.env` | env for PID 1 | optional `MYBOX_*` runtime config (`EnvironmentFile=`/`--env-file`) |

Host install locations (not state): quadlets + drop-ins under
`/etc/containers/systemd/`, the `containers:2000000:1000000` pool in
`/etc/subuid`+`/etc/subgid`, and the image + disposable container
object in podman's rootful store. Host resources consumed via
drop-ins: `/run/user/<uid>/{wayland-*,pipewire-*,pulse}` sockets,
`/dev/{dri,snd,input,nvidia*,kvm,net/tun,vhost-*,fuse,vfio}`,
`/mnt/shared`.

**Inside the container — where mutable paths really live:**

| Container path | Backing | Notes |
|---|---|---|
| `/usr`, `/opt` | overlay: image lower + `upperdir=/var/lib/mybox/overlay/{usr,opt}/diff` | mounted at boot by `mybox-usr-overlay.service` (`userxattr`); pacman installs + nvidia userland land in the diff, which rides the `/var` bind |
| `/root` | symlink → `/var/roothome` | ostree-style; root's home persists with `/var` |
| `/var/lib/mybox/.marks/` | `/var` bind | run-once markers (flatpak-setup) |
| `/var/lib/containers/users/<uid>` | `/var` bind | nested ROOTLESS podman storage (`storage.conf`) |
| `/var/lib/containers/storage` | `/var` bind | nested ROOTFUL podman storage |
| `/etc/containers/systemd/`, `~/.config/containers/systemd/` | `/etc` + `/home` binds | nested quadlets — auto-start at boot, survive recreation |
| `/srv/users/<uid>/` | `/srv` bind | per-user service data, provisioned by `mybox-user-setup.service` (user-owned so rootless nested podman can create volume dirs) |
| `/mnt/host/*` | runtime socket binds | host GUI sockets; `mybox-host-sockets.service` symlinks them into `$XDG_RUNTIME_DIR` (never `bus`) |
| `/run`, `/tmp`, `/var/tmp` | tmpfs | wiped every start — keeps runtime junk out of the state tree |

Writes that do NOT persist: anything outside `/etc`, `/var`, `/srv`,
`/home`, `/usr`, `/opt`, `/root` — e.g. `mkdir /data` at the root
level dies with the recreation. That is the immutable-root contract.

Why the `/usr` overlay is mounted from INSIDE the
container instead of podman's own `Volume=vol:/:O,upperdir=…`: that
podman path is broken under `--userns=auto` (crun can't reach the
overlay merge mount from the auto userns —
[podman#23211](https://github.com/containers/podman/issues/23211)), and
downgrading to `keep-id` would gut the isolation model. First boot of
an empty `/etc` bind is HOST-side pre-seeded by an `ExecStartPre`
throwaway container (PID 1 reads machine-id + preset/mask symlinks
before any in-container unit could seed them); the in-container
`mybox-etc-seed` / `mybox-var-seed` services remain for incus/nspawn
and as belt-and-braces.

Lifecycle:

```bash
just build && just restart         # rebase onto new image, state kept
just install <drop-ins...>         # change the installed drop-in set
sudo rm -rf /srv/<name>/{etc,var}  # factory reset (stopped; home kept)
```

The two runtimes reach this differently. **nspawn** matches it literally:
`RootImage=` mounts a RO erofs/squashfs (optional dm-verity) as root +
`Bind=...:idmap` state. **incus** does NOT mount a host image as root —
the root always comes from a storage-pool volume built from an imported
image (no host erofs/loop as root). incus keeps the image as the RO/CoW
base (or `--ephemeral` for a wiped-on-stop root; `incus rebuild` to swap
the base) and the `state-binds` profile binds `/etc /var /home /srv` from
host subvols with `shift=true`. Both consume the rootfs the `Containerfile`
builds (`podman export` → `incus image import` / `mkfs.erofs`).

On Btrfs, `/srv` or `/srv/machines` should be its own subvolume, but do
not set `chattr +C` on the whole tree by default. Copy-on-write is useful
for rootfs snapshots, reflinks, send/receive, and rollback. Use NoCOW only
for specific heavy random-write payloads such as VM disk images,
database stores, or dedicated nested-container storage, and set it before
files are created. `+C` disables data checksumming for those files and
does not reliably convert existing files.

## Quick start (incus — manual, config kept)

```bash
# ──  Prerequisites (one-time)  ───────────────────────────────────
# incus installed + your user in the incus-admin group.
# subuid/subgid pool for the daemon — myosi already ships
# `root:1500000:200000`; on a non-myosi host add an equivalent:
grep -q '^root:' /etc/subuid || \
  echo 'root:1500000:200000' | sudo tee -a /etc/subuid /etc/subgid
sudo incus admin init --preseed < ~/mybox/incus.yaml

# ──  Build + import the mybox image  ─────────────────────────────
cd ~/mybox && just build
cid=$(sudo podman create localhost/mybox:latest)
sudo podman export "$cid" | zstd > /tmp/mybox.tar.zst; sudo podman rm "$cid"
#   (provide a minimal metadata.yaml, then:)
incus image import /tmp/mybox.tar.zst --alias mybox
#   or iterate against a stock image: images:archlinux

# ──  Launch (compose profiles for the features you want)  ────────
incus launch mybox mybox -p default -p gui -p gpu -p nvidia
#   -p lan          # own LAN IP (macvlan on enp1s0)
#   -p virt         # KVM/libvirt inside
#   -p shared-folder

# ──  Enter / inspect  ────────────────────────────────────────────
incus shell mybox                       # admin shell
incus exec mybox -- systemctl --failed
# ssh -p 2222 user@<container-ip>    # once sshd is up

# ──  NVIDIA userland (matches host driver)  ──────────────────────
incus exec mybox -- mybox install-nvidia

# ──  Autostart at boot  ──────────────────────────────────────────
incus config set mybox boot.autostart=true

# ──  Stop / destroy  ─────────────────────────────────────────────
incus stop mybox
# incus delete mybox
```

The nspawn (secondary) quick start is under **raw build & run → nspawn**
below; export the rootfs with `podman export` into /var/lib/machines/mybox.

## Rootful podman quadlet

`mybox.container` is the ONLY podman quadlet — system-level rootful
at `/etc/containers/systemd/`. Rootless mode was dropped: too limited
for the "full system container" use case (no own LAN IP, broken
nested incus/nspawn, no autostart-at-boot with systemd-homed,
EPERMs on `:idmap` mounts).

For ad-hoc rootless `podman run` (one-off testing), run the image
directly — no quadlet, no persistence:

```bash
podman run --rm -it --systemd=always --userns=auto \
    --cap-add=SYS_ADMIN --security-opt=label=disable \
    localhost/mybox:latest
```

### `just` recipes

The justfile builds the image and drives the unit. It does **not** run
podman by hand — everything about how the container is composed lives in
the quadlet and its drop-ins.

| Recipe | What it does |
|---|---|
| `just build` | build the OCI image into the **rootful** store (the one the system quadlet reads) |
| `just install [drop-ins…]` | symlink `mybox.container`, the `.network` file and the chosen drop-ins into `/etc/containers/systemd`, then `daemon-reload` |
| `just start` / `stop` | `systemctl start` / `stop` — stop **removes** the container; `/srv/<name>` state survives |
| `just restart` | `daemon-reload` + `restart` — recreates against the current image and drop-ins |
| `just status` | unit state + container state + LAN IP |
| `just logs` | `journalctl -fu <unit>` |
| `just enter [user]` | fast shell, `podman exec` (no PAM session) |
| `just login [user]` | full PAM/logind session (`login -f`) |

`install` is declarative: it links exactly the drop-ins you name and
removes any it previously linked that you did not, so switching e.g.
`31-nvidia-raw` → `30-nvidia` cannot leave both active. Symlinks (not
copies) mean edits in this repo apply on the next `daemon-reload`.
Hand-written drop-ins that do not point into this repo are left alone.

```bash
just build && just install && just start
just install 01-persist-root 05-user 10-gui 30-nvidia   # explicit set
just build && just restart                              # rebase onto a new image
```

### Configuration

Only these knobs belong to the justfile — everything else is quadlet
configuration:

| Var | Default | Purpose |
|---|---|---|
| `MYBOX_IMAGE` | `localhost/mybox:latest` | OCI tag to build |
| `MYBOX_CONTAINER` | `mybox` | quadlet unit name (`<name>.container` → `<name>.service`, state at `/srv/<name>`) |
| `MYBOX_USERNAME` | `user` | default user for `enter` / `login` |
| `MYBOX_NETFILE` | `mybox-bridge.network` | `.network` file installed beside the quadlet |
| `MYBOX_DROPINS` | see justfile | default drop-in set for `just install` |

**Everything else is a drop-in.** Network, GUI sockets, GPU/NVIDIA,
devices, capabilities, userns and persistence are all expressed in
`container/*.conf` — edit the file, `just restart`. The image bakes **no
login user**: `mybox-user-setup.service` creates it at boot from
`MYBOX_USER` / `MYBOX_UID` / `MYBOX_GID` / `MYBOX_SHELL`, supplied by
`05-user.conf` or `/srv/<name>/container.env` (see
`container.env.example`).

## Security posture

mybox runs as a **rootful** podman container — the quadlet is a
system-level unit — but "rootful" only means the `podman` CLI runs as
root. The container workload is **not** host root:

- **`--userns=auto:size=200000`** is the load-bearing control.
  Container UID 0 maps to host UID ~2000000, user (UID 1000) to
  ~2001000. Every capability the container holds is *namespaced* — it
  grants nothing over host-owned files, devices, or processes. Same
  boundary incus (`security.idmap`) and nspawn (`PrivateUsers=`) use.

The relaxations are trimmed to the minimum systemd PID 1 + nested
rootless podman need. **Validated on metal** (Fedora host, SELinux
Enforcing, GTX 1070): the hardened profile boots with **zero failed
units** and the exact same running set as the old fully-relaxed
profile, and default seccomp permits bwrap, `unshare -Urm` + `mount`,
flatpak, and nested rootless+rootful podman — nothing regressed.

| Knob | State | Why |
|---|---|---|
| `--userns=auto:size=200000` | on | container root ≠ host root (verified: pid1 maps to host uid ~2200000) |
| default seccomp profile | **kept** (was `unconfined`) | biggest kernel-attack-surface cut; validated to allow systemd + nested podman + bwrap + flatpak |
| `/proc` masking | **kept** (dropped `unmask=/proc/*`) | keeps `/proc/{kcore,sysrq-trigger,kallsyms}` masked; `--systemd=always` mounts what PID 1 needs |
| `SYS_PTRACE` | **dropped** | only cross-process debugging used it; no regression |
| `SYS_ADMIN SYS_NICE MKNOD` | kept | systemd/mounts/nesting, scheduling, nested device nodes |
| `NET_ADMIN` + `NET_RAW` | **dropped from the base** | nothing in the base used them: `eth0` is configured host-side by podman/netavark and shows as `unmanaged` inside, and nested rootless podman gets its own `CAP_NET_ADMIN` in the userns it creates. Verified by A/B on a live box — with them present the runtime user still had `CapPrm=0` and `ping` still failed, because `ping` carries no file capabilities to elevate with, so removing them regressed nothing. The features that need them add them back themselves: `40-virt.conf`, `70-vpn.conf` (quadlet appends `AddCapability=` to the base list) |
| `/dev/fuse` + `/dev/net/tun` in the base | kept | nested **rootless** podman: fuse-overlayfs storage and pasta networking. Devices only — no capabilities are added for this. Rootless podman runs as the unprivileged user, whose capability set is empty; it gains `CAP_NET_ADMIN` inside the nested userns it creates for itself, exactly as on any ordinary host. Without `/dev/net/tun` every rootless `podman run` fails with `pasta failed … Failed to open() /dev/net/tun` |
| `--security-opt=label=disable` | **kept** — the one remaining hole | required: `container_t` was tested and mybox fails to boot under it on an Enforcing host |

**Remaining relaxation — SELinux.** `label=disable` turns off the MAC
layer, so on an *enforcing* host there is no second wall if the userns
boundary breaks. On a SELinux-disabled host it is a no-op. Tested on an
Enforcing host: `--security-opt=label=type:container_t` makes mybox
**fail to boot** (systemd never reaches ready, bwrap breaks), so
`label=disable` stays until a dedicated mybox SELinux policy module
exists. This is the single knowingly-open item.

**Store note.** Rootful `podman` and rootless `podman` keep SEPARATE
image stores. The system quadlet reads the **rootful** store, so
`just build` uses `sudo podman build`. An image built by a plain rootless
`podman build` is invisible to it and the unit would fail to start.

**Suitability.** Fine for a daily-driver box running *your own*
workloads on *your own* hardware — the userns boundary is real and
standard. Run untrusted code only *nested* behind mybox's own rootless
podman (a second userns), never as mybox's own PID tree. Do not expose
the container's sshd to the public internet with this profile.

### Prereq host setup (one-time)

```bash
# Containers subuid pool — myos / myosi hosts already ship it.
# On other hosts:
echo 'containers:2000000:1000000' | sudo tee -a /etc/subuid /etc/subgid
sudo useradd -r -s /usr/sbin/nologin containers 2>/dev/null || true

# DHCP proxy for IPAMDriver=dhcp networks (bridge / macvlan)
sudo systemctl enable --now netavark-dhcp-proxy.socket
```

### Install + start

```bash
just build          # image into the rootful store
just install        # symlink quadlet + network + default drop-ins, daemon-reload
just start          # systemctl start mybox.service
just status         # unit + container + LAN IP
```

`just install` takes an explicit drop-in set when you want one — it links
exactly what you name and removes any it previously linked:

```bash
just install 01-persist-root 02-persist-home 03-persist-srv \
             05-user 10-gui 20-gpu 30-nvidia
```

Edit `05-user.conf` for the runtime user (`MYBOX_USER=<you>`) or wire
`/srv/mybox/container.env` instead. State dirs under `/srv/mybox` are
created and seeded from the image factories automatically on first start.

Quadlets cannot be `systemctl enable`d — the generator wires boot from the
unit's `[Install]` section, so `just start` once is enough and it comes
back on every boot.

The equivalent by hand, if you would rather not use the recipes:

```bash
sudo cp ~/mybox/mybox.container /etc/containers/systemd/
sudo cp ~/mybox/container/mybox-bridge.network /etc/containers/systemd/
sudo mkdir -p /etc/containers/systemd/mybox.container.d
sudo cp ~/mybox/container/0{1,2,3,5}-*.conf \
        /etc/containers/systemd/mybox.container.d/
sudo systemctl daemon-reload && sudo systemctl start mybox.service
```

### Enter

```bash
sudo podman exec -it -u <user> mybox /usr/bin/fish -l
# or via LAN IP (with bridge / macvlan):
ssh -p 2222 <user>@<container-ip>
```

### Network options (pick ONE .network file)

| File | Driver | LAN reach | Requires |
|---|---|---|---|
| `mybox-bridge.network` | bridge (joins existing `br0`) | ✅ real LAN IP, same as libvirt VMs | `br0` set up on host |
| `mybox-macvlan.network` | macvlan on physical NIC | ✅ own LAN IP | NIC NOT enslaved to bridge |
| `mybox-managed.network` | podman-managed bridge + NAT | ⚠️ via PublishPort= forwarding | works anywhere |
| (no file, `Network=host`) | shares host netns | ✅ host's IP, sshd at `<host>:2222` | works anywhere |

Edit `Network=` in `mybox.container` to switch. Drop-ins can also
override with `Network=` (empty) + new value.

### Drop-ins

`mybox/container/` snippets layer on top of the base quadlet:

```bash
sudo mkdir -p /etc/containers/systemd/mybox.container.d
sudo cp ~/mybox/container/30-nvidia.conf \
        ~/mybox/container/70-vpn.conf \
        /etc/containers/systemd/mybox.container.d/
sudo systemctl daemon-reload
sudo systemctl restart mybox.service
```

**NVIDIA + Vulkan: `/dev/nvidia-modeset` is mandatory.** On the raw path
(`31-nvidia-raw.conf`) it is easy to assume that node is only for
display/KMS and can be skipped. It is not — without it the NVIDIA driver
**segfaults inside `vkCreateDevice`**. Everything up to that point still
works, which makes it look like a GUI or Wayland problem: `nvidia-smi`
reports the GPU, and `vkcube` prints `Selected GPU 0: … DiscreteGpu`
before dying with SIGSEGV. `vulkaninfo` crashes the same way with no WSI
at all, which is what localises it to device creation rather than
presentation. The drop-in ships it as `AddDevice=-/dev/nvidia-modeset` —
the leading `-` makes quadlet include it when present and skip it on
headless hosts. The device list now matches the host CDI spec exactly.

## Why multiple variants of "the same" thing

|  | podman (`just`, primary) | incus | nspawn |
|---|---|---|---|
| Strength | Direct `podman` via `just` — persistent container, validated end-to-end | Real-root daemon: idmapped mounts, lxcfs, pools, migration | systemd-native, no daemon, file-only |
| Best for | **Daily-driver GUI + nested podman + gaming** | Fleet / storage pools / live-migrate | Daemonless immutable-image box |
| Image | OCI image in podman storage (`just build`) | rootfs/OCI import → pool volume (CoW; `state-binds` profile) | `RootImage=` EROFS/squashfs + verity, or a dir |
| Enter | `just enter` / `just login` (PAM) | `incus shell mybox` | `machinectl shell <user>@mybox` |
| Auto-start | quadlet `[Install]` (generator; `just start` once) | `boot.autostart=true` | `systemd-nspawn@mybox.service` |
| NVIDIA | all `/dev/nvidia*` + `sudo mybox install-nvidia` | raw devices + `mybox install-nvidia` | raw devices + `mybox install-nvidia` |
| GUI host sockets | `/mnt/host` bind → relink after logind (no hook) | `shift=true` (no hook) | `Bind=...:idmap` (no hook) |
| Flatpak / nested crun | works (default seccomp + `proc-unmask`) | works out of the box | needs `proc-unmask.service` |
| Nested podman (rootless+rootful) | yes (rootful, `userns=auto:size=200000`) | yes (first-class) | yes (with drop-ins) |
| Nested KVM / libvirt | yes (`/dev/kvm`) | yes | yes |

The podman quadlet is the primary path — validated end-to-end for GUI +
nested podman + NVIDIA + macvlan. incus and nspawn run the same image
manually (configs kept in the tree, not wired into the recipes). Raw LXC was removed — it required a bespoke real-root hook for
host sockets and the `proc-unmask` workaround, with none of incus's
daemon benefits.

All variants ship the CLI + recipes + GUI environment baked into the
image at `system/usr/local/bin/mybox`, `system/usr/share/mybox/just/`,
and `system/etc/environment.d/gui.conf`. A recipe written once works
under any runtime.

## In-container CLI and env (baked into image)

### `system/usr/local/bin/mybox` — in-container dispatcher

Parallel to the host-side `myosi` CLI. Scans
`/usr/share/mybox/just/*.just`, builds a transient justfile, execs
`just` against it. No state on disk inside the container — recipes
are mounted read-only from this repo.

Inside any mybox variant:

```bash
mybox                  # list available recipes
mybox install-nvidia   # match host driver via official .run installer
```

`just` must be in the container's PATH. Per-distro install:

| Distro | Command |
|---|---|
| Fedora / RHEL | `dnf install -y just` |
| Arch | `pacman -S --noconfirm just` |
| Debian / Ubuntu | `apt install -y just` (or fetch from github) |
| Alpine | `apk add just` |
| openSUSE | `zypper install -y just` |

### `system/usr/share/mybox/just/` — recipe modules

Slot convention: `00-49` base recipes shipped with the repo, `50-99`
extras you can drop in.

| Recipe | What it does |
|---|---|
| `install-nvidia` | Detects host driver version via `/sys/module/nvidia/version`, picks a package manager from `/etc/os-release` `ID` + `ID_LIKE` (dnf/apt/pacman/zypper/apk), installs deps, downloads matching `NVIDIA-Linux-x86_64-<ver>.run`, runs it with `--no-kernel-modules`. Re-run for upgrades — `nvidia-installer --silent` replaces in place. |

### `system/etc/environment.d/gui.conf`

PAM `/etc/environment` for GUI containers. Read by `pam_env` on
every login session (getty, ssh, `machinectl login`, `incus
console`, desktop, `su -l`) — so wayland / pipewire / pulse / X11
env vars are set for ALL login shells without per-shell rc files.

## `nspawn/` — service drop-ins

systemd-nspawn supports drop-ins for the SERVICE that wraps it
(`systemd-nspawn@<machine>.service.d/*.conf`) but NOT for the
`.nspawn` settings file (`config_parse()` in
`src/nspawn/nspawn-settings.c` reads a single file; no `.nspawn.d`
support). So all per-feature toggles that need cgroup
`DeviceAllow=` policy live as service drop-ins here:

| Drop-in | What it allows |
|---|---|
| `40-gpu-nvidia.service.conf` | `DeviceAllow=` for `/dev/nvidia*` |
| `50-input.service.conf` | `/dev/input`, `/dev/uinput`, `/dev/tty[0-9]+` (compositor inside) |
| `60-virt.service.conf` | `/dev/kvm`, `/dev/net/tun`, `/dev/vhost-{net,vsock}` |

Install per-feature:

```bash
sudo install -D -m 0644 ~/mybox/nspawn/40-gpu-nvidia.service.conf \
    /etc/systemd/system/systemd-nspawn@mybox.service.d/40-gpu-nvidia.conf
sudo systemctl daemon-reload
```

The `.nspawn` file itself (`mybox.nspawn`) carries inline comments
calling out which drop-in goes with each `Bind=` block.

## Build & run

### podman (OCI)

Same as [Install + start](#install--start) above:

```bash
just build && just install && just start
just login          # full PAM session as the runtime user
```

Note `just build` uses `sudo podman build` on purpose — the system
quadlet reads the rootful image store, and rootful/rootless podman keep
separate stores.

Runtime user config (`MYBOX_USER`, `MYBOX_UID`, `MYBOX_GID`,
`MYBOX_SHELL`) reaches `mybox-user-setup.service` through the container
env — quadlet `Environment=` lines, `EnvironmentFile=/srv/<name>/
container.env`, or `-e` flags. PID 1 does not propagate env to units,
so the service reads `/proc/1/environ` itself.

The Containerfile installs CLI essentials (fish, git, just, eza,
bat, ripgrep, fzf, fd, zoxide, starship, btop, ncdu, jq, tree,
tmux, neovim, curl, rsync, unzip) + rootless-podman prereqs
(subuid + newuidmap setcap + crun + fuse-overlayfs + slirp4netns +
passt). Install `podman` inside on demand: `podman exec -it mybox
pacman -S --noconfirm podman`.

### sshd inside

Container runs sshd on **port 2222** (not 22) because
`Network=host` shares the host's network namespace — the host's own
sshd already owns port 22. Drop your pubkey into the user's
`~/.ssh/authorized_keys` (the home volume bind survives image
rebuilds), then `ssh -p 2222 user@localhost`.

### UID shifting (myosi-style)

Quadlet uses `--userns=auto:size=200000`, parallel to
`security.idmap.size=200000` (incus) and
`PrivateUsers=1100000:200000` (nspawn). Container UID 0 maps to a
fresh host UID base (NOT host UID 0); container UID 1000 (user)
maps to host `<base>+1000` (NOT host UID 1000). Security boundary
stays intact even if a process inside escapes its userns.

Bind volumes carry `:idmap` — VFS-layer translation, no on-disk
chown — so host UID 1000 ownership appears as container UID 1000
inside. Files created inside as user land on disk as host UID
1000 (visible / editable from the host).

Host prereq: `/etc/subuid` must include a range ≥ 200000 for the
rootless user, e.g.:

```
<user>:100000:200000
<user>:300000:200000   # second container, etc.
```

### /etc factory pattern (myosi-style)

Build-time flow (mirrors the myosi build):

1. pacman installs every package — populates `/etc` with stock
   defaults (`/etc/passwd`, `/etc/ssh/sshd_config`, etc.).
2. `COPY system/etc /etc` lays our drop-ins on top
   (`50-mybox.conf` for sshd / systemd PID 1, `locale.{conf,gen}`).
3. Build steps apply masking symlinks and preset state. Every write
   lands in `/etc`. (NO user is baked — `mybox-user-setup.service`
   creates it at boot from `MYBOX_*` env.)
4. Final RUN snapshots the fully-populated `/etc` to `/usr/share/factory/etc` AND
   `/var` to `/usr/share/factory/var` as the immutable factory trees.

Both live trees and their factories exist in the shipped image with
the same content. The default container runs straight from `/etc` +
`/var` — no seed needed.

Runtime flow:

| Case | `/etc` state | `mybox-etc-seed.service` |
|---|---|---|
| Default (no bind) | image-populated | `ConditionDirectoryNotEmpty=!/etc` fails → **skipped** every boot |
| Persistent host bind, empty first boot | empty | condition matches → `cp -a /usr/share/factory/etc/. /etc/` copies factory tree → /etc populated |
| Persistent bind after first boot | user-populated | condition fails → **skipped** every boot, user state preserved |

Seed runs **at most once** per persistent /etc bind (when first
mounted empty). It never overwrites a populated /etc. Same
semantics as `myosi-etc-seed.service` (initrd-side) — exact
parallel. `mybox-var-seed.service` mirrors it for `/var` from
`/usr/share/factory/var`.

**Podman-path caveat:** PID 1 reads `/etc` (machine-id, preset + mask
symlinks) before ANY unit runs, so the quadlet/justfile paths pre-seed
an empty `/etc`/`/var` bind from the HOST side (`ExecStartPre`
throwaway container) and the in-container seeds become no-ops. The
in-container services are the mechanism for incus/nspawn binds and the
fallback if the pre-seed is skipped. `/usr`-side target drop-ins
(`sysinit.target.d/50-mybox-state.conf`,
`multi-user.target.d/50-mybox-core.conf`) keep the core services wired
even on a boot where `/etc` arrived empty.

Persistence is wired by `container/01-persist-root.conf` — see the
root-model table at the top.

### nspawn (system container)

```bash
sudo cp ~/mybox/mybox.nspawn /etc/systemd/nspawn/
sudo machinectl start mybox
sudo machinectl shell <user>@mybox
```

Per-feature drop-ins go under
`/etc/systemd/system/systemd-nspawn@mybox.service.d/` (see
`nspawn/` section above).

### incus (system container) — manual

```bash
sudo incus admin init --preseed < ~/mybox/incus.yaml
incus launch images:archlinux mybox -p default -p gui -p gpu -p nvidia
incus shell mybox
# inside (any distro w/ `just`):
mybox install-nvidia
```

## Layering custom variants

Drop a sibling at `mybox/<variant>/Containerfile` with `FROM
localhost/mybox:latest` for podman variants, a `<variant>.nspawn`
for nspawn, or a new incus profile composition. All inherit the
shared CLI + env binds.

Naming convention (parallel to myosi sysext stacking):

| Variant | Adds |
|---|---|
| `mybox-dev` | gcc, rustup, go, python toolchain |
| `mybox-virt` | libvirt + qemu, needs `/dev/kvm` |
| `mybox-game` | steam, lutris, nvidia userland, wayland binds |
| `mybox-gpu` | minimal nvidia/cuda CDI consumer for compute jobs |

## Compared to `myos/` and `myosi/`

| Project | Scope |
|---|---|
| `myos/` | Host OS — Fedora bootc image with custom desktop + sysexts. Boots the metal. |
| `myosi/` | Host OS — mkosi-built immutable image with verity + UKI + repart. Boots the metal. |
| `mybox/` | User container — runs ON `myos` / `myosi` (or any host) via podman / nspawn / incus. Does not boot the metal. |

Different layers of the stack. `mybox` is what you live inside on
top of `myos` / `myosi`.
