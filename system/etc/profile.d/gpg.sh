# shellcheck shell=sh
# gpg-agent + TTY pinentry setup. Only runs for interactive shells
# or SSH sessions with a TTY.
if [ -n "${PS1:-}" ] || [ -n "${SSH_TTY:-}" ]; then
    if tty -s 2>/dev/null; then
        # Assigned first, exported second: `export X="$(cmd)"` masks the
        # command's exit status behind export's own (SC2155).
        GPG_TTY="$(tty)"
        export GPG_TTY
        gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1 || true
    fi
fi
