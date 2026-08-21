# Inspect and undo what this box has changed, per overlay tree.
#
# Every image-owned tree is an overlay of two directories:
#
#     lower   the image's own /<tree>, published read-only by the
#             pre-init at /run/mybox/lower/<tree> before the overlay
#             hides it — the real lower, not a copy of it
#     upper   /.mybox/<tree>/diff        what this box changed
#
# Anything nobody touched is read straight from the image, so it follows
# a rebase. The moment a file is written, overlayfs copies it up and this
# box owns it from then on — which makes the upper an exact list of local
# changes, with nothing to diff and nothing to remember after an upgrade.
#
# Trees: etc (default) var usr opt
#
#   mybox list          what this box changed, by path
#   mybox diff          the same question, with content
#   mybox reset PATH    stop overriding one path
#   mybox prune         drop overrides that no longer override anything

STATE := "/.mybox"
LOWER := "/run/mybox/lower"

# What has this box changed, compared to the image it runs?
[group('system')]
list tree="etc":
    #!/usr/bin/env bash
    set -uo pipefail
    upper="{{STATE}}/{{tree}}/diff"
    [[ -d "$upper" ]] || { echo "no upper for /{{tree}} — trees are: etc var usr opt" >&2; exit 1; }
    cd "$upper"
    # A deleted image file leaves an overlayfs whiteout: a character
    # device 0:0, not a regular file. Listing only -type f would report
    # every deletion as "unchanged", which is the one wrong answer here.
    find . -mindepth 1 -type f -printf 'changed  %P\n'
    find . -mindepth 1 -type c -printf 'deleted  %P\n'

# Show the content difference between a tree and the image's version.
[group('system')]
diff tree="etc":
    #!/usr/bin/env bash
    set -uo pipefail

    lower="{{LOWER}}/{{tree}}"
    if [[ ! -d "$lower" ]]; then
        echo "no published lower for /{{tree}} — trees are: etc var usr opt" >&2
        exit 1
    fi

    # containers/ and flatpak/ are raw binds punched through the /var
    # overlay, not overlay content: they have no counterpart in the lower
    # and would drown the report in thousands of image and app files.
    exclude=()
    if [[ "{{tree}}" == var ]]; then
        exclude=(--exclude=containers --exclude=flatpak)
    fi

    # --no-dereference: /etc/mtab and the factory tree carry symlinks that
    # point at runtime paths, and following them turns every one into a
    # "No such file or directory" line that buries the real report.
    diff -rq --no-dereference "${exclude[@]}" "$lower" "/{{tree}}"
    status=$?
    # diff exits 1 when files differ, which is the normal outcome here and
    # not an error worth failing the recipe over.
    [[ $status -le 1 ]] || exit $status

# Stop overriding a path so it follows the image again. Needs a restart.
[group('system')]
reset path:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ $EUID -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }
    p="{{path}}"; p="${p#/}"
    tree="${p%%/*}"; rel="${p#*/}"
    case "$tree" in
        etc|var|usr|opt) ;;
        *) echo "ERROR: /$tree is not an overlay tree — use etc, var, usr or opt" >&2; exit 2;;
    esac
    case "$rel" in ''|"$tree"|*..*) echo "ERROR: bad path: {{path}}" >&2; exit 2;; esac
    upper="{{STATE}}/$tree/diff"
    if [[ ! -e "$upper/$rel" ]]; then
        echo "/$tree/$rel is not overridden here — it already comes from the image."
        exit 0
    fi
    rm -rf "${upper:?}/$rel"
    echo "removed $rel from the /$tree upper. Restart the container to apply."
    # The kernel does not promise a coherent view of an overlay whose upper
    # was edited underneath it, and only the pre-init can remount the tree.
    echo "Until then /$tree/$rel may still show the old content."

# List overrides that no longer override anything, and offer to drop them.
[group('system')]
prune tree="etc" apply="":
    #!/usr/bin/env bash
    set -uo pipefail
    upper="{{STATE}}/{{tree}}/diff"
    lower="{{LOWER}}/{{tree}}"
    [[ -d "$upper" ]] || { echo "no upper for /{{tree}} — trees are: etc var usr opt" >&2; exit 1; }
    [[ -d "$lower" ]] || { echo "no published lower for /{{tree}} — cannot tell what still overrides" >&2; exit 1; }
    dead=()
    # An upper file byte-identical to the image's: overriding nothing, but
    # still pinned against every future rebase.
    while IFS= read -r rel; do
        if [[ -f "$lower/$rel" ]] && cmp -s "$upper/$rel" "$lower/$rel"; then
            dead+=("$rel"); echo "identical to image   $rel"
        fi
    done < <(cd "$upper" && find . -mindepth 1 -type f -printf '%P\n')
    # A whiteout for a file the image no longer ships: hiding nothing.
    while IFS= read -r rel; do
        if [[ ! -e "$lower/$rel" ]]; then
            dead+=("$rel"); echo "hides nothing        $rel"
        fi
    done < <(cd "$upper" && find . -mindepth 1 -type c -printf '%P\n')

    if [[ "${#dead[@]}" -eq 0 ]]; then echo "nothing to prune in /{{tree}}"; exit 0; fi
    if [[ "{{apply}}" != "apply" ]]; then
        echo
        echo "${#dead[@]} entr(ies) can be dropped. Re-run as: mybox prune {{tree}} apply"
        exit 0
    fi
    [[ $EUID -eq 0 ]] || { echo "ERROR: run as root to apply" >&2; exit 1; }
    for rel in "${dead[@]}"; do rm -rf "${upper:?}/$rel"; done
    echo "dropped ${#dead[@]} entr(ies) from /{{tree}}. Restart the container to apply."
