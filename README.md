# mybox

Daily-driver system container: an Arch Linux image with systemd as
PID 1, running as a **rootless podman user quadlet** on top of an
immutable host OS (sibling projects [myos](https://github.com/aboglioli/myos)
/ [myosi](https://github.com/aboglioli/myosi), or any Linux host with
podman ≥ 5). The `mybox@.container` template plus `container/*.conf`
drop-ins are symlinked from this checkout into
`~/.config/containers/systemd`, and the owning
account's systemd user manager owns the lifecycle. Nothing about it is
host root. Every box is a named instance, `mybox@<name>.service`, and the
name is also its hostname, container name and state directory
(`/srv/users/<uid>/<name>`). The default box is `mybox`.

It is intended to feel like a small user OS, not an app container:
real login sessions, SSH, background services, rootless and rootful
podman inside, Flatpak, the GPU through CDI with nothing installed
inside, KVM. Apps beyond the base come from Flatpak, Homebrew or
pacman inside the box, not from extra images.

```
mybox/
├── Containerfile                # base image (Arch Linux + systemd PID 1)
├── justfile                     # build images + install/drive the quadlet
├── mybox@.container             # rootless user quadlet template, one instance per box
├── container.env.example        # MYBOX_* runtime config template
├── container/                   # quadlet drop-ins (see container/README.md)
├── host/mybox-gui.service       # HOST user unit: shares the session's sockets
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
fails with the reason in `journalctl --user -u mybox@<name>`.
Publishing the read-only lowers is the one exception — it only powers
`mybox diff`, so it warns and carries on.

## Quick start

A desktop box under your own account — its apps on your compositor, the
GPU through CDI:

```bash
just install        # box `mybox`: link template + default drop-ins, daemon-reload
just build          # OPTIONAL: local build over the published reference,
                    # into YOUR rootless store; skip it and the quadlet
                    # pulls ghcr.io/aboglioli/mybox instead
just start          # or log in again: 01-boot starts it with your user manager
just status
just login          # full PAM session as the runtime user
```

More boxes are more names, each with its own state, hostname and
drop-ins:

```bash
just install dev                                     # default drop-ins
just install games 01-boot 20-gpu 30-nvidia
just start games && just enter games
```

Only one box can publish SSH on host port 2222. Leave `85-publish-ssh`
out of the others, and give one its own port with a local drop-in. A
name that is not in `container/` is never touched by `just install`:

```bash
just install dev 01-boot 05-user 10-gui 20-gpu 30-nvidia
printf '[Container]\nPublishPort=2223:2222\n' \
  > ~/.config/containers/systemd/mybox@dev.container.d/86-ssh-port.conf
```

Host prereqs: rootless podman with a subuid/subgid range of at least
200000 for your account (nested podman inside needs 165536 of them), and
a `/srv/users/<uid>` directory you own — the rootless half of the
myenv storage convention. On myosi both exist already.

| Recipe | What it does |
|---|---|
| `just build` | local build tagged over the published reference, into your rootless store |
| `just install [name] [drop-ins…]` | **symlink** the template + the box's chosen drop-ins into `~/.config/containers/systemd`, `daemon-reload`. Declarative: removes previously-installed drop-ins not in the set. With `10-gui` it also links and enables `host/mybox-gui.service` |
| `just start` / `stop [name]` | start/stop the box — stop removes the container; the state survives |
| `just sync` | repoint every installed link at this checkout (and turn copies from older installs into links), then `daemon-reload` |
| `just restart [name]` | `sync`, then recreate against the current image + drop-ins |

The links point into the checkout you ran `just install` from, so an
edit there is live at the next `just restart`. Install from the checkout
you keep: deleting it (a worktree, say) leaves dangling units, and
switching its branch changes the box at its next restart. Editing an
installed drop-in edits the repo file; keep host-local settings in a
drop-in of your own name, as with the SSH port above.
| `just status` | unit + container state of every box |
| `just logs [name]` | follow the box's journal |
| `just enter [name] [user]` | login shell (`podman exec` + `runuser -l`): the account's shell, in its home, with `SHELL` set and your terminal's `TERM`/`COLORTERM` (truecolor) |
| `just login [name] [user]` | full PAM/logind session (`login -f`) |

`name` defaults to `mybox` and must be a valid hostname: lowercase
letters, digits and inner dashes. Justfile knobs (env vars):
`MYBOX_NAME`, `MYBOX_IMAGE`, `MYBOX_USERNAME`,
`MYBOX_DROPINS`. Everything else — GUI, GPU, devices, image variant,
runtime user — is a drop-in in `container/` (see `container/README.md`).
Persistence is not: it is part of `mybox@.container` and always on.

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
just install games 01-boot 20-gpu 30-nvidia
just start games
```

`machinectl shell` rather than `sudo -u`: it opens a real session, so
`systemctl --user` and rootless podman find the account's runtime dir
and bus.

`01-boot.conf` starts it with that account's user manager, which linger
brings up at boot — no login involved. Verified end to end: restarting
the account's `user@<uid>.service` brought the box up on its own, with
the GPU and box root at the account's first
subuid.

The account's sockets are not your desktop's, so this shape is headless:
no `10-gui.conf` (the hard links would be yours, and other accounts
cannot traverse your runtime dir). Make sure your own state is not world-readable, or
the isolation stops at file permissions: `/srv/users/<uid>` and
anything holding keys should be `0700`.

## Installing by hand

Every file is **correct exactly as it sits in this repo**. `just install`
symlinks them and generates nothing, so `ln -s` by hand gives the same
install:

| Repo file | Installs to |
|---|---|
| `mybox@.container` | `~/.config/containers/systemd/mybox@.container` |
| *(per box)* a symlink to it | `~/.config/containers/systemd/mybox@<name>.container` |
| `container/<drop-in>.conf` | `~/.config/containers/systemd/mybox@<name>.container.d/` |
| `host/mybox-gui.service` *(with `10-gui`)* | `~/.config/systemd/user/`, enabled |

```bash
Q=~/.config/containers/systemd
mkdir -p $Q/mybox@mybox.container.d ~/.config/systemd/user
ln -s "$PWD/mybox@.container" $Q/
ln -s mybox@.container $Q/mybox@mybox.container
for d in 01-boot 10-gui 20-gpu 30-nvidia 85-publish-ssh; do
  ln -s "$PWD/container/$d.conf" $Q/mybox@mybox.container.d/
done
ln -s "$PWD/host/mybox-gui.service" ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now mybox-gui.service
systemctl --user start mybox@mybox
```

**The instance name is the box.** `%i` resolves to it everywhere,
including every `/srv/users/%U/%i` path, so `mybox@games` is an
independent box with its own state, hostname and container name. The
symlink is what lets a box carry its own `[Install]` (`01-boot`) and its
own drop-ins. `systemctl --user start mybox@<name>` works without one,
but such a box gets only the drop-ins in the shared
`mybox@.container.d/`. Two boxes on one host need different
`PublishPort=` host ports; nothing else clashes.

Check what the generator really does:

```bash
/usr/lib/systemd/user-generators/podman-user-generator --dryrun | grep -A3 Loading
systemctl --user cat mybox@mybox.service
```

## Start model

**One box that is always the same box.** `01-boot.conf` starts it with
its owner's user manager — at login, or at boot with linger and for the
isolated account. Without it, only `just start` does.

The GUI is not a start mode but something that comes and goes **inside
a running box**:

```
box up        /mnt/host bound, empty: headless, sockets inside dangle
login         host mybox-gui.service hard links wayland/pipewire/pulse
              into %t/mybox-gui -> they appear at /mnt/host
              -> mybox-xwayland.path starts Xwayland, apps can draw
logout        mybox-gui.service removes the links; the box keeps running
compositor    the target stops and starts again, the links are renewed,
restart       new clients reach the new compositor
```

The box is never restarted for any of it — verified by starting
the box with no session sockets, bringing the links up and down twice,
and opening native Wayland, Xwayland, gamescope-nested and
NVIDIA-offloaded windows in niri each time, all on one container start.

That is the rootful layout's behaviour (boot headless, take the GUI at
login, hand it back at logout) without its machinery: the two-instance
template, the `Conflicts=`/`OnSuccess=` handover, the host `.path`
trigger and the guard condition are gone. They existed because a bind of
a socket needs the socket at container start and pins its inode
forever; a bound **directory** whose entries are hard links has neither
problem.

Hard links rather than binds or symlinks: the host side runs as you,
without privileges to bind-mount, and a symlink would point at a path
that does not exist inside the box. A hard link is the socket inode
itself, so `connect()` on it reaches the compositor.

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

## Homebrew

Every box gets Homebrew for its login user, at
`/home/linuxbrew/.linuxbrew`, the prefix its bottles are built for.
It is not in the image: `/home` is a bind that hides anything the image
puts there, and the prefix must belong to a user that only exists after
`mybox-user-setup`. `mybox-homebrew.service` installs it instead, on the
first boot with network, the way Homebrew documents a git install: a
clone of the brew repository, `brew update` for the latest release and
its portable Ruby, and a cleanup of the downloaded tarball. It takes a
minute or two, does not hold up the boot, and retries on the next boot
if it fails. Once `bin/brew` exists the unit skips itself.

Homebrew keeps the download of every installed version, and its own
cleanup never removes those. The box does not clean it: that is the job
of whatever manages your user environment — run `brew cleanup
--prune=all -s` now and then, or schedule it with your dotfiles.

It lives in the box's `/home`, so it survives restarts and image
updates, belongs to that one box, and is gone with the box's state.
fish and bash sessions get `brew shellenv` once it is there (not root:
brew refuses to run as root). Bottles need nothing else; a formula that
builds from source needs `brew install gcc` first.

```bash
journalctl -u mybox-homebrew        # inside the box: how the install went
```

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
`nvidia-smi`, Vulkan, EGL and GLX on NVIDIA; on the laptop, windows in
niri from native Wayland (`vkcube`), X11 through the box's Xwayland
(`glxgears`), a nested gamescope, and GLX offloaded to the discrete GPU.

**X11 apps** get Xwayland inside the box: the base ships
`xorg-xwayland` + `xwayland-satellite`, and `mybox-xwayland.path` starts
it on `DISPLAY=:0` whenever the host wayland socket is there. The host's
own `:0` is unreachable — niri keeps it as an abstract socket, which is
network-namespace scoped.

**Compositors inside the box** run as clients of the host's (gamescope,
sway or niri nested in a window) or headless (`gamescope --backend
headless`, for streaming). One that takes over the screen from a TTY is
gone with the rootful layout: rootless cannot become DRM master or open
virtual terminals.

**Hybrid laptops** render on the GPU the compositor uses, like any
desktop app; offload to NVIDIA per app with
`__NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia` (Vulkan
apps and DXVK pick the discrete GPU themselves).

## Games

No gaming image: Steam runs from Flathub inside the box.

```bash
flatpak install --user flathub com.valvesoftware.Steam
flatpak run com.valvesoftware.Steam
```

CDI carries only the 64-bit NVIDIA libraries. Flatpak does not need
them: it installs Flathub's `GL.nvidia-<version>` and
`GL32.nvidia-<version>` extensions for the host's driver version, which
give Steam and Proton both halves. gamescope and MangoHud are Flatpak
extensions too (`com.valvesoftware.Steam.Utility.gamescope`,
`org.freedesktop.Platform.VulkanLayer.MangoHud`).

**Not included: gamemode.** Rootless, the box's hard nice limit is 0 and
only host root can raise it, so gamemode cannot renice anything, and the
CPU governor it would set is host sysfs. Its limits.d entry also makes
pam_limits fail every session of its group's members, which is why the
base makes pam_limits optional (see Security posture).

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
