# host/

HOST-side systemd unit — it runs on the machine, not inside the container,
and is not a quadlet drop-in.

| File | What it does |
|---|---|
| `mybox@gui.path` | hands the box to `<name>@gui.service` once the desktop session is ready |

## Two instances, one box

mybox is **one template with two mutually exclusive instances**:

| Unit | Sockets | Started by |
|---|---|---|
| `mybox@headless.service` | none | boot (`WantedBy=multi-user.target`) |
| `mybox@gui.service` | host wayland / pipewire / pulse | `mybox@gui.path` |

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
- `OnSuccess=%p@headless.service` — gives the box back. `OnFailure=` too.
- `ConditionPathExistsGlob=!/run/user/*/wayland-*` (in `container/10-gui-guard.conf`, installed to `<name>@headless.container.d/`) — the
  headless instance only takes the box when there is no session to take it
  for. This one is not optional; see below.

### Why the headless instance carries a condition

`OnSuccess=` fires whenever the unit enters inactive — and systemd counts
the stop half of `systemctl restart` as exactly that. So restarting the GUI
instance wakes the headless one, mid-restart, while a session is still up.

That would be harmless if the two were independent, but they share
`ContainerName`, and quadlet adds `--replace`: whichever starts second
deletes the other's container. The loser exits 137, `Restart=on-failure`
brings it back 100ms later, it replaces the winner in turn, and the pair
destroy each other until something is killed by hand. Observed directly —
restarts went from 1s to 47s and ended with the unit "active" and no
container at all.

The condition breaks it: during a restart the socket is still there, so the
headless instance is skipped and the GUI instance restarts alone. At logout
the socket is gone, so it starts for real.

It lives in `10-gui-guard.conf` rather than in the headless stub because it
belongs to the GUI feature. On a headless-only box there is no GUI instance
to hold the box, so the same condition would stop mybox starting at all on
any machine that runs a desktop session.

**Consequence worth knowing:** if the GUI instance cannot start while a
session exists, the headless one is skipped too and the box stays down
rather than silently running without your sockets. `Restart=on-failure`
and the `.path` retry; `StartLimitBurst=3` stops it thrashing.

**Never start or restart both instances at once** — `just restart` only
touches the one that currently holds the box, and that is deliberate.

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
sudo cp host/mybox@gui.path /etc/systemd/system/
sudo systemctl enable --now mybox@gui.path
```

**Nothing to edit.** The unit takes its target from its own filename — a
`.path` with no `Unit=` triggers the service of the same name, so
`mybox@gui.path` starts `mybox@gui.service`, and renaming the file to
`foo@gui.path` follows the box. The socket it watches is a glob,
`/run/user/*/wayland-*`, so no uid and no compositor-specific socket number
appear anywhere. Copy it as it is.

The one file that still names your uid is `container/10-gui.conf` — bind
sources have to be literal paths, so its `Volume=` lines and its
`BindsTo=run-user-1000.mount` need editing if your uid is not 1000, or if
your compositor uses `wayland-0` (GNOME/KDE) instead of `wayland-1`.

`just install` copies every file verbatim — it substitutes nothing, so a
`cp` by hand gives byte-identical results. The full file-by-file table for
a manual install is under **Installing by hand** in the repo README.

```bash
just status                              # which instance holds the box
systemctl status mybox@gui.path          # waiting == armed, running == fired
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
  `systemctl status mybox@gui.path`.
- **ssh-only logins stay headless**, which is now the right answer rather
  than a failure: the box is already up.
