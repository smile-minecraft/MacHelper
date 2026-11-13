#!/bin/bash
# Intentionally fail closed.
#
# This check used to run the embedded CLI against a fake brew. That is no longer safe to do
# automatically: the script accepts any .app path, and a Release build compiles out the
# MACHELPER_BREW override, so the CLI would run the user's real Homebrew. sandbox-exec on this
# machine did not block a self-created canary, so it cannot be used as isolation either.
#
# Previous Debug-only results, kept in SmileWork evidence and not rerun in this version:
#   info success: ok; info failure fallback: ok.
#
# Do not add a bypass here without an independently proven way to force every brew invocation to
# a test-owned executable (or block the real one and the network).
set -euo pipefail
echo "refusing to run CLI compat: no proven isolation forces this .app to use a fake brew; a Release build ignores MACHELPER_BREW and sandbox-exec is not enforcing deny rules on this machine." >&2
exit 2
