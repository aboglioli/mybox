# mybox

Daily-driver system container: an Arch Linux image with systemd as
PID 1, running as a **rootless podman user quadlet** on top of an
immutable host OS (sibling projects [myos](https://github.com/aboglioli/myos)
/ [myosi](https://github.com/aboglioli/myosi), or any Linux host with
podman ≥ 5). `mybox.container` plus `container/*.conf` drop-ins are
copied under `~/.config/containers/systemd`, and the owning account's
systemd user manager owns the lifecycle. Nothing about it is host root.

It is intended to feel like a small user OS, not an app container:
real login sessions, SSH, background services, rootless and rootful
podman inside, Flatpak, the GPU through CDI with nothing installed
inside, KVM, and a gaming variant with Steam and Proton.

```
mybox/
├── Containerfile                # base image (Arch Linux + systemd PID 1)
├── gaming/                      # gaming variant, FROM the base
│   ├── Containerfile
│   └── system/                  # mybox-nvidia32 (32-bit NVIDIA userland)
├── justfile                     # build images + install/drive the quadlet
├── mybox.container              # rootless user quadlet (minimal base)
├── container.env.example        # MYBOX_* runtime config template
├── container/                   # quadlet drop-ins (see container/README.md)
└── system/                      # image config tree (Containerfile COPY)
    ├── etc/                     # → /etc (snapshotted to /usr/share/factory/etc)
    └── usr/                     # → /usr (immutable at runtime)
        ├── lib/systemd/         # units, presets, target drop-ins
        ├── libexec/mybox/       # preinit (root assembly), user-setup, …
        ├── local/bin/mybox      # in-container CLI dispatcher
        └── share/mybox/
            ├── just/            # in-container recipes
            └── user-groups.d/   # extra groups for the runtime user
```

## Root model

Immutable image + writable state, one pattern everywhere: **every tree
the image owns is an overlay of image-lower + host-upper, and every
upper lives in a single host bind**. `/usr/libexec/mybox/preinit`
assembles them as PID 1 and then execs systemd. The container is
disposable — quadlet removes and recreates it on every stop/restart/
boot; nothing of value lives inside it.

| Host | In container | Mechanism |
|---|---|---|
| `/srv/users/<uid>/<name>` | `/.mybox` | the one state bind — holds every overlay upper. Never itself overlaid |
| `/srv/users/<uid>/<name>/etc/diff` | `/etc` | overlay upper; **lower is the image's `/etc`** |
| `/srv/users/<uid>/<name>/usr/diff` | `/usr` | overlay upper; lower is the image's `/usr` — pacman installs, NVIDIA userland |
| `/srv/users/<uid>/<name>/var` | `/var` | **plain bind** — no image layer worth keeping |
| `/srv/users/<uid>/<name>/opt` | `/opt` | **plain bind** — the image ships nothing here |
| `/srv/users/<uid>/<name>/var/lib/containers` | `/var/lib/containers` | ordinary subdirectory of the `/var` bind |
| `/srv/users/<uid>/<name>/var/lib/flatpak` | `/var/lib/flatpak` | ordinary subdirectory, same |
| `/srv/users/<uid>/<name>/home` | `/home` | raw bind — user data, no image content to layer |
| `/srv/users/<uid>/<name>/srv` | `/srv` | raw bind, empty by contract — nested-quadlet service data |
| `/srv/users/<uid>/<name>/container.env` | env for PID 1 | optional `MYBOX_*` runtime config |

**Only `/etc` and `/usr` are overlays.** Those are the trees whose image
content is worth layering under. `/var` and `/opt` are plain binds: the
image ships 5 files and 5 symlinks in `/var` (the rest is empty
directories) and nothing at all in `/opt`, and `tmpfiles.d` rebuilds what
matters on every boot. That removes a whole mechanism — with `/var` bound
directly, the bulk payloads are ordinary subdirectories instead of binds
punched back through an overlay.

**Nothing is seeded.** The image tree *is* the lower, so an empty upper
is already a complete `/etc` — 116 entries on first boot. The seed
services and the host-side seed containers are gone, and so is their
worst property: a newer image's `/etc` changes now reach an existing
box instead of being frozen at whatever was copied once. Files you edit
copy up and keep winning; files you never touched track the image.

**Why one state bind rather than an upper inside each tree.** The kernel
refuses overlayfs as an upperdir, so an upper cannot live under a tree
that is itself overlaid — putting `/usr`'s upper in `/var/lib/mybox`
stops working the instant `/var` becomes an overlay. A bind that is
never overlaid removes the ordering problem entirely: there is no tree
that must be mounted before the thing holding its own upper. (This is
the chicken-and-egg that kept `/etc` a plain mount in sibling myosi,
where no such host bind exists before PID 1.)

**Why a pre-init and not a unit.** PID 1 reads `/etc` — machine-id,
preset symlinks, masks — before any unit can run, so an `/etc` overlay
mounted by a service is already too late. The pre-init mounts everything
and `exec`s systemd, which keeps it PID 1. It is the initrd pattern
without the initrd; podman still treats the container as a systemd one
because `--systemd=always` is explicit.

**Box root owns the trees, whoever created them.** The host account
creates `home/` and `srv/` before the box exists (podman needs bind
sources), and keep-id makes that account the box's login user. The
pre-init therefore takes every tree directory and overlay upper for root
before mounting it — otherwise `/var` would be the user's to write, an
overlay root takes its upper's owner, and systemd-tmpfiles refuses every
path below a user-owned `/var` as an unsafe transition, silently skipping
`/var/lib/pacman`. Only the directories themselves; their contents were
written from inside.

Inside, `/root` symlinks to `/var/roothome` and `/var/lib/pacman` to
`/usr/lib/pacman`, so both ride their tree's overlay. `/run`, `/tmp` and
`/var/tmp` are tmpfs, wiped every start. The **journal is persistent**:
podman puts a tmpfs at `/var/log/journal`, but the pre-init deliberately
does not park it, so `/var` owns the path and the journal survives a
restart — which is what you want when debugging why it restarted.

**Tooling outside the container sees the IMAGE's `/etc`, not yours.** The
overlays exist only inside the container's mount namespace, so anything
resolving from the host side reads the pristine image tree. The one place
that bites is `podman exec -u <name>`, which looks the name up in the
image's `/etc/passwd` — where the runtime user deliberately does not
exist — and fails with `unable to find user`. `podman exec -u 1000`
works, and `just enter` resolves the name inside with `runuser`. Anything
running *in* the container (sshd, login, su, systemd) is unaffected.

**The pristine lower stays reachable.** Once an overlay is mounted its
lower has no name left, so the pre-init publishes each one read-only at
`/run/mybox/lower/<tree>` first. That is the actual lower rather than a
copy of it, so "what has this box changed?" is answerable from inside
and cannot drift from what the box is really layered on:

```bash
mybox diff          # /etc versus its lower — user db, ssh host keys, …
mybox diff usr      # empty unless you installed something at runtime
mybox list          # same question, paths only, no content comparison
```

Use `mybox list`, not a bare `find /.mybox/etc/diff -type f`: a deleted
image file leaves a **whiteout** (a character device 0:0, not a regular
file), so `-type f` reports every deletion as "unchanged" — the one wrong
answer. `list` reads both.

Factory reset is per tree and non-destructive to data:
`rm -rf /srv/users/<uid>/<name>/etc/diff` while stopped resets configuration and
leaves `/home`, the flatpak apps and the container images alone. Only
`/etc` and `/usr` have a `diff` to reset; `/var` and `/opt` are plain
binds, so there you delete the path itself. For a
single path use `mybox reset <path>` instead, and `mybox prune` to drop
overrides that have stopped overriding anything after a rebase.

**The pre-init fails the container rather than boot a degraded box.** A
missing state bind, a tree that cannot be overlaid, or a bulk payload that
cannot be bound are all fatal: each would leave a box that looks fine and
silently loses every write to that tree at the next restart. The unit
fails with the reason in `journalctl --user -u <name>`.
Publishing the read-only lowers is the one exception — it only powers
`mybox diff`, so it warns and carries on.

## Quick start

A desktop box under your own account — its apps on your compositor, the
GPU through CDI:

```bash
just install        # copy quadlet + default drop-ins, daemon-reload
just build          # OPTIONAL: local build over the published reference,
                    # into YOUR rootless store; skip it and the quadlet
                    # pulls ghcr.io/aboglioli/mybox instead
just start          # or log in again: 10-gui starts it with the session
just status
just login          # full PAM session as the runtime user
```

Host prereqs: rootless podman with a subuid/subgid range of at least
200000 for your account (nested podman inside needs 165536 of them), and
a `/srv/users/<uid>` directory you own — the rootless half of the
myenv storage convention. On myosi both exist already.

| Recipe | What it does |
|---|---|
| `just build` / `build-gaming` | local build tagged over the published reference, into your rootless store |
| `just install [drop-ins…]` | **copy** quadlet + chosen drop-ins to `~/.config/containers/systemd`, `daemon-reload`. Declarative: removes previously-installed drop-ins not in the set |
| `just start` / `stop` | start/stop the unit — stop removes the container; the state survives |
| `just sync` | re-copy the installed unit files from this repo, without changing which drop-ins are selected |
| `just restart` | `sync`, then recreate against the current image + drop-ins |
| `just status` / `logs` | unit + container state / follow the journal |
| `just enter [user]` | fast shell (`podman exec`, no PAM session) |
| `just login [user]` | full PAM/logind session (`login -f`) |

Justfile knobs (env vars): `MYBOX_IMAGE`, `MYBOX_GAMING_IMAGE`,
`MYBOX_CONTAINER`, `MYBOX_USERNAME`, `MYBOX_DROPINS`. Everything else —
GUI, GPU, devices, image variant, runtime user — is a drop-in in
`container/` (see `container/README.md`). Persistence is not: it is part
of `mybox.container` and always on.

## Isolated box

Run the box under a **dedicated system account** that owns nothing but
the box. That is the shape for untrusted code — games from anywhere, a
future streaming server: whatever escapes the box lands as an account
with no home worth reading, no keys and no other services.

```bash
sudo useradd -r -m -d /var/lib/games -s /usr/sbin/nologin games
echo 'games:3000000:1000000' | sudo tee -a /etc/subuid /etc/subgid  # a free range
sudo install -d -o games -g games -m 0700 /srv/users/$(id -u games)
sudo loginctl enable-linger games        # its user manager starts at boot

sudo machinectl shell games@ /bin/bash   # a shell as games, with its user bus
git clone https://github.com/aboglioli/mybox && cd mybox  # your tree is not readable from here
MYBOX_CONTAINER=games just install 01-boot 02-gaming 20-gpu 30-nvidia
just start
```

`machinectl shell` rather than `sudo -u`: it opens a real session, so
`systemctl --user` and rootless podman find the account's runtime dir
and bus.

`01-boot.conf` starts it with that account's user manager, which linger
brings up at boot — no login involved. Verified end to end: restarting
the account's `user@<uid>.service` brought the box up on its own, with
the GPU, the 32-bit NVIDIA service and box root at the account's first
subuid.

The account's sockets are not your desktop's, so this shape is headless:
no `10-gui.conf`. Make sure your own state is not world-readable, or
the isolation stops at file permissions: `/srv/users/<uid>` and
anything holding keys should be `0700`.

## Installing by hand

Every file is **correct exactly as it sits in this repo**. `just install`
copies them and generates nothing, so `cp` by hand gives a
byte-identical install:

| Repo file | Installs to |
|---|---|
| `mybox.container` | `~/.config/containers/systemd/<name>.container` |
| `container/<drop-in>.conf` | `~/.config/containers/systemd/<name>.container.d/` |

```bash
Q=~/.config/containers/systemd
mkdir -p $Q/mybox.container.d
cp mybox.container $Q/
cp container/10-gui.conf container/20-gpu.conf container/30-nvidia.conf \
   container/85-publish-ssh.conf $Q/mybox.container.d/
systemctl --user daemon-reload
systemctl --user start mybox
```

**Running it under another name is pure file naming.** `%p` resolves to
the new name everywhere, including every `/srv/users/%U/%p` path:
`games.container` + `games.container.d/` is an independent box with its
own state. Two boxes on one host need different `PublishPort=` host
ports; nothing else clashes.

Check what the generator really does:

```bash
/usr/lib/systemd/user-generators/podman-user-generator --dryrun | grep -A3 Loading
systemctl --user cat mybox.service
```

## Start model

One unit, and the drop-in set decides when it starts:

| Drop-in | Starts with | For |
|---|---|---|
| `10-gui.conf` | `graphical-session.target` | a desktop box under your own account |
| `01-boot.conf` | `default.target` of the owning user manager | headless: the isolated account, or yours with linger |
| neither | `just start` only | |

The GUI box is **started by the session and ends with it**: the target is
reached once the compositor is up and its sockets exist, and `PartOf=`
stops the box when the session goes. A compositor restart stops and
re-reaches the target, so the box comes back on the new sockets instead
of holding dead ones. The two-instance template, the host `.path` trigger
and the guard condition of the rootful layout are all gone — they existed
to bridge a system unit to a user session, and a user unit is already in
the session.

The two do not mix: `default.target` is reached before the compositor
creates its sockets, and podman hard-fails a start on a missing bind
source.

## Runtime user + SSH keys

The image bakes NO user. `mybox-user-setup.service` creates one at boot
from env — with no env at all you still get a default user
(`user` / 1000 / 1000 / fish). Keep uid 1000: keep-id maps exactly that
box uid to the owning host account, whatever its own uid is.

```
MYBOX_USER / MYBOX_UID / MYBOX_GID / MYBOX_SHELL
MYBOX_AUTHORIZED_KEYS      comma-separated ssh keys
```

Set them in `/srv/users/<uid>/<name>/container.env`, which the quadlet loads and
creates empty on first start — per instance, no wiring (see
`container.env.example`). A `*.container.d` drop-in's `Environment=`
overrides it, which is why the shipped `05-user.conf` keeps its lines
commented. `MYBOX_AUTHORIZED_KEYS` is
synced every boot to `/etc/ssh/authorized_keys.d/<user>`; sshd reads
that alongside `~/.ssh/authorized_keys`. Local alternative — bind-mount
a host file instead:

```
Volume=/srv/users/%U/mybox/authorized_keys:/etc/ssh/authorized_keys.d/<user>:ro
```

sshd listens on **port 2222**, published on the host by
`85-publish-ssh.conf`. Auth is
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

## Networking

`Network=pasta`: the box shares the host's addresses and reaches whatever
the owning account can. Inbound is through `PublishPort=` —
`85-publish-ssh.conf` maps the box's sshd to `<host>:2222`; copy its
shape for anything else you serve.

Rootless cannot give the box its own LAN address: no macvlan, no port on
the host's bridge, no static IP or MAC. The `.network` files and the
static-address drop-ins of the rootful layout are gone with it. DNS is
baked into the image (resolved.conf.d + nsswitch `resolve`).

## GPU

`20-gpu.conf` binds `/dev/dri`, `/dev/snd` and `/dev/input`;
`30-nvidia.conf` adds the NVIDIA GPU through **CDI**. Rootless podman
has no device cgroup, so the host's own permissions decide what opens:

- render nodes, `/dev/nvidia*`, `/dev/kvm`, `/dev/fuse` and
  `/dev/net/tun` are `0666`;
- sound and game controllers open through the ACLs logind's uaccess
  grants the seat's user — which keep-id makes the box user;
- **keyboards and mice do not**: verified on a laptop, neither box root
  nor the box user can open the keyboard's event node.

`/dev/input` and `/dev/snd` are bound as directories, so a controller
plugged in later appears inside. hidraw nodes cannot be bound that way;
Steam Input falls back to evdev.

**NVIDIA through CDI only.** Podman injects the device nodes and the host
driver's own userland — `libGLX_nvidia`, `libcuda`, the Vulkan and EGL
ICDs, `nvidia-smi` — so it always matches the host kernel module and
nothing is installed inside. Needs a CDI spec on the host
(`nvidia-ctk cdi list` → `nvidia.com/gpu=all`; the myosi nvidia sysexts
generate it at boot). The drop-in sets no `NVIDIA_*` environment on
purpose: CDI does not read it, and it is what wakes a legacy
`nvidia-container-runtime-hook` if a host still registers one.

Verified rootless on a desktop and a hybrid laptop with NVIDIA GPUs:
`nvidia-smi`, Vulkan, EGL and GLX on NVIDIA, and on the laptop EGL
through the host's niri.

**Hybrid laptops** render on the GPU the compositor uses, like any
desktop app; offload to NVIDIA per app with
`__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia` (Vulkan
apps and DXVK pick the discrete GPU themselves).

**32-bit** is the one thing CDI cannot do — specs carry no 32-bit
libraries. The gaming variant covers it, below.

## Gaming variant

`ghcr.io/aboglioli/mybox-gaming` is the base plus Steam, umu-launcher
(Proton for any Windows exe, outside Steam), gamescope, mangohud and the
32-bit GPU stack. Same box, different image: `02-gaming.conf` switches
`Image=`, and an existing box keeps its state.

```bash
just install 02-gaming 10-gui 20-gpu 30-nvidia 85-publish-ssh
```

**32-bit NVIDIA.** `mybox-nvidia32.service` reads the host driver version
from `/sys/module/nvidia/version`, takes NVIDIA's own `.run` for exactly
that version, extracts only its 32-bit libraries into `/usr/lib32` (the
`/usr` overlay, so they persist) and writes the 32-bit Vulkan ICD. It is
a no-op once the version matches, re-runs when the host driver changes,
and removes the previous version's files through a manifest. The first
boot after a driver change downloads ~400 MB; an offline boot just leaves
32-bit games without the GPU until the next one.

Verified with Steam's own `steam-runtime-system-info` inside
pressure-vessel, the container Steam runs games in: Vulkan and GLX on
NVIDIA for both i386 and x86_64. 32-bit EGL on X11 falls back to
llvmpipe — games use GLX or Vulkan, so it rarely matters.

**Not included: gamemode.** Rootless, the box's hard nice limit is 0 and
only host root can raise it, so gamemode cannot renice anything, and the
CPU governor it would set is host sysfs. Worse, its limits.d entry made
pam_limits fail every session of its group's members, user manager
included. The base now makes pam_limits optional for exactly this class
of package (see Security posture).

**A streaming server** (Sunshine or similar, streaming a compositor that
runs inside the box) fits the isolated account. Not shipped yet: it
needs `/dev/uinput`, which is root-only on the host and would have to be
granted to that account by a udev rule — and a uinput device is
host-global input.

## Security posture

Rootless end to end: the podman that creates the box is the owning
account's, and **no box uid maps to host root**.

| Knob | State | Why |
|---|---|---|
| rootless user quadlet | on | an escape lands in the owning account, never root |
| `UserNS=keep-id:uid=1000,gid=1000` | on | box uid 1000 = the owning account; box root = its first subuid, which owns nothing on the host |
| dedicated account (Isolated box) | optional | makes the owning account worthless too |
| default seccomp, `/proc` masking | kept | validated with systemd + nested podman + bwrap + flatpak + Steam's pressure-vessel |
| `SYS_ADMIN NET_ADMIN NET_RAW SYS_NICE` | kept | namespaced: the pre-init's overlays, systemd, nested podman (rootful inside needs `NET_ADMIN`), VPNs, ping, realtime audio. None reaches the host |
| no `MKNOD` | dropped | an unprivileged user namespace cannot create device nodes anyway |
| devices | host permissions | no device cgroup rootless; only what the owning account can open — not keyboards |
| `pam_limits` optional | on | the box cannot raise its own hard limits; a limits.d entry above them would otherwise lock every login out |
| `label=disable` | the one open item | `container_t` is denied the GPU's device nodes (NVML: "Insufficient Permissions") and breaks systemd's boot |

Under your own account the box is a strong boundary for what runs as box
root, and an ordinary one for what runs as the box user: that is you.
Run untrusted code under the isolated account, and nested behind the
box's own rootless podman (a second user namespace) on top of that.

Not covered by any of it: the kernel and the GPU driver are shared, as
with every container.

**Store note:** each account has its own rootless image store; the user
quadlet reads its owner's. `just build` builds into it.

**Moving from the rootful layout.** The old state under `/srv/<name>`
is owned by root-namespace ids, and its `/etc`, `/usr` and `/var` are
cheaper to rebuild than to re-own: copy `home/` (and `srv/`) to
`/srv/users/<uid>/<name>/` owned by you, let the overlays start empty,
re-pull nested images and flatpaks.

## Rebasing: what a new image changes on an existing box

Because every image-owned tree is an overlay with the image as the
lower, a rebase behaves the same way in `/etc` as it always has in
`/usr`:

| On the box | After pulling a newer image |
|---|---|
| file you never touched | **updated** — it is served from the new lower |
| file you edited | yours wins; the edit copied it up and the upper shadows the image |
| file only the new image ships | **appears** |
| file you deleted | stays deleted — the whiteout in your upper shadows it |

That is the property the old seeded-bind model could not offer: a
populated `/etc` was never re-seeded, so newly enabled units, new
`environment.d` drop-ins and edited defaults silently never arrived and
had to be reconciled by hand after every rebase. Now only what you
personally changed is pinned, and `mybox list`
tells you exactly what that is.

`ConditionNeedsUpdate=/etc` works again as a side effect — the `/usr`
lower is newer than the upper's `.updated` stamp after a rebase, so
`systemd-sysusers` and friends re-run on their own.

The image still snapshots `/usr/share/factory/{etc,var}`: systemd's own
`tmpfiles.d` copies from it, and it stays a useful reference to diff a
box against. Nothing seeds from it any more.

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
| system units | `50-mybox.preset` → `systemctl preset-all` at build → symlinks in the image's `/etc`, which is the overlay lower |
| user units (all sessions) | `systemctl --global enable` at build → `/etc/systemd/user/…`, same snapshot |

No exceptions and no bootstrap problem: the pre-init has already
assembled `/etc` before PID 1 reads a single symlink, so an enable
baked at build time is simply there on the first boot.

**`Upholds=` is not a stronger `Wants=`** — it re-asserts "keep active"
every time a unit goes inactive, so it busy-loops on `Type=oneshot` +
`RemainAfterExit=no` and on **any unit with a failable `Condition*=`**
(a skipped start counts as inactive). Not theoretical: in the sibling
myosi project one mis-wired condition unit produced 27,380 restarts in
4.8 h. It has a legitimate use — re-asserting a unit that arrives after
the boot transaction is frozen, which is what a sysext merge does — and
that is precisely the situation mybox does not have.

**`systemctl enable` sticks for runtime-installed units too.** This used
to be false: the `/usr` overlay was mounted by a service at sysinit,
i.e. after PID 1 had already frozen the boot job graph, so a unit that
arrived via `pacman -S` was a dangling enable symlink that boot dropped
with a warning and it needed one manual `systemctl start` per boot. The
pre-init mounts `/usr` before systemd exists, so the unit file is simply
there when the transaction is built — verified by installing a unit at
runtime, enabling it, and restarting the container: `active`, `enabled`.

Nothing optional is still wired in the base image, but for a different
reason: a drop-in naming `virtqemud.socket` is evaluated on EVERY box,
so one without libvirt logs `Unit not found` per unit per boot and
carries them forever in `systemctl list-units --state=not-found` — 19
phantom units for libvirt alone. Install the package, then
`systemctl enable --now` its units like on any other machine.

## In-container CLI

`mybox` (baked at `/usr/local/bin/mybox`) scans
`/usr/share/mybox/just/*.just` and execs `just` against a transient
justfile. Slot convention: 00-49 shipped, 50-99 local additions.

| Recipe | What it does |
|---|---|
| `list [tree]` | what this box changed, by path — `changed` from the upper's files, `deleted` from its whiteouts |
| `diff [tree]` | the same question with content, compared against the overlay's real lower |
| `reset <path>` | stop overriding one path so it follows the image again (restart to apply). `/etc` and `/usr` only |
| `prune [tree] [apply]` | find overrides that no longer override anything — upper files identical to the image, whiteouts hiding files it no longer ships |

Overlay trees are `etc` (default) and `usr`.

## License

MIT — see [LICENSE](LICENSE).
