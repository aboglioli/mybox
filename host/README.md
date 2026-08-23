# host/

HOST-side systemd unit — it runs on the machine, not inside the container,
and is not a quadlet drop-in.

| File | What it does |
|---|---|
| `mybox-gui.path` | hands the box to `<name>@gui.service` once the desktop session is ready |

## Two instances, one box

mybox is **one template with two mutually exclusive instances**:

| Unit | Sockets | Started by |
|---|---|---|
| `mybox@headless.service` | none | boot (`WantedBy=multi-user.target`) |
| `mybox@gui.service` | host wayland / pipewire / pulse | `mybox-gui.path` |

They are the *same box*: `%p` is `mybox` for both instances, so both use
`/srv/mybox`, both are `ContainerName=mybox`, and both read every drop-in
in `mybox@.container.d/`. Only `mybox@gui.container.d/10-gui.conf` is not
shared — that one drop-in is the entire difference. Only one may run at a
time; two systemd PID 1s over the same overlay uppers would corrupt them.

Nothing here needs a config directory of its own. The definition lives in
`/etc/containers/systemd` where quadlet already looks, and the state lives
in `/srv/<name>` where it already lived.

## The handover

```
boot            @headless up
login           .path fires  ->  @gui starts  ->  Conflicts= stops @headless
logout          /run/user/<uid> unmounts -> BindsTo= stops @gui
                -> OnSuccess= starts @headless -> .path re-arms
```

Every arrow is a systemd directive; nothing polls and nothing is scripted.

- `Conflicts=%p@headless.service` + `After=` — ordered handover, never both.
- `BindsTo=run-user-1000.mount` (in `10-gui.conf`) — ends the GUI instance
  with the session.
- `OnSuccess=%p@headless.service` — gives the box back. `OnFailure=` too,
  so a GUI instance that cannot start still leaves the box running.

### Why `BindsTo=` is written out by hand

Quadlet already emits `RequiresMountsFor=/run/user/1000/wayland-1` from the
`Volume=` lines, and that looks like it should be enough. It isn't:
systemd gives a mount it only discovered in `/proc/self/mountinfo` an
`After=` but **no** `Requires=`.

```bash
systemctl show run-user-1000.mount -p RequiredBy   # empty
systemctl show mybox@gui.service   -p Requires     # no run-user-1000.mount
```

Without the explicit `BindsTo=`, logging out leaves `@gui` running on dead
sockets and the next login inherits them, because a `.path` unit does not
re-check while the unit it triggers is still active.

## Install by hand

```bash
sudo cp host/mybox-gui.path /etc/systemd/system/
sudoedit /etc/systemd/system/mybox-gui.path
sudo systemctl enable --now mybox-gui.path
```

| Line | Adjust when |
|---|---|
| `PathExists=/run/user/1000/wayland-1` | your uid isn't 1000, or the compositor uses `wayland-0` (GNOME/KDE). Keep in sync with `container/10-gui.conf` — both its `Volume=` lines and its `BindsTo=run-user-1000.mount` |
| `Unit=mybox@gui.service` | the instance is renamed |

`just install` substitutes both from `MYBOX_WAYLAND` / `MYBOX_CONTAINER`,
and removes the whole GUI instance again when `10-gui` is dropped from the
drop-in set.

```bash
just status                              # which instance holds the box
systemctl status mybox-gui.path          # waiting == armed, running == fired
systemctl cat mybox@gui.service          # the merged result
```

## Limits

- **A compositor restart within one session is not caught.** The runtime
  dir stays mounted, so `@gui` keeps running, and a `.path` unit does not
  re-check while its unit is active. The new socket is a new inode and a
  bind pins the old one, so the GUI goes dead until `just restart` — which
  `try-restart`s whichever instance is up. Logging out and back in fixes it
  by itself; restarting niri in place does not.
- **A GUI instance that keeps failing flaps.** `OnFailure=` starts
  `@headless`, the `.path` re-arms and fires again. systemd's start limit
  ends it after a few tries and the box stays headless — check
  `systemctl status mybox-gui.path`.
- **ssh-only logins stay headless**, which is now the right answer rather
  than a failure: the box is already up.
