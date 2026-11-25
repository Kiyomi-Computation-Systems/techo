#!/bin/sh
# `make check-makefile`: holds the Makefile's own behaviour that no suite
# reaches, one case each:
#
#   submodules-git      make submodules runs `git submodule update --init`
#   submodules-no-git   with no git on PATH it exits non-zero, naming git
#   deps-hint           deps' missing-submodule message names `make
#                       submodules`, not a bare git command
#   submodule-head      scripts/submodule-head prints the commit a submodule's
#                       files are at, without git, and nothing when it cannot
#                       tell
#   deps-off-pin        deps refuses a submodule that is not at its pin, and
#                       names `make submodules`
#   no-gnu-only         no recipe or script uses `mv -T` or `ln -sT`, which
#                       BSD (macOS) lacks
#   rename-flag         scripts/mv-no-follow-flag names a flag this system's
#                       mv has, and with it a link to a directory is
#                       replaced, never followed into
#   clean-read-only     make clean removes a build directory that holds a
#                       read-only directory
#
# Needs the MAKE variable the Makefile passes it (the command that runs
# this make), and the CHEZ one, which it only hands on. Runs nothing in the
# real build/: clean is aimed at a scratch BUILD_DIR.
set -u

: "${MAKE:=make}" "${CHEZ:?CHEZ is not set}"

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/check-makefile.XXXXXX") || exit 2
cleanup() { chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

make_path=$(command -v "$MAKE" 2>/dev/null) || make_path=$MAKE

failures=0
fail() { echo "check-makefile: FAILED $*" >&2; failures=$((failures + 1)); }
ok() { echo "check-makefile: ok $*"; }

cd "$root" || exit 2

# submodules-git: a fake git on PATH logs its arguments.
mkdir "$tmp/fakebin"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s/git.log"\n' "$tmp" > "$tmp/fakebin/git"
chmod +x "$tmp/fakebin/git"
PATH="$tmp/fakebin:$PATH" "$make_path" --no-print-directory CHEZ="$CHEZ" submodules \
  > "$tmp/out" 2>&1 < /dev/null
rc=$?
log=$(cat "$tmp/git.log" 2>/dev/null)
if [ "$rc" -eq 0 ] && [ "$log" = "submodule update --init" ]; then
  ok "submodules-git (git ran: $log)"
else
  fail "submodules-git: exit $rc, git was run with '$log'; make said:"; sed 's/^/  /' "$tmp/out" >&2
fi

# submodules-no-git: a PATH with nothing on it.
mkdir "$tmp/empty"
PATH="$tmp/empty" "$make_path" --no-print-directory CHEZ="$CHEZ" submodules \
  > "$tmp/out" 2>&1 < /dev/null
rc=$?
if [ "$rc" -ne 0 ] && grep -q 'git not found' "$tmp/out"; then
  ok "submodules-no-git (exit $rc: $(head -n 1 "$tmp/out"))"
else
  fail "submodules-no-git: exit $rc, make said:"; sed 's/^/  /' "$tmp/out" >&2
fi

# deps-hint: aim deps at a submodule directory that is not there.
"$make_path" --no-print-directory CHEZ="$CHEZ" CIRCUIT_DIR="$tmp/no-such-dir" deps \
  > "$tmp/out" 2>&1 < /dev/null
rc=$?
if [ "$rc" -ne 0 ] && grep -q "deps: .*Run 'make submodules' on the host" "$tmp/out" \
   && ! grep -q 'git submodule update' "$tmp/out"; then
  ok "deps-hint"
else
  fail "deps-hint: exit $rc, make said:"; sed 's/^/  /' "$tmp/out" >&2
fi

# submodule-head: a made-up submodule, each way its HEAD can be written.
sh_ok=1
a=1111111111111111111111111111111111111111
b=2222222222222222222222222222222222222222
c=3333333333333333333333333333333333333333
mkdir -p "$tmp/sm/outer/.git/modules/one/refs/heads" "$tmp/sm/outer/one" \
         "$tmp/sm/plain/.git" "$tmp/sm/none" "$tmp/sm/odd/.git"
echo "gitdir: ../.git/modules/one" > "$tmp/sm/outer/one/.git"
echo "$a" > "$tmp/sm/outer/.git/modules/one/HEAD"
[ "$(sh scripts/submodule-head "$tmp/sm/outer/one" 2>&1)" = "$a" ] || sh_ok=0
echo "ref: refs/heads/main" > "$tmp/sm/outer/.git/modules/one/HEAD"
echo "$b" > "$tmp/sm/outer/.git/modules/one/refs/heads/main"
[ "$(sh scripts/submodule-head "$tmp/sm/outer/one" 2>&1)" = "$b" ] || sh_ok=0
rm "$tmp/sm/outer/.git/modules/one/refs/heads/main"
printf '# pack-refs with: peeled fully-peeled sorted\n%s refs/heads/other\n%s refs/heads/main\n' \
  "$a" "$c" > "$tmp/sm/outer/.git/modules/one/packed-refs"
[ "$(sh scripts/submodule-head "$tmp/sm/outer/one" 2>&1)" = "$c" ] || sh_ok=0
echo "$b" > "$tmp/sm/plain/.git/HEAD"
[ "$(sh scripts/submodule-head "$tmp/sm/plain" 2>&1)" = "$b" ] || sh_ok=0
echo "not a commit" > "$tmp/sm/odd/.git/HEAD"
[ -z "$(sh scripts/submodule-head "$tmp/sm/odd" 2>&1)" ] || sh_ok=0
[ -z "$(sh scripts/submodule-head "$tmp/sm/none" 2>&1)" ] || sh_ok=0
[ -z "$(sh scripts/submodule-head "$tmp/sm/no-such-dir" 2>&1)" ] || sh_ok=0
if [ "$sh_ok" -eq 1 ]; then
  ok "submodule-head"
else
  fail "submodule-head: a made-up submodule's commit was not read as written"
fi

# deps-off-pin: the real circuit checkout, held against a pin it is not at.
wrong=0000000000000000000000000000000000000000
"$make_path" --no-print-directory CHEZ="$CHEZ" SUBMODULE_PINS="circuit:$wrong" deps \
  > "$tmp/out" 2>&1 < /dev/null
rc=$?
if [ "$rc" -ne 0 ] && grep -q "deps: vendor/circuit is at .*not its pin 0000000.*Run 'make submodules' on the host" "$tmp/out"; then
  ok "deps-off-pin"
else
  fail "deps-off-pin: exit $rc, make said:"; sed 's/^/  /' "$tmp/out" >&2
fi

# no-gnu-only: the flags, not the comments that name them.
if grep -nE '(^|[^#]*[[:space:]])(mv -T|ln -sT)([[:space:]]|$)' Makefile scripts/* 2>/dev/null \
   | grep -vE ':[0-9]+:[[:space:]]*#' > "$tmp/gnu"; [ -s "$tmp/gnu" ]; then
  fail "no-gnu-only: GNU-only mv -T or ln -sT in:"; sed 's/^/  /' "$tmp/gnu" >&2
else
  ok "no-gnu-only"
fi

# rename-flag
if [ ! -f scripts/mv-no-follow-flag ]; then
  fail "rename-flag: scripts/mv-no-follow-flag does not exist"
else
  flag=$(sh scripts/mv-no-follow-flag)
  rf=$tmp/rf; mkdir -p "$rf/real"
  : > "$rf/new"
  ln -sn real "$rf/link"
  if [ -n "$flag" ] && mv "$flag" "$rf/new" "$rf/link" \
     && [ -f "$rf/link" ] && [ ! -L "$rf/link" ] && [ -z "$(ls "$rf/real")" ]; then
    ok "rename-flag (mv $flag replaced the link, did not follow it)"
  else
    fail "rename-flag: flag '$flag' did not replace a link to a directory"
  fi
fi

# clean-read-only: a read-only directory, with a file in it, in a scratch
# build directory.
b=$tmp/build
mkdir -p "$b/ro/inner"
: > "$b/ro/inner/file"
chmod a-w "$b/ro/inner" "$b/ro"
# Before it runs, a dry run must show that make clean is aimed at $b: a
# clean that ignored BUILD_DIR would remove the real build/.
if ! "$make_path" -n --no-print-directory CHEZ="$CHEZ" BUILD_DIR="$b" clean 2>&1 | grep -qF -- "$b"; then
  fail "clean-read-only: make clean does not act on BUILD_DIR, so it was not run"
else
"$make_path" --no-print-directory CHEZ="$CHEZ" BUILD_DIR="$b" clean > "$tmp/out" 2>&1 < /dev/null
rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$b" ]; then
  ok "clean-read-only"
else
  fail "clean-read-only: exit $rc, $b $( [ -e "$b" ] && echo 'is still there' || echo gone ); make said:"
  sed 's/^/  /' "$tmp/out" >&2
fi
fi

if [ "$failures" -ne 0 ]; then
  echo "check-makefile: $failures case(s) failed" >&2
  exit 1
fi
echo "check-makefile: every case held"
