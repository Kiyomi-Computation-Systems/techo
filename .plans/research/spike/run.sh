#!/bin/sh
# usage: .plans/research/spike/run.sh PROGRAM.sps [ARGS...]   (from the repo root, on the host)
# Runs a spike program in the Guix container.
set -eu
cd "$(dirname "$0")/../../.."
mkdir -p build/spike
prog=$1; shift
exec scripts/guix-env sh -c '$CHEZ --libdirs "$(make -s libdirs):.plans/research/spike/lib" --program .plans/research/spike/'"$prog"' '"$*"
