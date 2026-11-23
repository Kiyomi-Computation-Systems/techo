;; bench.sps SIZE ITERS CACHE-KIB  -- measures on build/spike/SIZE.bench.db (a copy of SIZE.db).
(import (rnrs) (only (chezscheme) file-length open-file-input-port) (chez-sqlite3) (spike))
(define args (cdr (command-line)))
(define size (car args))
(define iters (string->number (cadr args)))
(define cache-kib (string->number (caddr args)))
(define writes-only (and (> (length args) 3) (string=? (cadddr args) "writes-only")))
(define path (string-append "build/spike/" size ".bench.db"))
(define db (open-spike-db path 'full cache-kib))
(define (num x) (number->string x))
(define (pragma name) (vector-ref (query-row db (string-append "pragma " name)) 0))
(define n (vector-ref (query-row db "select count(*) from nodes") 0))
(define nproj (div n 200))
(define rng (make-rng 424242))
(define (rnd k) (rng-below! rng k))

(out-line (string-append "# size=" size " nodes=" (num n) " iters=" (num iters) " sqlite=" (sqlite-version)))
(out-line (string-append "# pragmas: journal_mode=" (pragma "journal_mode") " synchronous=" (num (pragma "synchronous"))
  " (2=FULL,1=NORMAL) cache_size=" (num (pragma "cache_size")) " (negative=KiB) busy_timeout=" (num (pragma "busy_timeout"))
  " page_size=" (num (pragma "page_size")) " foreign_keys=" (num (pragma "foreign_keys"))
  " wal_autocheckpoint=" (num (pragma "wal_autocheckpoint"))))
(out-line "| operation | size | n | median ms | p99 ms | worst ms |")
(out-line "|---|---|---|---|---|---|")

;; run : Natural (Natural -> X) (Natural X -> Void) -> (Listof ns)   (prep is untimed)
(define (run count prep op)
  (do ((i 0 (+ i 1))) ((= i (min 100 count)))   ; warm up, discarded
    (op (- i) (prep (- i))))
  (let loop ((i 0) (acc '()))
    (if (= i count) acc
        (let* ((x (prep i)) (t0 (now-ns)) (ignored (op i x)) (t1 (now-ns)))
          (loop (+ i 1) (cons (- t1 t0) acc))))))
(define (report label count times) (out-line (stats-line label size count times)))
(define (no-prep i) #f)

;; read
(when (not writes-only) (let ((sql "select id, owner, kind, title, body, content_type, props, parent, revision, created, updated from nodes where id=?"))
  (report "read" iters (run iters (lambda (i) (node-id (rnd n))) (lambda (i id) (query-row db sql id))))))
;; list
(when (not writes-only) (let ((sql "select id, title, kind, revision from nodes where parent=? order by id limit 100"))
  (report "list (100 children)" iters
          (run iters (lambda (i) (node-id (rnd nproj)))
               (lambda (i p) (let ((r (query db sql p))) (if (and (>= i 0) (< (length r) 100)) (error 'list "short page" (length r)))))))))
;; search terms, from fts5vocab
(define (terms sql . args) (map (lambda (r) (cons (vector-ref r 0) (vector-ref r 1))) (apply query db sql args)))
(define common (terms "select term, doc from nodes_vocab order by doc desc limit 5"))
(define mid (terms "select term, doc from nodes_vocab where doc >= ? order by doc limit 10" (max 2 (div n 50))))
(define rare (let ((r (terms "select term, doc from nodes_vocab where doc >= 5 order by doc limit 20")))
               (if (null? r) (terms "select term, doc from nodes_vocab where doc >= 1 order by doc limit 20") r)))
(define (show-terms l lst) (out-line (string-append "# " l " terms (term:docs): "
  (apply string-append (map (lambda (p) (string-append (car p) ":" (num (cdr p)) " ")) lst)))))
(when (not writes-only) (show-terms "common" common) (show-terms "mid" mid) (show-terms "rare" rare))
(define ranked "select n.id, n.title from nodes_fts f join nodes n on n.rowid = f.rowid where nodes_fts match ? order by rank limit 50")
(define unranked "select n.id, n.title from nodes_fts f join nodes n on n.rowid = f.rowid where nodes_fts match ? limit 50")
(define (search label sql lst count)
  (let ((v (list->vector lst)))
    (report label count (run count (lambda (i) (car (vector-ref v (mod (abs i) (vector-length v)))))
                             (lambda (i w) (let ((r (query db sql w))) (if (and (>= i 0) (null? r)) (error 'search "no hits" w))))))))
(when (not writes-only) (search "search common (ranked)" ranked common (if (string=? size "large") (min iters 300) iters))
(search "search common (unranked)" unranked common iters)
(search "search mid (ranked)" ranked mid iters)
(search "search rare (ranked)" ranked rare iters))
;; feed
(when (not writes-only) (let ((total (vector-ref (query-row db "select max(seq) from changes where owner=1") 0))
      (sql "select seq, node_id, revision, op, ts from changes where owner = 1 and seq > ? order by seq limit 500"))
  (report "feed (500 changes)" iters
          (run iters (lambda (i) (rnd (- total 600)))
               (lambda (i c) (let ((r (query db sql c))) (if (and (>= i 0) (< (length r) 500)) (error 'feed "short" (length r)))))))))

;; write: one transaction, as Techo's write would be
(define write-counter 0)
(define (write! id title body)
  (with-transaction db
    (lambda ()
      (let ((row (query-row db "update nodes set title=?, body=?, revision=revision+1, updated=? where id=? returning revision, props"
                            title body (+ 1800000000000 write-counter) id)))
        (execute! db "insert into revisions values (?,?,?,?,?,?)" id (vector-ref row 0) title body (vector-ref row 1) 1800000000000)
        (let ((seq (+ 1 (vector-ref (query-row db "select coalesce(max(seq),0) from changes where owner=1") 0))))
          (execute! db "insert into changes values (1,?,?,?,?,?)" seq id (vector-ref row 0) "update" 1800000000000))))))
(define (write-prep i)
  (set! write-counter (+ write-counter 1))
  (let ((seed (+ 100000000 (* write-counter 31))))
    (vector (node-id (rnd n)) (node-title seed) (make-body seed))))
(define (write-op i x) (write! (vector-ref x 0) (vector-ref x 1) (vector-ref x 2)))
(define (set-sync! s) (execute! db (string-append "pragma synchronous=" s)))
(for-each
 (lambda (mode)
   (set-sync! mode)
   (report (string-append "write (synchronous=" mode ")") iters (run iters write-prep write-op)))
 '("FULL" "NORMAL"))

;; checkpoint: build ~1000 frames of WAL (SQLite's default auto-checkpoint size) with
;; auto-checkpoint off, then time one PASSIVE checkpoint. Untimed TRUNCATE resets the file.
(define (wal-size) (let* ((p (open-file-input-port (string-append path "-wal"))) (l (file-length p))) (close-port p) l))
(define ckpt-count (if (string=? size "large") 60 100))
(define frames '())
(execute! db "pragma wal_autocheckpoint=0")
(for-each
 (lambda (mode)
   (set-sync! mode)
   (query db "pragma wal_checkpoint(TRUNCATE)")
   (let ((times
          (let loop ((k 0) (acc '()))
            (if (= k (+ ckpt-count 3)) (list-tail (reverse acc) 3) ; first 3 are warm-up
                (begin
                  (let fill () (when (< (wal-size) (* 1000 4120)) (write-op 0 (write-prep 0)) (fill)))
                  (let* ((t0 (now-ns)) (r (query-row db "pragma wal_checkpoint(PASSIVE)")) (t1 (now-ns)))
                    (set! frames (cons (vector-ref r 1) frames))
                    (query db "pragma wal_checkpoint(TRUNCATE)")
                    (loop (+ k 1) (cons (- t1 t0) acc))))))))
     (report (string-append "checkpoint (PASSIVE, ~1000 frames, synchronous=" mode ")") ckpt-count times)))
 '("FULL" "NORMAL"))
(let ((l (list-sort < frames)))
  (out-line (string-append "# checkpointed frames per checkpoint: min=" (num (car l)) " median=" (num (list-ref l (div (length l) 2))) " max=" (num (car (reverse l))))))
(close-database! db)
