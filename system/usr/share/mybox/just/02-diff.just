# What has this box changed, relative to the image it runs?
#
# Every image-owned tree is an overlay, and the pre-init publishes each
# PRISTINE lower read-only at /run/mybox/lower/<tree> before the overlay
# hides it. That is the real lower rather than a copy of it, so the
# comparison cannot drift from what the box is actually layered on.
#
#   mybox diff          /etc, the one you almost always want
#   mybox diff usr      packages installed at runtime
#   mybox diff var      state; the bulk payloads are excluded, see below
#
# For "which files did this box touch" without reading content, the
# overlay upper answers instantly:  find /.mybox/etc/diff -type f

[group('system')]
diff tree="etc":
    #!/usr/bin/env bash
    set -uo pipefail

    lower="/run/mybox/lower/{{tree}}"
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
