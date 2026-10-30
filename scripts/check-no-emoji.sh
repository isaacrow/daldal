#!/bin/sh
# Fails the build if any emoji or pictographic symbol appears in the given source tree.
# Every icon in Daldal must be an SVG asset (see Daldal/Resources/Assets.xcassets/Icons).
set -eu

root="${1:-Daldal}"

matches=$(find "$root" -type f \( -name '*.swift' -o -name '*.xcstrings' -o -name '*.strings' -o -name '*.json' -o -name '*.plist' \) -print0 \
  | xargs -0 perl -CSD -ne '
      if (/[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{2B00}-\x{2BFF}\x{FE0F}\x{200D}\x{20E3}]/) {
        print "$ARGV:$.: emoji found (use an SVG icon instead)\n";
      }
      close ARGV if eof;
    ')

if [ -n "$matches" ]; then
  printf '%s\n' "$matches" | sed 's/^/error: /'
  exit 1
fi
