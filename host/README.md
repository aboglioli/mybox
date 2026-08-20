# host/

HOST-side systemd units — they run on the machine, not inside the
container, and are not quadlet drop-ins.

| File | What it does |
|---|---|
| `mybox-gui.path` | starts `mybox.service` once the desktop session is ready (GUI hosts only) |

A **headless** box needs none of this: `mybox.container` ships
`WantedBy=multi-user.target` and is up before anyone logs in. A **GUI** box
can't do that — `10-gui.conf` binds sockets under `/run/user/<uid>` that
don't exist until a compositor runs, and podman fails a start on a missing
bind source. So that drop-in cancels the boot wiring and this unit
replaces it.

## Install by hand

```bash
sudo cp host/mybox-gui.path /etc/systemd/system/
sudoedit /etc/systemd/system/mybox-gui.path
sudo systemctl enable --now mybox-gui.path
```

| Line | Adjust when |
|---|---|
| `PathExists=/run/user/1000/wayland-1` | your uid isn't 1000, or the compositor uses `wayland-0` (GNOME/KDE). Keep in sync with `container/10-gui.conf` |
| `Unit=mybox.service` | the instance is renamed |

`just install` substitutes both from `MYBOX_WAYLAND` / `MYBOX_CONTAINER`.

```bash
systemctl status mybox-gui.path    # waiting == armed, active == fired
ls -l "$XDG_RUNTIME_DIR"/wayland-* # what the unit should watch
```

## Limits

- **Fires once per boot.** A `.path` re-arms only after the unit it
  triggers goes inactive, and the container stays active — so no churn on
  screen lock or logout.
- **Re-login does not re-attach the sockets.** A bind pins the inode it was
  made from; the next session creates a new socket at the same path and the
  running container keeps the dead one. Run `just restart`.
- **ssh-only logins never start it.** No compositor, no socket. That box
  wants the headless set.
