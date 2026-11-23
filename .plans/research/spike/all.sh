#!/bin/sh
# The one rerun command, from anywhere on the host:   .plans/research/spike/all.sh
# Fills small/medium/large (a few minutes; large is the slow one), benchmarks each,
# then the under-load test on medium and large. Everything lands in build/spike/.
# Set SIZES="small medium" to skip large; set SKIP_FILL=1 to reuse existing SIZE.db files.
set -eu
cd "$(dirname "$0")/../../.."
here=.plans/research/spike
mkdir -p build/spike
: "${SIZES:=small medium large}"
: "${SKIP_FILL:=0}"
$here/run.sh check.sps > build/spike/check.out 2>&1
[ "$SKIP_FILL" = 1 ] || : > build/spike/fill.out
for s in $SIZES; do
  [ "$SKIP_FILL" = 1 ] || $here/run.sh fill.sps $s >> build/spike/fill.out 2>&1
  case $s in large) iters=500 ;; *) iters=2000 ;; esac
  for cache in 2000 65536; do
    [ "$cache" = 65536 ] && [ "$s" = small ] && continue
    cp build/spike/$s.db build/spike/$s.bench.db; rm -f build/spike/$s.bench.db-wal build/spike/$s.bench.db-shm
    $here/run.sh bench.sps $s $iters $cache > build/spike/bench-$s-cache$cache.out 2>&1
  done
  case $s in small) continue ;; esac
  cp build/spike/$s.db build/spike/$s.bench.db; rm -f build/spike/$s.bench.db-wal build/spike/$s.bench.db-shm
  common=$(awk '/^# common terms/ {split($5,a,":"); print a[1]}' build/spike/bench-$s-cache2000.out)
  rare=$(awk '/^# rare terms/ {split($5,a,":"); print a[1]}' build/spike/bench-$s-cache2000.out)
  scripts/guix-env sh $here/load.sh build/spike/$s.bench.db "$common" "$rare" build/spike/load-$s > build/spike/load-$s.table 2>&1
done
echo done; cat build/spike/fill.out build/spike/bench-*.out build/spike/load-*.table
