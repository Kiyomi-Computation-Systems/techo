;; fsyncprobe.sps -- the disk's own commit latency: 5000 one-row transactions, WAL, synchronous=FULL, no FTS, no big rows.
(import (rnrs) (chez-sqlite3) (spike))
(for-each (lambda (f) (when (file-exists? f) (delete-file f))) '("build/spike/probe.db" "build/spike/probe.db-wal" "build/spike/probe.db-shm"))
(define db (open-spike-db "build/spike/probe.db" 'full 2000))
(execute! db "create table t (x integer)")
(define times
  (let loop ((i 0) (acc '()))
    (if (= i 5000) acc
        (let* ((t0 (now-ns)) (ignored (execute! db "insert into t values (?)" i)) (t1 (now-ns)))
          (loop (+ i 1) (cons (- t1 t0) acc))))))
(out-line "| operation | size | n | median ms | p99 ms | worst ms |")
(out-line (stats-line "1-row insert commit, FULL (autocheckpoint on)" "-" 5000 times))
(close-database! db)
