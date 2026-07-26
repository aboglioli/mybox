# Load environment.d-style env files for fish shells.
#
# systemd-environment-d-generator(8) reads these directories for the
# systemd USER manager — vars end up in `systemctl --user`-spawned
# processes (niri-session, graphical sessions, etc.). They do NOT
# reach plain PAM sessions (TTY login, ssh, machinectl shell,
# lxc-console) and definitely not raw `lxc-attach` (no PAM at all).
#
# This loader gives fish-shell users the same vars in every fish
# session by parsing the standard directories ourselves. Bash users
# need /etc/profile.d/*.sh for equivalent coverage.
#
# Search order matches systemd-environment-d-generator: vendor →
# runtime → admin → user. Later loads override earlier (last wins),
# within a dir files load in lexical order.
#
# Parsing handles:
#   * blank lines and `# comment` lines
#   * `KEY=value`         (bare)
#   * `KEY="value"`       (double-quoted)
#   * `KEY='value'`       (single-quoted)
#   * `KEY=value # tail`  (NO — env.d spec doesn't support tail comments;
#                          tail content lands in the value, on purpose)
#   * leading whitespace in keys is trimmed
#
# Does NOT support `${VAR}` expansion in values — systemd's loader
# supports it, but we keep this simple. Add explicit values if needed.

for env_dir in /usr/lib/environment.d /run/environment.d /etc/environment.d ~/.config/environment.d
    test -d $env_dir; or continue
    for env_file in $env_dir/*.conf
        test -r $env_file; or continue

        while read -l line
            # Skip blank lines and full-line comments
            string match -qr '^\s*$' -- $line; and continue
            string match -qr '^\s*#' -- $line; and continue

            # Split on FIRST `=` only
            set -l key_value (string split -m 1 '=' -- $line)
            test (count $key_value) -eq 2; or continue

            set -l key (string trim -- $key_value[1])
            set -l value (string trim -- $key_value[2])

            # Strip ONE pair of surrounding quotes (double or single)
            if string match -qr '^".*"$' -- $value
                set value (string sub -s 2 -e -1 -- $value)
            else if string match -qr "^'.*'\$" -- $value
                set value (string sub -s 2 -e -1 -- $value)
            end

            # Skip empty keys (malformed input)
            test -n "$key"; or continue

            set -gx $key $value
        end <$env_file
    end
end
