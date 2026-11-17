# container/

Quadlet drop-ins for the `mybox.container` base. Podman ≥ 5.0 merges any
`<unit>.container.d/*.conf` next to the main quadlet into the generated
`.service`, same semantics as systemd `.service.d/*.conf`.

Persistence is **not** here. `mybox.container` binds
`/srv/users/<uid>/<name>` at `/.mybox` and `/usr/libexec/mybox/preinit`
builds `/etc`, `/usr`, `/var` and `/opt` on top of it before systemd
starts, plus plain binds for `/home` and `/srv`. None of it is optional.
A throwaway instance gets its own unit name — `mybox-test.container` →
`/srv/users/<uid>/mybox-test` — and you delete that directory when done
(`podman unshare rm -rf`, since box root's files are in your subuid range).

## Drop-ins

| File | Adds |
|---|---|
| `01-boot.conf` | start with the owning user manager (`default.target`): at login, at boot with linger, and for the isolated account. Pairs with `10-gui` |
| `02-gaming.conf` | the gaming image: Steam, umu-launcher, gamescope, mangohud, 32-bit GPU stack |
| `05-user.conf` | template for pinning `MYBOX_USER`/`UID`/`GID`/`SHELL`/`AUTHORIZED_KEYS` in the repo — all commented, since per-box identity belongs in `/srv/users/<uid>/<name>/container.env` |
| `10-gui.conf` | binds `%t/mybox-gui` at `/mnt/host`, where `host/mybox-gui.service` hard links your session's wayland / pipewire / pulse sockets while a session runs — the GUI comes and goes without restarting the box. Only under the desktop account itself |
| `20-gpu.conf` | `/dev/dri`, `/dev/snd`, `/dev/input` — what the owning account may open, not keyboards |
| `30-nvidia.conf` | `AddDevice=nvidia.com/gpu=all` via CDI — device nodes and host userland, nothing installed inside |
| `40-virt.conf` | `/dev/kvm`, `/dev/vhost-net` for libvirt + QEMU inside |
| `60-shared-folder.conf` | bind `/mnt/shared` |
| `85-publish-ssh.conf` | expose the box's sshd at `<host>:2222` |

## Usage

`just install [drop-ins…]` copies the chosen set (see the repo justfile).
It substitutes nothing, so copying by hand gives exactly the same result:

```bash
mkdir -p ~/.config/containers/systemd/mybox.container.d
cp container/20-gpu.conf container/30-nvidia.conf \
   ~/.config/containers/systemd/mybox.container.d/
systemctl --user daemon-reload
systemctl --user restart mybox
```

## Verifying a drop-in applied

```bash
systemctl --user cat mybox.service   # drop-ins are merged inline
/usr/lib/systemd/user-generators/podman-user-generator --dryrun | grep Loading
```

If a drop-in didn't merge, check the path — `<name>.container.d/`, with
the `.d` on the unit name — plus the `.conf` extension and the section
headers.

## Drop-in merge semantics

systemd-standard:

- Read in lexicographic order — `10-` before `20-` before `30-`
- Most fields ADD (every `Volume=`, `AddDevice=`, `PodmanArgs=` line
  is additive)
- Singletons (`Image=`, `Network=`, `HostName=`) — LAST setter wins
- To REMOVE a base field, set it empty (`Volume=`), then re-add
