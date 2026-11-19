# Homebrew on PATH for fish sessions, once mybox-homebrew.service has
# installed it. Skipped for root: brew refuses to run as root.
if test -x /home/linuxbrew/.linuxbrew/bin/brew; and test (id -u) -ne 0
    /home/linuxbrew/.linuxbrew/bin/brew shellenv fish | source
end
