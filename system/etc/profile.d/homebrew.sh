# shellcheck shell=sh
# Homebrew on PATH for bash/sh sessions, once mybox-homebrew.service has
# installed it. Skipped for root: brew refuses to run as root.
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ] && [ "$(id -u)" -ne 0 ]; then
    eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
