#!r6rs
;;; A test program, not a suite: a writer on a Techo file in WAL, to be
;;; killed with `kill -9` while its `-wal` is large (ADR-0012, clause 11).
;;;
;;;   writer-child.sps DB REPORT-FILE
;;;
;;; Auto-checkpointing is off, so every commit stays in the `-wal`. Each
;;; transaction inserts a batch of rows. After each COMMIT the table's row
;;; count is appended to REPORT-FILE as a line, and the file is flushed and
;;; closed, so a kill loses no line it reported.
(import (rnrs)
        (chez-sqlite3)
        (techo db))

(define batch 100)

;; report! : String Integer -> Void
;; One more line at the end of PATH. `no-truncate` matters: `no-fail` alone
;; empties the file at each open, `append` or not, and a kill between that
;; open and the write then leaves no number at all (traps.md).
(define (report! path n)
  (let ((p (open-file-output-port path (file-options no-fail no-truncate append)
                                  (buffer-mode block) (native-transcoder))))
    (put-string p (number->string n))
    (newline p)
    (flush-output-port p)
    (close-port p)))

(let* ((args (cdr (command-line)))
       (path (car args))
       (report (cadr args))
       (db (open-techo-db path 'read-write)))
  (execute! db "PRAGMA wal_autocheckpoint = 0")
  (execute! db "CREATE TABLE IF NOT EXISTS writer_rows (id INTEGER PRIMARY KEY, payload TEXT NOT NULL) STRICT")
  (let loop ((count (vector-ref (query-row db "SELECT count(*) FROM writer_rows") 0)))
    (execute! db "BEGIN IMMEDIATE")
    (do ((i 0 (+ i 1))) ((= i batch))
      (execute! db "INSERT INTO writer_rows (payload) VALUES (?)"
                (make-string 200 #\x)))
    (execute! db "COMMIT")
    (report! report (+ count batch))
    (loop (+ count batch))))
