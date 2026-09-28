#!/usr/bin/env bash
#
# Cut a release: build the arm64 macOS tarball that a Homebrew formula or a
# manual download would install, pin the checked-in Homebrew formula to the
# result, and (with --tag) create the matching git tag.
#
# Usage:
#   ./release.sh            # build dist/s1-mini-engine-vX.Y.Z-macos-arm64.tar.gz
#   ./release.sh --tag      # ... and create the annotated tag vX.Y.Z
#
# The version comes from Sources/s1-mini-engine/Version.swift — the single source
# of truth — so a release can never disagree with what `--version` prints.
#
# This script never pushes. Publishing is a separate, deliberate step; the exact
# commands are printed at the end.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

DO_TAG=false
for arg in "$@"; do
    case "$arg" in
    --tag) DO_TAG=true ;;
    -h | --help)
        sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
    *)
        echo "error: unknown option '$arg' (try --help)" >&2
        exit 2
        ;;
    esac
done

VERSION_FILE="Sources/s1-mini-engine/Version.swift"
if [ ! -f "$VERSION_FILE" ]; then
    echo "error: $VERSION_FILE not found; run this from the repository root." >&2
    exit 1
fi
VERSION="$(sed -n 's/^let versionString = "\(.*\)"$/\1/p' "$VERSION_FILE")"
if [ -z "$VERSION" ]; then
    echo "error: could not read versionString from $VERSION_FILE" >&2
    exit 1
fi
TAG="v$VERSION"

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "error: releases are arm64 macOS only (the bundled llama.xcframework is)." >&2
    exit 1
fi

# --- preflight ---------------------------------------------------------------
if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
        echo "error: tag $TAG already exists. Bump versionString in $VERSION_FILE first." >&2
        exit 1
    fi
    if [ -n "$(git status --porcelain)" ]; then
        echo "warning: working tree is not clean; the tarball will include uncommitted work." >&2
        if $DO_TAG; then
            echo "error: refusing to tag a dirty tree. Commit first, or drop --tag." >&2
            exit 1
        fi
    fi
else
    echo "note: not a git repository (no tag will be created or checked)."
    if $DO_TAG; then
        echo "error: --tag needs a git repository. Run 'git init' and commit first." >&2
        exit 1
    fi
fi

# --- build -------------------------------------------------------------------
echo "Building release binary ..."
swift build -c release
BIN=".build/release/s1-mini-engine"
if [ ! -x "$BIN" ]; then
    echo "error: $BIN was not produced." >&2
    exit 1
fi

# --- stage -------------------------------------------------------------------
# The binary links llama.framework from @loader_path, so the framework must sit
# next to it inside the tarball; a lone executable would not start.
STAGE_NAME="s1-mini-engine-$TAG"
STAGE="dist/$STAGE_NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"

cp -p "$BIN" "$STAGE/"
cp -Rp ".build/release/llama.framework" "$STAGE/"
cp -p LICENSE README.md "$STAGE/" 2>/dev/null || true
find "$STAGE" -name '.DS_Store' -delete

# Strip extended attributes from the stage. cp copies them, and two matter:
#   com.apple.quarantine   If the bundled framework is quarantined, dyld refuses to
#                          load it ("library load disallowed by system policy") and
#                          macOS raises a Gatekeeper "allow" dialog. The staged run
#                          below would then block on a human click, which looks
#                          exactly like a hang. The tarball is archived with
#                          --no-xattrs, so the artifact we ship never carries
#                          quarantine; the copy we test must not either.
#   com.apple.provenance   Stamped by macOS on every file a process creates, with a
#                          value that varies per copy, so it cannot be shipped at
#                          all. It is protected and survives this strip, which is
#                          why the tar step below still needs --no-xattrs.
xattr -cr "$STAGE" 2>/dev/null || true

# Pin every staged timestamp. tar records member mtimes, including directories and
# symlinks, so without this the tarball differs byte-for-byte on every run and the
# sha256 a Homebrew formula pins could never match a re-run of this script.
# 2026-01-01 00:00:00, chosen only because it is fixed and obviously synthetic.
find "$STAGE" -exec touch -h -t 202601010000 {} +

# Prove the staged copy is actually runnable before packaging it.
#
# Bounded on purpose. "The framework could not be loaded" surfaces as a modal dialog
# on some machines rather than as an error, so the process waits for a click and an
# unattended release run sits there indefinitely.
run_with_timeout() {
    local secs="$1"
    shift
    "$@" &
    local pid=$!
    local waited=0
    while [ "$waited" -lt "$secs" ]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid"
            return $?
        fi
        sleep 1
        waited=$((waited + 1))
    done
    kill -9 "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    return 124
}

RUN_VERSION="$(run_with_timeout 30 "$STAGE/s1-mini-engine" --version)" || {
    echo "error: the staged binary reported no version within 30s." >&2
    echo "       If macOS is showing a Gatekeeper dialog for llama.framework, allow it" >&2
    echo "       and re-run. To see the real error, run it by hand:" >&2
    echo "         \"$STAGE/s1-mini-engine\" --version" >&2
    exit 1
}
echo "Staged binary reports: $RUN_VERSION"
if [ "$RUN_VERSION" != "s1-mini-engine $VERSION" ]; then
    echo "error: staged binary reports '$RUN_VERSION' but $VERSION_FILE says $VERSION." >&2
    exit 1
fi

TARBALL="dist/$STAGE_NAME-macos-arm64.tar.gz"
rm -f "$TARBALL"
# Three details make this reproducible, and all of them matter because the
# formula pins the sha256:
#   --no-xattrs        macOS stamps files it creates with a com.apple.provenance
#                      xattr whose value changes per copy, so archiving xattrs made
#                      the bytes differ on every run even when contents did not.
#   COPYFILE_DISABLE   stops tar embedding ._* AppleDouble entries.
#   gzip -n            drops the gzip header's MTIME. With plain `tar -czf`, byte 4
#                      of the file changed every run on its own.
COPYFILE_DISABLE=1 tar --no-xattrs -cf - -C dist "$STAGE_NAME" | gzip -9n > "$TARBALL"
SHA="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"

URL="https://github.com/nub235/s1-mini-engine/releases/download/$TAG/$STAGE_NAME-macos-arm64.tar.gz"

# --- homebrew formula --------------------------------------------------------
# homebrew/s1-mini-engine.rb is the canonical copy of the formula that the
# nub235/homebrew-tap tap serves. Pinning its url and sha256 here is what keeps
# the tap from silently pointing at the previous release. Both substitutions are
# asserted afterwards, so reformatting the file fails the release loudly instead
# of quietly leaving a stale pin behind.
FORMULA="homebrew/s1-mini-engine.rb"
FORMULA_NOTE="missing, skipped"
if [ -f "$FORMULA" ]; then
    FORMULA_BEFORE="$(shasum -a 256 "$FORMULA" | awk '{print $1}')"
    # BSD sed takes no bare -i, so rewrite through a temp file. The patterns are
    # anchored to the exact lines the file is expected to contain: a url inside
    # this project's releases, and a 64-hex sha256.
    sed -e "s|^  url \"https://github.com/[^\"]*\"\$|  url \"$URL\"|" \
        -e "s|^  sha256 \"[0-9a-f]\\{64\\}\"\$|  sha256 \"$SHA\"|" \
        "$FORMULA" >"$FORMULA.tmp"
    mv "$FORMULA.tmp" "$FORMULA"
    if ! grep -qF "  url \"$URL\"" "$FORMULA" ||
        ! grep -qF "  sha256 \"$SHA\"" "$FORMULA"; then
        echo "error: could not pin $FORMULA to $TAG." >&2
        echo "       expected it to contain rewritable url/sha256 lines, but found:" >&2
        grep -n '^  \(url\|sha256\) ' "$FORMULA" >&2 || true
        exit 1
    fi
    FORMULA_NOTE="pinned to $VERSION"
    if [ "$FORMULA_BEFORE" = "$(shasum -a 256 "$FORMULA" | awk '{print $1}')" ]; then
        FORMULA_NOTE="already pinned to $VERSION"
    fi
else
    echo "warning: $FORMULA not found; skipping the Homebrew formula." >&2
fi

cat <<EOF

Built $TARBALL
  size      $(du -h "$TARBALL" | cut -f1)
  sha256    $SHA
  version   $VERSION (tag $TAG)
  formula   $FORMULA ($FORMULA_NOTE)

This sha256 belongs to THIS file. Upload it, then use this number; do not
re-run this script in between, or the upload and the formula will disagree.

Next steps (not run for you):

    git add $FORMULA
    git commit -m "Pin the Homebrew formula to $VERSION"
    git tag -a $TAG -m "s1-mini-engine $VERSION"
    git push origin main
    git push origin $TAG
    gh release create $TAG "$TARBALL" --title "$TAG" --notes "s1-mini-engine $VERSION"

The tap serves a copy of that same file:

    cp $FORMULA <tap-checkout>/Formula/s1-mini-engine.rb
    git -C <tap-checkout> commit -am "s1-mini-engine $VERSION"
    git -C <tap-checkout> push
EOF

if $DO_TAG; then
    git tag -a "$TAG" -m "s1-mini-engine $VERSION"
    echo
    echo "Created local tag $TAG (still needs 'git push origin $TAG')."
    if [ "$FORMULA_NOTE" = "pinned to $VERSION" ]; then
        echo "Note: $FORMULA is still uncommitted, so $TAG does not contain it."
        echo "      Commit the pin and re-run with --tag if you want them together;"
        echo "      the tarball is reproducible, so the sha256 will not change."
    fi
fi
