#!/bin/sh
# Rebuilds apps/cli/tools/archives/happier-daemon-launcher-darwin-universal.tar.gz from
# happier-daemon-launcher.c and records its checksum. Requires macOS with the Xcode command line
# tools. The binary is universal (arm64 + x86_64) so one installed copy keeps working on either
# architecture, and ad-hoc signed with a fixed identifier; release signing re-signs it with the
# payload identity and preserves that identifier.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
archives="$here/../../archives"
archive_name=happier-daemon-launcher-darwin-universal.tar.gz
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

xcrun clang -Os -Wall -Wextra -Werror \
  -arch arm64 -arch x86_64 -mmacosx-version-min=11.0 \
  -o "$work/happier-daemon-launcher" "$here/happier-daemon-launcher.c"
codesign --force --sign - --identifier dev.happier.daemon-launcher "$work/happier-daemon-launcher"
chmod 0755 "$work/happier-daemon-launcher"

COPYFILE_DISABLE=1 tar -czf "$archives/$archive_name" --uid 0 --gid 0 --uname root --gname wheel \
  -C "$work" happier-daemon-launcher

checksum=$(shasum -a 256 "$archives/$archive_name" | cut -d' ' -f1)
checksums="$archives/checksums.sha256"
grep -v "  $archive_name\$" "$checksums" > "$work/checksums" || true
printf '%s  %s\n' "$checksum" "$archive_name" >> "$work/checksums"
sort -k2 "$work/checksums" > "$checksums"
echo "$archive_name $checksum"
