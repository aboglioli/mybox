# Load environment.d-style env files for fish shells.
#
# systemd-environment-d-generator only feeds the systemd USER manager —
# the vars never reach plain PAM sessions (TTY login, ssh). This loader
# parses the same directories for every fish session; bash users need
# /etc/profile.d/*.sh for equivalent coverage.
#
# Search order matches the generator (vendor → runtime → admin → user,
# last wins). Handles blank/comment lines, bare and quoted values.
# No ${VAR} expansion — kept simple on purpose.

for env_dir in /usr/lib/environment.d /run/environment.d /etc/environment.d ~/.config/environment.d
    test -d $env_dir; or continue
    for env_file in $env_dir/*.conf
        test -r $env_file; or continue

        while read -l line
            string match -qr '^\s*$' -- $line; and continue
            string match -qr '^\s*#' -- $line; and continue

            set -l key_value (string split -m 1 '=' -- $line)
            test (count $key_value) -eq 2; or continue

            set -l key (string trim -- $key_value[1])
            set -l value (string trim -- $key_value[2])

            if string match -qr '^".*"$' -- $value
                set value (string sub -s 2 -e -1 -- $value)
            else if string match -qr "^'.*'\$" -- $value
                set value (string sub -s 2 -e -1 -- $value)
            end

            test -n "$key"; or continue

            set -gx $key $value
        end <$env_file
    end
end
