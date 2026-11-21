# Sourced (not run) by the Makefile and the build scripts, from the repository root.
#
# Picks the Xcode to build with, in this order:
#   1. DEVELOPER_DIR already set in the environment
#   2. DEVELOPER_DIR from Config/Local.env (git-ignored, one machine's settings), e.g.
#        DEVELOPER_DIR=/Applications/Xcode-26.2.app/Contents/Developer
#   3. the Xcode chosen with `xcode-select` (the usual case: nothing to configure)

if [ -z "${DEVELOPER_DIR:-}" ] && [ -f Config/Local.env ]; then
    # shellcheck disable=SC1091
    . ./Config/Local.env
fi
if [ -n "${DEVELOPER_DIR:-}" ]; then
    if [ ! -d "$DEVELOPER_DIR" ]; then
        echo "DEVELOPER_DIR points to a folder that doesn't exist: $DEVELOPER_DIR" >&2
        echo "Fix it in Config/Local.env or unset it to use the Xcode chosen with xcode-select." >&2
        return 1 2>/dev/null || exit 1
    fi
    export DEVELOPER_DIR
fi
