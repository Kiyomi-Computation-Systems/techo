#!r6rs
;;; The hasher suite: (techo hasher), the one-thread worker that hashes and
;;; verifies passwords (slice 3b, L5), with fast fake procedures and no
;;; chez-sodium; and (techo serve)'s serve-loop, which opens and stops it.
;;;
;;;   - make-hasher starts nothing; opening makes the stand-in once, the hash
;;;     of 64 lowercase hex characters of 32 random bytes; opening twice is
;;;     refused; a raise at open stops the worker and goes on as itself;
;;;   - each answer of hasher-verify, hasher-doubt and hasher-hash; #f for
;;;     the stored hash verifies against the stand-in and is always
;;;     'unmatched;
;;;   - 'busy on a full queue: the one thread held at a gate, the 8 slots
;;;     filled; Q9, two jobs never overlap;
;;;   - a `failed?` raise is 'failed (for doubt and hash), any other raise
;;;     goes on as itself, a deadline too; a queued job a deadline cut never
;;;     runs;
;;;   - stop is idempotent, and a call after it raises circuit's stopped
;;;     condition;
;;;   - serve-loop's six-argument form performs the hasher's open and stop,
;;;     and its four-argument form still serves.
;;;
;;; A call waits with await-outside, so each runs as the handler of one
;;; request in a test host, and the test advances the host until the job's
;;; answer is posted. A job is held by a gate (a mutex and a condition),
;;; never by a sleep.
;;;
;;; Everything that can raise is computed under `attempt` or a guard, and a
;;; raise comes out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (only (chezscheme) make-mutex mutex-acquire mutex-release make-condition
              condition-wait condition-broadcast real-time make-time sleep)
        (techo-testing)
        (http-server testing)
        (only (circuit) make-res)
        (only (circuit http-server) circuit->handler with-deadline deadline-passed?)
        (only (circuit worker) worker-stopped?)
        (only (http-support) fresh-dir)
        (only (techo db) migrate!)
        (only (techo migrations) migrations)
        (only (techo doorway) make-doorway)
        (techo serve)
        (techo hasher))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; raised-of : (-> Any) -> (U (List 'raised Any) (List 'returned Any))
;; The object itself, so a test can ask whether it is the one raised.
(define (raised-of thunk)
  (guard (e (#t (list 'raised e)))
    (list 'returned (thunk))))

;; raised-kind : (-> Any) -> (U 'no-raise 'assertion 'other)
(define (raised-kind thunk)
  (guard (e ((assertion-violation? e) 'assertion)
            (#t 'other))
    (thunk)
    'no-raise))

(define (from-to a b) (if (> a b) '() (cons a (from-to (+ a 1) b))))

;;; The gate: a fake job counts itself in, waits while the gate is shut,
;;; does its work, and counts itself out. `most` is the most jobs ever in
;;; at once.

(define-record-type gate
  (fields mx cv (mutable entered) (mutable active) (mutable most) (mutable open?)))

(define (new-gate open?) (make-gate (make-mutex) (make-condition) 0 0 0 open?))

(define (through-gate! g thunk)
  (mutex-acquire (gate-mx g))
  (gate-entered-set! g (+ 1 (gate-entered g)))
  (gate-active-set! g (+ 1 (gate-active g)))
  (gate-most-set! g (max (gate-most g) (gate-active g)))
  (condition-broadcast (gate-cv g))
  (let loop ()
    (unless (gate-open? g) (condition-wait (gate-cv g) (gate-mx g)) (loop)))
  (mutex-release (gate-mx g))
  (dynamic-wind
    (lambda () #f)
    thunk
    (lambda ()
      (mutex-acquire (gate-mx g))
      (gate-active-set! g (- (gate-active g) 1))
      (condition-broadcast (gate-cv g))
      (mutex-release (gate-mx g)))))

;; await-entered : Gate Natural Natural -> Boolean
;; Whether N jobs have come in within MS milliseconds.
(define (await-entered g n ms)
  (let ((deadline (+ (real-time) ms)) (mx (gate-mx g)))
    (mutex-acquire mx)
    (let loop ()
      (cond ((>= (gate-entered g) n) (mutex-release mx) #t)
            ((> (real-time) deadline) (mutex-release mx) #f)
            (else (condition-wait (gate-cv g) mx (make-time 'time-duration 10000000 0))
                  (loop))))))

(define (set-gate! g open?)
  (mutex-acquire (gate-mx g))
  (gate-open?-set! g open?)
  (condition-broadcast (gate-cv g))
  (mutex-release (gate-mx g)))
(define (open-gate! g) (set-gate! g #t))
(define (shut-gate! g) (set-gate! g #f))

(define (gate-view g)
  (mutex-acquire (gate-mx g))
  (let ((v (list (gate-entered g) (gate-most g))))
    (mutex-release (gate-mx g))
    v))

;;; The fakes: a hash of "H(" password ")", a verify that compares with it
;;; (or always says SAYS, when SAYS is not 'compare), and random bytes that
;;; are 0, 8, 16, ... Every call is recorded, in order. MODE is 'ok, or
;;; (raise . Object): every later hash and verify raises that object.

(define-condition-type &fake-short &error make-fake-short fake-short?)

(define-record-type fakes
  (fields gate mx (mutable calls) (mutable mode) says))

(define (new-fakes gate says) (make-fakes gate (make-mutex) '() 'ok says))

(define (note! f call)
  (mutex-acquire (fakes-mx f))
  (fakes-calls-set! f (append (fakes-calls f) (list call)))
  (mutex-release (fakes-mx f)))

(define (calls-of f)
  (mutex-acquire (fakes-mx f))
  (let ((c (fakes-calls f)))
    (mutex-release (fakes-mx f))
    c))

(define (raise-next! f obj) (fakes-mode-set! f (cons 'raise obj)))

(define (obey-mode f)
  (let ((m (fakes-mode f)))
    (when (pair? m) (raise (cdr m)))))

(define (fake-hash f)
  (lambda (password)
    (through-gate! (fakes-gate f)
                   (lambda ()
                     (note! f (list 'hash password))
                     (obey-mode f)
                     (string-append "H(" password ")")))))

(define (fake-verify f)
  (lambda (stored password)
    (through-gate! (fakes-gate f)
                   (lambda ()
                     (note! f (list 'verify stored password))
                     (obey-mode f)
                     (if (eq? (fakes-says f) 'compare)
                         (string=? stored (string-append "H(" password ")"))
                         (fakes-says f))))))

(define (fake-random f)
  (lambda (n)
    (note! f (list 'random n))
    (u8-list->bytevector (map (lambda (i) (mod (* i 8) 256)) (from-to 0 (- n 1))))))

;; The 64 hex characters of the fake's 32 bytes: two digits each, lowercase.
(define stand-in-text
  "0008101820283038404850586068707880889098a0a8b0b8c0c8d0d8e0e8f0f8")
(define stand-in-hash (string-append "H(" stand-in-text ")"))

;; Every hasher the suite makes, and every gate, so the end can open each
;; gate and stop each hasher, whatever a test left behind.
(define made '())
(define gates '())

;; rig : [Any] -> (values Hasher Fakes)
;; A hasher over fresh fakes, their gate open, verify answering SAYS
;; ('compare by default). Shut the gate after the open, which hashes.
(define rig
  (case-lambda
    (() (rig 'compare))
    ((says)
     (let* ((g (new-gate #t))
            (f (new-fakes g says))
            (h (make-hasher (fake-hash f) (fake-verify f) fake-short? (fake-random f))))
       (set! made (cons h made))
       (set! gates (cons g gates))
       (values h f)))))

;;; The host: each call is the handler of one request. `start!` sends the
;;; request, so the handler has run up to its wait when it returns; the
;;; CELL is #f until the handler has its answer, then (returned V) or
;;; (raised E).

(define unset (lambda (name) #f))
(define pending #f)

(define (call-app req)
  (let ((p pending))
    (set! pending #f)
    (let ((answer (guard (e (#t (list 'raised e))) (list 'returned ((car p))))))
      (vector-set! (cdr p) 0 answer)
      (make-res 200 '() "ok"))))

(define (new-host) (make-test-host (circuit->handler call-app unset) unset))

;; start! : Host (-> Any) -> Cell
(define (start! host thunk)
  (let ((cell (vector #f)) (c (test-host-connect! host)))
    (set! pending (cons thunk cell))
    (test-client-send! c (string->utf8 "GET /x HTTP/1.1\r\nHost: x\r\n\r\n"))
    cell))

(define (answer-of cell) (vector-ref cell 0))

;; settle! : Host (Listof Cell) -> Void
;; Runs the host until every cell has its answer, or 5 s have passed.
(define (settle! host cells)
  (let ((deadline (+ (real-time) 5000)))
    (let loop ()
      (test-host-advance! host 0)
      (unless (or (for-all answer-of cells) (> (real-time) deadline))
        (sleep (make-time 'time-duration 1000000 0))
        (loop)))))

;; hosted : (-> Any) -> (U (List 'returned Any) (List 'raised Any) 'no-answer)
(define (hosted thunk)
  (let* ((host (new-host)) (cell (start! host thunk)))
    (settle! host (list cell))
    (or (answer-of cell) 'no-answer)))

;; value-of : (U (List 'returned Any) Any) -> Any   the value, else the whole
(define (value-of r) (if (and (pair? r) (eq? (car r) 'returned)) (cadr r) r))

;; raised-what : Outcome -> Any   what a raise was, as a test reads it
(define (raised-what r)
  (cond ((not (and (pair? r) (eq? (car r) 'raised))) (list 'no-raise r))
        ((worker-stopped? (cadr r)) 'worker-stopped)
        ((deadline-passed? (cadr r)) 'deadline-passed)
        ((fake-short? (cadr r)) 'fake-short)
        ((assertion-violation? (cadr r)) 'assertion)
        (else (list 'other (describe (cadr r))))))

(define other-raise (list 'another-raise))
(define an-assertion (condition (make-assertion-violation)
                                (make-message-condition "a fake's assertion")))

(test-begin "hasher")

;;; make-hasher and opening

(test-equal "make-hasher starts nothing: no random bytes, no hash"
  '()
  (attempt (lambda () (let-values (((h f) (rig))) (calls-of f)))))

(test-equal "make-hasher refuses an argument that is no procedure"
  '(assertion assertion assertion assertion)
  (list (raised-kind (lambda () (make-hasher 'x string-length fake-short? bytevector-length)))
        (raised-kind (lambda () (make-hasher string-length 'x fake-short? bytevector-length)))
        (raised-kind (lambda () (make-hasher string-length string-length 'x bytevector-length)))
        (raised-kind (lambda () (make-hasher string-length string-length fake-short? 'x)))))

(test-equal "hasher-stop! on a hasher never opened is fine, twice"
  'stopped
  (attempt (lambda () (let-values (((h f) (rig)))
                        (hasher-stop! h) (hasher-stop! h) 'stopped))))

(test-equal "opening asks for 32 random bytes once and hashes their 64 lowercase hex characters"
  (list (list 'random 32) (list 'hash stand-in-text))
  (attempt (lambda () (let-values (((h f) (rig)))
                        (hasher-open! h)
                        (calls-of f)))))

(test-equal "opening twice is an assertion violation, and hashes nothing more"
  (list 'assertion 2)
  (attempt (lambda () (let-values (((h f) (rig)))
                        (hasher-open! h)
                        (let ((k (raised-kind (lambda () (hasher-open! h)))))
                          (list k (length (calls-of f))))))))

;; A raise at open: the same object goes on, and the worker was stopped, so
;; a call raises circuit's stopped condition.
(define open-raise
  (attempt
   (lambda ()
     (let-values (((h f) (rig)))
       (raise-next! f other-raise)
       (let* ((r (raised-of (lambda () (hasher-open! h))))
              (after (begin (fakes-mode-set! f 'ok) (hosted (lambda () (hasher-hash h "pw"))))))
         (list (and (eq? (car r) 'raised) (eq? (cadr r) other-raise))
               (raised-what after)
               (calls-of f)
               (raised-kind (lambda () (hasher-stop! h)))))))))

(test-equal "a raise from the stand-in's hash at open goes on as itself"
  #t (and (pair? open-raise) (car open-raise)))
(test-equal "after a raise at open the worker is stopped: a call raises circuit's stopped condition"
  'worker-stopped (and (pair? open-raise) (cadr open-raise)))
(test-equal "after a raise at open no job ran: the only hash was the stand-in's"
  (list (list 'random 32) (list 'hash stand-in-text))
  (and (pair? open-raise) (caddr open-raise)))
(test-equal "after a raise at open, hasher-stop! is still fine"
  'no-raise (and (pair? open-raise) (cadddr open-raise)))

(test-equal "a `failed?` raise at open goes on too, as itself"
  'fake-short
  (attempt (lambda () (let-values (((h f) (rig)))
                        (raise-next! f (make-fake-short))
                        (raised-what (raised-of (lambda () (hasher-open! h))))))))

(test-equal "a call before open is an assertion violation"
  'assertion
  (attempt (lambda () (let-values (((h f) (rig)))
                        (raised-what (hosted (lambda () (hasher-hash h "pw"))))))))

;;; Each answer

(define answers
  (attempt
   (lambda ()
     (let-values (((h f) (rig)))
       (hasher-open! h)
       (let* ((matched (hosted (lambda () (hasher-verify h "H(right)" "right"))))
              (unmatched (hosted (lambda () (hasher-verify h "H(right)" "wrong"))))
              (unknown (hosted (lambda () (hasher-verify h #f "right"))))
              (unknown-2 (hosted (lambda () (hasher-verify h #f stand-in-text))))
              (hashed (hosted (lambda () (hasher-hash h "secret"))))
              (doubt (hosted (lambda () (hasher-doubt h))))
              (doubt-2 (hosted (lambda () (hasher-doubt h)))))
         (list matched unmatched unknown unknown-2 hashed doubt doubt-2 (calls-of f)))))))

(define (answer n) (if (and (list? answers) (> (length answers) n)) (list-ref answers n) answers))
(define (answer-calls) (answer 7))

(test-equal "hasher-verify: the right password is 'matched" '(returned matched) (answer 0))
(test-equal "hasher-verify: a wrong password is 'unmatched" '(returned unmatched) (answer 1))
(test-equal "hasher-verify: #f for the stored hash is 'unmatched" '(returned unmatched) (answer 2))
(test-equal "hasher-verify: #f is 'unmatched even for the stand-in's own text"
  '(returned unmatched) (answer 3))
(test-equal "hasher-hash: the password's hash" '(returned "H(secret)") (answer 4))
(test-equal "hasher-doubt: 'hashed when the hash returned" '(returned hashed) (answer 5))

(test-equal "verify is given the stored hash first, then the password; #f is the stand-in"
  (list (list 'verify "H(right)" "right") (list 'verify "H(right)" "wrong")
        (list 'verify stand-in-hash "right") (list 'verify stand-in-hash stand-in-text))
  (let ((cs (answer-calls)))
    (if (list? cs) (filter (lambda (c) (eq? (car c) 'verify)) cs) cs)))

(test-equal "the stand-in is made once, at open: one random draw, one hash before any job"
  (list (list 'random 32) (list 'hash stand-in-text) 1)
  (let ((cs (answer-calls)))
    (if (list? cs)
        (list (car cs) (cadr cs)
              (length (filter (lambda (c) (eq? (car c) 'random)) cs)))
        cs)))

(test-assert "the doubt hashes one fixed string twice: no password, and not the stand-in's"
  (let ((cs (answer-calls)))
    (and (list? cs)
         (let ((hashes (map cadr (filter (lambda (c) (eq? (car c) 'hash)) cs))))
           ;; the stand-in's, "secret", then the doubt's twice
           (and (= (length hashes) 4)
                (string=? (list-ref hashes 1) "secret")
                (string=? (list-ref hashes 2) (list-ref hashes 3))
                (not (member (list-ref hashes 2)
                             (list stand-in-text "secret" "right" "wrong"))))))))

(test-equal "#f is 'unmatched even when verify says yes; a stored hash is then 'matched"
  '((returned unmatched) (returned matched))
  (attempt (lambda () (let-values (((h f) (rig #t)))
                        (hasher-open! h)
                        (list (hosted (lambda () (hasher-verify h #f "any")))
                              (hosted (lambda () (hasher-verify h "H(x)" "y"))))))))

(test-equal "a verify that answers no boolean is 'unmatched"
  '(returned unmatched)
  (attempt (lambda () (let-values (((h f) (rig 'yes)))
                        (hasher-open! h)
                        (hosted (lambda () (hasher-verify h "H(x)" "x")))))))

;;; Raises

(define raises
  (attempt
   (lambda ()
     (let-values (((h f) (rig)))
       (hasher-open! h)
       (let* ((short-hash (begin (raise-next! f (make-fake-short))
                                 (hosted (lambda () (hasher-hash h "pw")))))
              (short-doubt (hosted (lambda () (hasher-doubt h))))
              (short-verify (hosted (lambda () (hasher-verify h "H(pw)" "pw"))))
              (other-hash (begin (raise-next! f other-raise)
                                 (hosted (lambda () (hasher-hash h "pw")))))
              (other-doubt (hosted (lambda () (hasher-doubt h))))
              (other-verify (hosted (lambda () (hasher-verify h "H(pw)" "pw"))))
              (assert-hash (begin (raise-next! f an-assertion)
                                  (hosted (lambda () (hasher-hash h "pw"))))))
         (list short-hash short-doubt short-verify other-hash other-doubt other-verify
               assert-hash))))))
(define (raise-case n) (if (and (list? raises) (> (length raises) n)) (list-ref raises n) raises))
(define (raised-is? r obj) (and (pair? r) (eq? (car r) 'raised) (eq? (cadr r) obj)))

(test-equal "hasher-hash: a `failed?` raise is 'failed" '(returned failed) (raise-case 0))
(test-equal "hasher-doubt: a `failed?` raise is 'failed" '(returned failed) (raise-case 1))
(test-equal "hasher-verify: a `failed?` raise is not its answer: it goes on"
  'fake-short (raised-what (raise-case 2)))
(test-equal "any other raise goes on as itself: the very object, from hash, doubt and verify"
  '(#t #t #t)
  (list (raised-is? (raise-case 3) other-raise) (raised-is? (raise-case 4) other-raise)
        (raised-is? (raise-case 5) other-raise)))
(test-equal "an assertion violation in a job goes on as itself"
  #t (raised-is? (raise-case 6) an-assertion))

;;; A full queue: one thread held, 8 waiting, and the next call is 'busy.

(define full
  (attempt
   (lambda ()
     (let-values (((h f) (rig)))
       (hasher-open! h)
       (shut-gate! (fakes-gate f))
       (let* ((host (new-host))
              (held (start! host (lambda () (hasher-hash h "held"))))
              (running? (await-entered (fakes-gate f) 2 5000))
              ;; One by one, in order: Chez's map may apply its procedure
              ;; in any order (7 8 5 6 3 4 1 2 for eight).
              (queued (let loop ((i 1) (acc '()))
                        (if (> i 8)
                            (reverse acc)
                            (let ((cell (start! host (lambda ()
                                                       (hasher-hash h (string-append
                                                                       "q" (number->string i)))))))
                              (loop (+ i 1) (cons cell acc))))))
              (busy-hash (start! host (lambda () (hasher-hash h "late"))))
              (busy-verify (start! host (lambda () (hasher-verify h "H(late)" "late"))))
              (busy-doubt (start! host (lambda () (hasher-doubt h))))
              (before (list (answer-of held) (map answer-of queued)
                            (answer-of busy-hash) (answer-of busy-verify)
                            (answer-of busy-doubt))))
         (open-gate! (fakes-gate f))
         (settle! host (cons held queued))
         (list running? before (answer-of held) (map answer-of queued) (calls-of f)))))))
(define (full-part n) (if (and (list? full) (> (length full) n)) (list-ref full n) full))

(test-equal "full: the held job is running" #t (full-part 0))
(test-equal "full: with 1 running and 8 waiting, the next hash, verify and doubt are 'busy at once"
  (list #f (map (lambda (i) #f) (from-to 1 8))
        '(returned busy) '(returned busy) '(returned busy))
  (full-part 1))
(test-equal "full: the held job and all 8 waiting answer once the thread is free"
  (list '(returned "H(held)")
        (map (lambda (i) (list 'returned (string-append "H(q" (number->string i) ")")))
             (from-to 1 8)))
  (list (full-part 2) (full-part 3)))
(test-equal "full: the refused calls ran no job, and the waiting ran in the order called"
  (append (list (list 'random 32) (list 'hash stand-in-text) (list 'hash "held"))
          (map (lambda (i) (list 'hash (string-append "q" (number->string i)))) (from-to 1 8)))
  (full-part 4))

;;; Q9: at most one hash at a time. Every job waits at the gate while it is
;;; shut; a second thread would let the second job in.

(define overlap
  (attempt
   (lambda ()
     (let-values (((h f) (rig)))
       (hasher-open! h)
       (shut-gate! (fakes-gate f))
       (let* ((host (new-host))
              (one (start! host (lambda () (hasher-hash h "one"))))
              (in-one (await-entered (fakes-gate f) 2 5000))
              (two (start! host (lambda () (hasher-verify h "H(two)" "two"))))
              (in-two (await-entered (fakes-gate f) 3 300)))
         (open-gate! (fakes-gate f))
         (settle! host (list one two))
         (list in-one in-two (answer-of one) (answer-of two) (gate-view (fakes-gate f))))))))

(test-equal "Q9: while one job runs a second does not start, and both then answer, never two at once"
  '(#t #f (returned "H(one)") (returned matched) (3 1))
  overlap)

;;; A deadline goes on as itself; the queued job it cut never runs.

(define deadline
  (attempt
   (lambda ()
     (let-values (((h f) (rig)))
       (hasher-open! h)
       (shut-gate! (fakes-gate f))
       (let* ((host (new-host))
              (held (start! host (lambda () (with-deadline 1000 (lambda () (hasher-hash h "held"))))))
              (in (await-entered (fakes-gate f) 2 5000))
              (queued (start! host (lambda () (with-deadline 1000 (lambda () (hasher-verify h "H(q)" "queued")))))))
         (test-host-advance! host 1001)
         (let ((at-deadline (list (raised-what (answer-of held)) (raised-what (answer-of queued)))))
           (open-gate! (fakes-gate f))
           (await-entered (fakes-gate f) 3 300)
           (let ((after (hosted (lambda () (hasher-hash h "after")))))
             (list in at-deadline after (calls-of f)))))))))

(test-equal "a deadline reaches the caller as itself, for the running job and the queued one"
  '(deadline-passed deadline-passed)
  (if (and (list? deadline) (= (length deadline) 4)) (cadr deadline) deadline))
(test-equal "the running job finished, the queued one never ran, and the hasher still works"
  (list '(returned "H(after)")
        (list (list 'random 32) (list 'hash stand-in-text) (list 'hash "held") (list 'hash "after")))
  (if (and (list? deadline) (= (length deadline) 4)) (cddr deadline) deadline))

;;; Stopping

(define stopped
  (attempt
   (lambda ()
     (let-values (((h f) (rig)))
       (hasher-open! h)
       (let ((before (hosted (lambda () (hasher-hash h "pw")))))
         (hasher-stop! h)
         (hasher-stop! h)
         (list before
               (raised-what (hosted (lambda () (hasher-hash h "pw"))))
               (raised-what (hosted (lambda () (hasher-verify h "H(pw)" "pw"))))
               (raised-what (hosted (lambda () (hasher-verify h #f "pw"))))
               (raised-what (hosted (lambda () (hasher-doubt h))))))))))

(test-equal "stop is idempotent, and every call after it raises circuit's stopped condition"
  '((returned "H(pw)") worker-stopped worker-stopped worker-stopped worker-stopped)
  stopped)

;;; serve-loop opens and stops the hasher

(define db-path
  (attempt (lambda ()
             (let ((p (string-append (fresh-dir "test-hasher") "/techo.db")))
               (migrate! p migrations)
               p))))

;; serve-with : (-> Any) (-> Any) (-> Any) -> (List Status Prints Log)
;; serve-loop's six-argument form on the migrated file, with a doorway of
;; one reader; each thunk is told to the log before it does its own work.
(define (serve-with run! open! stop!)
  (attempt
   (lambda ()
     (let* ((log '())
            (note (lambda (x) (set! log (append log (list x)))))
            (d (make-doorway db-path 1 migrations)))
       (let-values (((status prints)
                     (serve-loop db-path migrations d
                                 (lambda () (note 'run) (run!))
                                 (lambda () (note 'open-hasher) (open!))
                                 (lambda () (note 'stop-hasher) (stop!)))))
         (list status prints log))))))

(define o1 (list 'first))
(define (nothing) #f)
(define (raising o) (lambda () (raise o)))

(test-equal "serve-loop, six arguments: the hasher opens before the server runs and stops after"
  '(0 () (open-hasher run stop-hasher))
  (serve-with nothing nothing nothing))
(test-equal "serve-loop: a hasher that will not open: no server, no hasher stop, exit 1"
  (list 1 (list (cons 'raised o1)) '(open-hasher))
  (serve-with nothing (raising o1) nothing))
(test-equal "serve-loop: a hasher's stop that raises after a clean run exits 1"
  (list 1 (list (cons 'raised o1)) '(open-hasher run stop-hasher))
  (serve-with nothing nothing (raising o1)))
(test-equal "serve-loop: a server that raises still stops the hasher"
  (list 1 (list (cons 'raised o1)) '(open-hasher run stop-hasher))
  (serve-with (raising o1) nothing nothing))

(test-equal "serve-loop, four arguments: serves with a hasher that does nothing"
  '(0 () (run))
  (attempt
   (lambda ()
     (let* ((log '()) (d (make-doorway db-path 1 migrations)))
       (let-values (((status prints)
                     (serve-loop db-path migrations d
                                 (lambda () (set! log (append log (list 'run)))))))
         (list status prints log))))))

(test-equal "serve-loop: a refused check opens no hasher"
  '(1 #t ())
  (attempt
   (lambda ()
     (let* ((log '()) (missing (string-append db-path "-missing"))
            (d (make-doorway missing 1 migrations)))
       (let-values (((status prints)
                     (serve-loop missing migrations d nothing
                                 (lambda () (set! log (cons 'open-hasher log)))
                                 (lambda () (set! log (cons 'stop-hasher log))))))
         (list status (and (= (length prints) 1) (eq? (car (car prints)) 'line)) log))))))

(test-equal "serve-loop with a real hasher: a job runs while serving, and the stop stops it"
  '(0 () (returned "H(pw)") worker-stopped)
  (attempt
   (lambda ()
     (let-values (((h f) (rig)))
       (let* ((during #f) (d (make-doorway db-path 1 migrations)))
         (let-values (((status prints)
                       (serve-loop db-path migrations d
                                   (lambda () (set! during (hosted (lambda () (hasher-hash h "pw")))))
                                   (lambda () (hasher-open! h))
                                   (lambda () (hasher-stop! h)))))
           (list status prints during
                 (raised-what (hosted (lambda () (hasher-hash h "pw")))))))))))

(test-equal "serve-loop with a real hasher whose stand-in will not hash: the server never runs"
  (list 1 #t #f)
  (attempt
   (lambda ()
     (let-values (((h f) (rig)))
       (raise-next! f other-raise)
       (let* ((ran #f) (d (make-doorway db-path 1 migrations)))
         (let-values (((status prints)
                       (serve-loop db-path migrations d
                                   (lambda () (set! ran #t))
                                   (lambda () (hasher-open! h))
                                   (lambda () (hasher-stop! h)))))
           (list status (equal? prints (list (cons 'raised other-raise))) ran)))))))

;; Whatever a test left: every gate opened, every hasher stopped.
(for-each open-gate! gates)
(for-each (lambda (h) (guard (e (#t #f)) (hasher-stop! h))) made)

(test-end "hasher")

(exit (suite-exit-status runner))
