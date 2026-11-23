#!/bin/sh
# scripts/ci/check-chez.sh PREFIX
#
# Fails unless PREFIX/bin/scheme is Chez Scheme 10.4.1, threaded: the build
# scripts/ci/build-chez.sh makes. It asks the installed scheme for
# (scheme-version-number) and (threaded?) and compares the answer whole.
# build-chez.sh checks what it built the same way; CI runs this again after
# restoring Chez from a cache, so a cache that serves another build is caught
# before any check runs on it.
#
# It prints one line and exits 0, or says what is wrong on stderr and exits
# 1, or 2 on a usage error. Keep `version` equal to build-chez.sh's.
set -eu

version=10.4.1

[ "$#" -eq 1 ] || { echo "usage: check-chez.sh PREFIX" >&2; exit 2; }
prefix=$1

scheme=$prefix/bin/scheme
[ -x "$scheme" ] || {
  echo "check-chez.sh: $scheme is not an executable file" >&2
  exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/check-chez.XXXXXX")
trap 'rm -rf "$work"' EXIT

probe=$work/probe.ss
cat >"$probe" <<'EOS'
(let-values (((major minor patch) (scheme-version-number)))
  (display (list major minor patch (if (threaded?) 'yes 'no))))
EOS
asked=$("$scheme" --script "$probe") || {
  echo "check-chez.sh: $scheme could not run the probe" >&2
  exit 1
}
expected="($(printf '%s' "$version" | tr . ' ') yes)"
if [ "$asked" != "$expected" ]; then
  echo "check-chez.sh: $scheme answers $asked, but (scheme-version-number) and (threaded?) should answer $expected" >&2
  exit 1
fi
echo "check-chez.sh: $scheme is Chez $version, threaded: $asked"
