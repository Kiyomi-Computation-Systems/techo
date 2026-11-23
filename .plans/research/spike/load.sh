#!/bin/sh
# load.sh DB COMMON-WORD RARE-WORD OUTFILE   -- runs INSIDE the container (see run.sh load).
# Starts the server, measures /health idle and under a /search loop, writes raw timings to OUTFILE.*
set -eu
db=$1; common=$2; rare=$3; out=$4
port=18080
base=http://127.0.0.1:$port
CHEZ_HTTP_PORT=$port $CHEZ --libdirs "$(make -s libdirs):.plans/research/spike/lib" --program .plans/research/spike/server.sps "$db" > "$out.server.log" 2>&1 &
srv=$!
trap 'kill $srv 2>/dev/null || true' EXIT
for i in $(seq 1 100); do curl -s -o /dev/null $base/health && break; sleep 0.3; done

# stats FILE LABEL : median/p99/worst in ms of a file of seconds, one per line
stats() { sort -g "$1" | awk -v l="$2" '{a[NR]=$1*1000} END {m=a[int((NR+1)/2)]; p=a[int(NR*0.99+0.999999)]; printf "| %s | %d | %.3f | %.3f | %.3f |\n", l, NR, m, p, a[NR]}'; }
# per-process: 500 curls, each its own process and connection
perproc() { : > "$1"; for i in $(seq 1 500); do curl -s -o /dev/null -w '%{time_total}\n' $base/health >> "$1"; done; }
# one process, one kept-alive connection, 500 requests
oneconn() { curl -s -o /dev/null -w '%{time_total}\n' "$base/health?[1-500]" > "$1"; }

# warm up
curl -s -o /dev/null "$base/health?[1-100]"; curl -s -o /dev/null "$base/search?q=$common"; curl -s -o /dev/null "$base/search?q=$rare"

echo "| /health client | requests | median ms | p99 ms | worst ms |"
echo "|---|---|---|---|---|"
perproc "$out.idle.perproc"; stats "$out.idle.perproc" "idle, curl per request"
oneconn "$out.idle.oneconn"; stats "$out.idle.oneconn" "idle, one curl, kept-alive"
for w in "$common" "$rare"; do
  curl -s -o /dev/null -w '%{time_total}\n' "$base/search?n=[1-1000000]&q=$w" > "$out.search.$w" &
  cl=$!
  sleep 2
  perproc "$out.load.$w.perproc"; stats "$out.load.$w.perproc" "under /search?q=$w, curl per request"
  oneconn "$out.load.$w.oneconn"; stats "$out.load.$w.oneconn" "under /search?q=$w, one curl, kept-alive"
  kill $cl 2>/dev/null || true; wait $cl 2>/dev/null || true
  stats "$out.search.$w" "the /search?q=$w requests themselves (as the loop client saw them)"
done
