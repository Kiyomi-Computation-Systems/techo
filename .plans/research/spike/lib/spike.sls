;; Throwaway spike library: schema, deterministic text, clock, statistics.
(library (spike)
  (export make-rng rng-next! rng-below! node-id node-title make-body
          now-ns ms stats-line sorted-stats create-schema! pick-word
          open-spike-db vocab-word out-line pad-hex)
  (import (rnrs) (only (chezscheme) current-time time-second time-nanosecond
                       string-set! string-copy!)
          (chez-sqlite3))

  ;; ---- PRNG: xorshift32, all fixnum -------------------------------------
  (define mask #xFFFFFFFF)
  (define (make-rng seed)
    (let ((s (let ((x (bitwise-and (+ (* seed 2654435761) 12345) mask))) (if (zero? x) 88172645 x))))
      (lambda ()
        (let* ((x s)
               (x (bitwise-and (bitwise-xor x (bitwise-arithmetic-shift-left x 13)) mask))
               (x (bitwise-xor x (bitwise-arithmetic-shift-right x 17)))
               (x (bitwise-and (bitwise-xor x (bitwise-arithmetic-shift-left x 5)) mask)))
          (set! s x) x))))
  (define (rng-next! r) (r))
  (define (rng-below! r n) (mod (+ (* (r) 4096) (bitwise-arithmetic-shift-right (r) 20)) n))

  ;; ---- ids ---------------------------------------------------------------
  ;; UUIDv7-shaped: 6 bytes of ordinal, 10 bytes pseudo-random, deterministic in i.
  (define (node-id i)
    (let ((bv (make-bytevector 16 0)) (r (make-rng (+ i 7))))
      (do ((k 0 (+ k 1))) ((= k 6))
        (bytevector-u8-set! bv k (bitwise-and (bitwise-arithmetic-shift-right i (* 8 (- 5 k))) 255)))
      (do ((k 6 (+ k 1))) ((= k 16))
        (bytevector-u8-set! bv k (bitwise-and (bitwise-arithmetic-shift-right (r) 11) 255)))
      bv))
  (define (pad-hex bv) (apply string-append (map (lambda (b) (string-append (if (< b 16) "0" "") (number->string b 16))) (bytevector->u8-list bv))))

  ;; ---- vocabulary and text -----------------------------------------------
  (define vocab-size 50000)
  (define syl (list->vector
               (let ((cs '("b" "d" "k" "l" "m" "n" "r" "s" "t")) (vs '("a" "e" "i" "o")))
                 (apply append (map (lambda (c) (map (lambda (v) (string-append c v)) vs)) cs)))))
  (define (vocab-word k)
    (let loop ((n (+ k 36)) (acc ""))
      (if (zero? n) acc
          (loop (div n 36) (string-append (vector-ref syl (mod n 36)) acc)))))
  (define words (let ((v (make-vector vocab-size)))
                  (do ((k 0 (+ k 1))) ((= k vocab-size) v) (vector-set! v k (vocab-word k)))))
  ;; Zipf(1) over 2^22 slots: rank k owns a share proportional to 1/(k+1).
  (define slot-bits 22)
  (define slots 4194304)
  (define table
    (let* ((h (let loop ((k 1) (s 0.0)) (if (> k vocab-size) s (loop (+ k 1) (+ s (/ 1.0 k))))))
           (t (make-vector slots 0)))
      (let loop ((k 0) (pos 0) (cum 0.0))
        (if (< k vocab-size)
            (let* ((cum2 (+ cum (/ (/ 1.0 (+ k 1)) h)))
                   (end (min slots (exact (round (* cum2 slots))))))
              (do ((p pos (+ p 1))) ((>= p end)) (vector-set! t p k))
              (loop (+ k 1) (max pos end) cum2))
            (do ((p pos (+ p 1))) ((>= p slots)) (vector-set! t p (- vocab-size 1)))))
      t))
  (define (pick-word r) (vector-ref table (bitwise-arithmetic-shift-right (r) (- 32 slot-bits))))

  ;; make-body : Seed -> String   about 2 KB of words
  (define (make-body seed)
    (let ((r (make-rng seed)) (buf (make-string 2200)))
      (let loop ((pos 0))
        (if (>= pos 2000)
            (substring buf 0 pos)
            (let* ((w (vector-ref words (pick-word r))) (n (string-length w)))
              (string-copy! w 0 buf pos n)
              (string-set! buf (+ pos n) #\space)
              (loop (+ pos n 1)))))))
  (define (node-title seed)
    (let ((r (make-rng (+ seed 99991))))
      (let loop ((k (+ 3 (rng-below! r 5))) (acc ""))
        (if (zero? k) acc
            (loop (- k 1) (string-append acc (if (string=? acc "") "" " ") (vector-ref words (pick-word r))))))))

  ;; ---- clock and statistics ------------------------------------------------
  (define (now-ns) (let ((t (current-time 'time-monotonic)))
                     (+ (* (time-second t) 1000000000) (time-nanosecond t))))
  (define (ms ns) (/ ns 1e6))
  ;; sorted-stats : (Listof ns) -> (values median p99 worst)  in ms
  (define (sorted-stats lst)
    (let* ((v (list->vector (list-sort < lst))) (n (vector-length v)))
      (values (ms (vector-ref v (div n 2)))
              (ms (vector-ref v (- (exact (ceiling (* 0.99 n))) 1)))
              (ms (vector-ref v (- n 1))))))
  (define (fmt x) (let* ((s (number->string (/ (round (* x 1000)) 1000.0)))) s))
  (define (stats-line label size n lst)
    (let-values (((m p w) (sorted-stats lst)))
      (string-append "| " label " | " size " | " (number->string n) " | " (fmt m) " | " (fmt p) " | " (fmt w) " |")))
  (define (out-line s) (display s) (newline) (flush-output-port (current-output-port)))

  ;; ---- schema ---------------------------------------------------------------
  (define (create-schema! db)
    (execute-script! db "
create table nodes (
  id blob not null primary key,
  owner integer not null, kind text not null,
  title text not null, body text not null, content_type text not null,
  props text not null check (json_valid(props)),
  parent blob references nodes(id),
  revision integer not null, created integer not null, updated integer not null);
create index nodes_parent on nodes(parent, id);
create table revisions (
  node_id blob not null references nodes(id), revision integer not null,
  title text not null, body text not null, props text not null, ts integer not null,
  primary key (node_id, revision));
create table changes (
  owner integer not null, seq integer not null, node_id blob not null,
  revision integer not null, op text not null, ts integer not null,
  primary key (owner, seq)) without rowid;
create virtual table nodes_fts using fts5(title, body, content='nodes', content_rowid='rowid');
create trigger nodes_ai after insert on nodes begin
  insert into nodes_fts(rowid, title, body) values (new.rowid, new.title, new.body); end;
create trigger nodes_ad after delete on nodes begin
  insert into nodes_fts(nodes_fts, rowid, title, body) values ('delete', old.rowid, old.title, old.body); end;
create trigger nodes_au after update of title, body on nodes begin
  insert into nodes_fts(nodes_fts, rowid, title, body) values ('delete', old.rowid, old.title, old.body);
  insert into nodes_fts(rowid, title, body) values (new.rowid, new.title, new.body); end;
create virtual table nodes_vocab using fts5vocab(nodes_fts, 'row');"))

  (define (open-spike-db path sync cache-kib)
    (let ((db (open-database path `((journal-mode . wal) (synchronous . ,sync)
                                   (foreign-keys . #t) (busy-timeout . 5000)))))
      (execute! db (string-append "pragma cache_size=-" (number->string cache-kib)))
      db)))
