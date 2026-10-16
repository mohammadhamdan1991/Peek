#!/usr/bin/env bash
# Fails when a build contains the Peek debug toolkit.
# Run on every Production archive: the last check that Peek stayed out.
# Usage: Scripts/verify_no_peek.sh <path to .ipa | .app | .xcarchive>
# No pipefail: `grep -q` exits on the first match, and the SIGPIPE it sends upstream would turn a hit into a miss.
set -eu

target="${1:?usage: verify_no_peek.sh <.ipa|.app|.xcarchive>}"
[[ -e "$target" ]] || { echo "error: $target does not exist"; exit 2; }

work=""
trap '[[ -n "$work" ]] && rm -rf "$work"' EXIT
case "$target" in
  *.ipa) work="$(mktemp -d)"; unzip -q "$target" -d "$work"; root="$work/Payload" ;;
  *) root="$target" ;;
esac

# Swift mangled names embed the module name, so this also catches stripped binaries via `strings`.
# Swift mangles module names with their length (4Peek, 8PeekCore), so this stays specific to Peek.
pattern='s4Peek|C4Peek|8PeekCore|dev\.peek\.'
found=0
scanned=0

if bundles="$(find "$root" -iname '*Peek*')" && [[ -n "$bundles" ]]; then
  echo "error: Peek bundle in build:"; echo "$bundles"; found=1
fi

while IFS= read -r -d '' binary; do
  file -b "$binary" | grep -q 'Mach-O' || continue
  scanned=$((scanned + 1))
  if nm "$binary" 2>/dev/null | grep -Eq "$pattern" \
    || strings -a "$binary" | grep -Eq "$pattern" \
    || otool -L "$binary" 2>/dev/null | grep -Eq "$pattern"; then
    echo "error: Peek found in ${binary#"$root"/}"; found=1
  fi
done < <(find "$root" -type f \( -perm -u+x -o -name '*.dylib' \) -print0) # dylibs don't always carry the exec bit

# Passing because nothing was looked at is not passing: a wrong path or an empty Payload must fail.
if [[ $scanned -eq 0 ]]; then echo "error: no Mach-O binary found under $target"; exit 2; fi
if [[ $found -eq 0 ]]; then echo "OK: no Peek in $scanned binaries of $(basename "$target")"; fi
exit $found
