# mybox

Daily-driver system container: an Arch Linux image with systemd as
PID 1, running as a **podman quadlet** on top of an immutable host OS
(sibling projects [myos](https://github.com/aboglioli/myos) /
[myosi](https://github.com/aboglioli/myosi), or any Linux host with
podman ≥ 5). `mybox.container` plus `container/*.conf` drop-ins are
copied under `/etc/containers/systemd`, with systemd owning the
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
├── host/                        # HOST-side systemd units (start trigger; see host/README.md)
└── system/                      # image config tree (Containerfile COPY)
    ├── etc/                     # → /etc (snapshotted to /usr/share/factory/etc)
    └── usr/                     # → /usr (immutable at runtime)
        ├── lib/systemd/         # units, presets, target drop-ins
        ├── libexec/mybox/       # preinit (root assembly), user-setup, …
        ├── local/bin/mybox      # in-container CLI dispatcher
        └── share/mybox/
            ├── just/            # in-container recipes (install-nvidia, …)
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
| `/srv/<name>` | `/.mybox` | the one state bind — holds every overlay upper. Never itself overlaid |
| `/srv/<name>/etc/diff` | `/etc` | overlay upper; **lower is the image's `/etc`** |
| `/srv/<name>/usr/diff` | `/usr` | overlay upper; lower is the image's `/usr` — pacman installs, NVIDIA userland |
| `/srv/<name>/var` | `/var` | **plain bind** — no image layer worth keeping |
| `/srv/<name>/opt` | `/opt` | **plain bind** — the image ships nothing here |
| `/srv/<name>/var/lib/containers` | `/var/lib/containers` | ordinary subdirectory of the `/var` bind |
| `/srv/<name>/var/lib/flatpak` | `/var/lib/flatpak` | ordinary subdirectory, same |
| `/srv/<name>/home` | `/home` | raw bind — user data, no image content to layer |
| `/srv/<name>/srv` | `/srv` | raw bind, empty by contract — nested-quadlet service data |
| `/srv/<name>/container.env` | env for PID 1 | optional `MYBOX_*` runtime config |

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

**Bulk payloads are raw binds, not overlay content.** Nested podman
storage and flatpak apps are gigabytes, are not image-derived, and must
not vanish on a factory reset of `/var` — so the pre-init binds them
back over the overlay. podman cannot do it for us: anything it mounts
under `/var` is shadowed the moment `/var` is overlaid.

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
`rm -rf /srv/<name>/etc/diff` while stopped resets configuration and
leaves `/home`, the flatpak apps and the container images alone. Only
`/etc` and `/usr` have a `diff` to reset; `/var` and `/opt` are plain
binds, so there you delete the path itself. For a
single path use `mybox reset <path>` instead, and `mybox prune` to drop
overrides that have stopped overriding anything after a rebase.

**The pre-init fails the container rather than boot a degraded box.** A
missing state bind, a tree that cannot be overlaid, or a bulk payload that
cannot be bound are all fatal: each would leave a box that looks fine and
silently loses every write to that tree at the next restart. The unit
fails with the reason on the console and in `journalctl -u <name>`.
Publishing the read-only lowers is the one exception — it only powers
`mybox diff`, so it warns and carries on.

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
just start          # systemctl start mybox@headless (or @gui)
just status
just login          # full PAM session as the runtime user
```

Quadlets cannot be `systemctl enable`d — the generator wires boot from
the unit's `[Install]` section. What that means here depends on whether
the box has a GUI; see **Start model** below.

| Recipe | What it does |
|---|---|
| `just build` | local build tagged over the published reference, into the rootful store |
| `just install [drop-ins…]` | **copy** quadlet + `.network` + chosen drop-ins, wire the start trigger, `daemon-reload`. Declarative: removes previously-installed drop-ins not in the set |
| `just start` / `stop` | start/stop the unit — stop removes the container; `/srv/<name>` survives |
| `just sync` | re-copy the installed unit files from this repo — the "apply my edits" verb, since install copies rather than symlinks. Changes nothing about *which* drop-ins are selected |
| `just restart` | `sync`, then recreate against the current image + drop-ins |
| `just status` / `logs` | unit + container state + LAN IP / follow journal |
| `just enter [user]` | fast shell (`podman exec`, no PAM session) |
| `just login [user]` | full PAM/logind session (`login -f`) |

Justfile knobs (env vars): `MYBOX_IMAGE`, `MYBOX_CONTAINER`,
`MYBOX_USERNAME`, `MYBOX_DROPINS`. Everything else —
network, GUI, GPU, devices, capabilities, runtime user — is a drop-in
in `container/` (see `container/README.md`). Persistence is not: it is
part of `mybox.container` and always on.

## Start model

**Unit files are COPIES, never symlinks.** The quadlet generator runs at
the very start of the boot transaction — before `local-fs.target`, before
any `.mount` unit — so a symlink from `/etc/containers/systemd` into a tree
under `/home` is unreadable exactly when it matters. The generator then
emits **nothing**, and `systemctl status mybox@headless.service` says
`Unit … could not be found` — no unit at all, rather than a failed
one. The familiar workaround (`daemon-reload` after login, then start by
hand, every boot) is the symptom.

On an encrypted home this is unfixable by any unlock method: homed has no
TPM2 support (`homectl` has no `--tpm2-device`),
`systemd-homed-activate.service` has no `ExecStart`, and linger governs
*user*-scope quadlets while this is a rootful *system* quadlet. Copying is
the fix. `just sync` pushes later repo edits to `/etc`, and `just restart`
runs it first.

**One template, two mutually exclusive instances:**

| Unit | Sockets | Started by |
|---|---|---|
| `<name>@headless.service` | none | boot (`WantedBy=multi-user.target`) |
| `<name>@gui.service` | host wayland / pipewire / pulse | `host/mybox@gui.path`, when a wayland socket appears |

They are the same box. `%p` is `<name>` for both instances, so both use
`/srv/<name>`, both are `ContainerName=<name>`, and both read every
drop-in in `<name>@.container.d/` — which is where `mybox.container`
itself installs, as `00-base.conf`. A quadlet drop-in directory is the
only thing two instances of a template both read, so that is where the
shared definition has to live; the two `.container` files are stubs
carrying just the wiring that differs. Only one may run at a time — two
systemd PID 1s over the same overlay uppers would corrupt them.

`10-gui.conf` is the single unshared drop-in. Its bind sources are session
sockets that don't exist until a compositor runs, and podman hard-fails a
missing bind source (`statfs …: no such file or directory`), so it goes
into `<name>@gui.container.d/` and never boot-starts.

The handover is all systemd directives — nothing polls, nothing is
scripted:

```
boot     @headless up
login    .path fires -> @gui starts -> Conflicts= stops @headless
logout   /run/user/<uid> unmounts -> BindsTo= stops @gui
         -> OnSuccess= starts @headless -> .path re-arms
```

One catch worth knowing: quadlet's own `RequiresMountsFor=` does *not*
give you that logout edge — systemd grants a mount discovered only in
`/proc/self/mountinfo` an `After=` but no `Requires=`, so `10-gui.conf`
writes `BindsTo=run-user-1000.mount` out by hand. Without it, re-login
inherits dead sockets.

Restarting the compositor *within* one session is the one case this does
not catch (the runtime dir stays mounted, and a `.path` unit does not
re-check while its unit is active): run `just restart`. Drop `10-gui` and
`just install` removes the GUI instance entirely; an ssh-only login then
needs nothing, because the box is already up. See `host/README.md`.

Check what the generator will really do:

```bash
sudo /usr/lib/systemd/system-generators/podman-system-generator /tmp/g /tmp/g /tmp/g
find /tmp/g     # multi-user.target.wants/mybox@headless.service == boot start
```

## Runtime user + SSH keys

The image bakes NO user. `mybox-user-setup.service` creates one at boot
from env — with no env at all you still get a default user
(`user` / 1000 / 1000 / fish), which is what makes replicating the host
account a one-liner (`MYBOX_UID` = your host uid):

```
MYBOX_USER / MYBOX_UID / MYBOX_GID / MYBOX_SHELL
MYBOX_AUTHORIZED_KEYS      comma-separated ssh keys
```

Set them in `/srv/<name>/container.env`, which the quadlet loads and
creates empty on first start — per instance, no wiring (see
`container.env.example`). A `*.container.d` drop-in's `Environment=`
overrides it, which is why the shipped `05-user.conf` keeps its lines
commented. `MYBOX_AUTHORIZED_KEYS` is
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

Two shapes, and they answer different questions:

| File | What the container is | Reaching it |
|---|---|---|
| `mybox-nat.network` (default) | a private address behind the host's NAT | host talks to it directly; the LAN only through `PublishPort=` |
| `mybox-lan.network` | **its own host on your LAN**, own MAC and DHCP lease | any machine on the LAN, directly — except the host itself |

**NAT** assumes nothing about your network, so it works on wifi, on a
roaming laptop, in CI. Inbound needs published ports; `85-publish-ssh.conf`
is in the default drop-in set and maps the container's sshd to
`<host>:2222`. Copy that file's shape for anything else you serve.

**LAN** is macvlan: the router sees a separate machine and hands it its
own address, so nothing needs publishing — the VM-like model. It needs a
**wired** NIC not enslaved to a bridge, `netavark-dhcp-proxy.socket`
enabled on the host, and `parent=` set to your LAN NIC
(`ip -o route get 1.1.1.1 | awk '{print $5}'`). Its one hard limit is a
kernel rule, not a mybox choice: **the host and the container cannot talk
to each other** over macvlan. Everything else on the LAN can. Drop
`85-publish-ssh.conf` when using it.

Switch by editing the `Network=` line in `mybox.container` and re-running
`just install` (the recipe reads the netfile out of that line), then
`just restart`. Pin the address across recreations with
`80-static-ip.conf` (static IPAM) or `81-static-mac.conf` (stable DHCP
lease).

Neither file pins a subnet. podman allocates a free range per host,
which is what keeps them reusable: a hardcoded range fails outright on a
host where something else already holds it (`subnet … is already used on
the host or by another config`) and the container never starts. The
allocation is stable anyway — the network object outlives container
recreations. Pin `Subnet=`/`Gateway=` only when something outside podman
needs the range up front, and accept that the file stops being
host-agnostic.

**Editing a `.network` file is not enough on its own.** Quadlet creates
the podman network object only when it is missing and never reconciles an
existing one against the file, so an edit — or a switch that reuses the
name — silently keeps the old object, and the container lands on a subnet
the file no longer mentions. `just net-reset` deletes it so the next start
rebuilds it from the file.

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
| `NET_ADMIN`/`NET_RAW` | in base | nested ROOTFUL podman (`sudo podman run` inside) needs them: netavark builds a bridge, veth and nftables rules in the container's own netns and fails with `Netlink error: Operation not permitted` otherwise. Namespaced by `userns=auto`, so they reach the container's netns and nothing of the host's — **except** under `Network=host`, where the netns is the host's and you should drop them |
| `/dev/fuse` + `/dev/net/tun` | kept | tun: pasta (nested rootless podman networking). fuse: flatpak document portal + fuse-overlayfs fallback. Devices only, no capabilities |
| `label=disable` | the one open item | `container_t` breaks boot on an Enforcing host; no dedicated policy module yet |

Fine for a daily-driver box running your own workloads. Run untrusted
code only nested behind mybox's own rootless podman (a second userns).
Do not expose the container's sshd to the public internet.

**Store note:** rootful and rootless podman keep SEPARATE image
stores. The system quadlet reads the rootful store — `just build` uses
`sudo podman build`; a rootless build is invisible to the unit.

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
personally changed is pinned, and `find /srv/<name>/etc/diff -type f`
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
| `install-nvidia` | installs userland matching the host driver via the official `.run` (raw-device path; the CDI drop-in doesn't need it). Re-run after host driver upgrades |
| `list [tree]` | what this box changed, by path — `changed` from the upper's files, `deleted` from its whiteouts |
| `diff [tree]` | the same question with content, compared against the overlay's real lower |
| `reset <path>` | stop overriding one path so it follows the image again (restart to apply). `/etc` and `/usr` only |
| `prune [tree] [apply]` | find overrides that no longer override anything — upper files identical to the image, whiteouts hiding files it no longer ships |

Overlay trees are `etc` (default) and `usr`.

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
