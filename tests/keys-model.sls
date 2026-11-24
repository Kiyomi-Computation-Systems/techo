#!r6rs
;;; (keys-model): the model-based test of D5's key lifecycle, ADR-0007's
;;; third layer, for tests/test-keys-model.sps. Test-only: it lives in
;;; tests/, which make test puts on Chez's library path.
;;;
;;; The model (pure)
;;; ----------------
;;; A world is two accounts, a and b (fixed), and for each key ever made
;;; its id, account, label ("a1"), name, created, current secret, how many
;;; secrets it had before, its state (active or revoked), its revoked time
;;; and its last_used; and the dead secrets: each regenerated key's old
;;; ones, kept so a sequence can go on presenting them.
;;;
;;; `expect` answers a request from D5's step alone, in the handlers' two
;;; steps: first the asking secret's `check`, whose state is none for a
;;; secret no key now has (a check belongs to a secret, not a key); then,
;;; if admitted, the target's event, the target's state as the ASKING
;;; ACCOUNT sees it (none for another account's key or an unknown id), and
;;; regenerate is regenerate-self when the target is the asking key. The
;;; command names the status (command-answers) and the next world. A write
;;; that is admitted sets the asking key's last_used when it is due (D6);
;;; a refusal rolls that back with the rest.
;;;
;;; `invariant-breaks` holds P2 and P3, and D5's "a key regenerates only
;;; itself", against the answer whatever the step says: they catch a table
;;; changed under both the handlers and the oracle.
;;;
;;; The run (the shell)
;;; -------------------
;;; `run-sequence` resets one migrated file, generates a seeded sequence
;;; (xorshift32: no chez-sodium randomness in the choice), and sends each
;;; request as raw HTTP through make-app inside wrap-server, in a test
;;; host. Keys are made by the test itself, through the store, as the
;;; model's own `none x create`. After every request it compares the
;;; status, the code of a refusal and the body of a 200 with the oracle's;
;;; checks the invariants; and reads every row of api_keys and accounts
;;; and compares them with the world. The first request with a difference
;;; ends the sequence, with a report that can be replayed from its seed.
(library (keys-model)
  (export make-event model-start
          expect expectation-status expectation-code expectation-rows expectation-world
          expectation-fresh expectation-problem
          world-with-new-secret world-key-view command-answers invariant-breaks
          run-sequence verdict-seed verdict-requests verdict-rows verdict-aims
          verdict-cant-happen verdict-report)
  (import (rnrs)
          (only (chezscheme) format)
          (only (chez-sqlite3) sql-null?)
          (only (chez-sodium) blake2b)
          (only (unique-id) bytevector->uuid uuid->string string->uuid uuid->bytevector)
          (techo-testing)
          (http-support)
          (only (techo keys) key-cant-happen key-secret key-secret?)
          (only (techo store) insert-account! insert-key!)
          (only (techo doorway) tx-query tx-execute!)
          (only (techo app) make-app wrap-server))

  ;;; Helpers

  (define (from-to a b) (if (> a b) '() (cons a (from-to (+ a 1) b))))

  (define (join strings sep)
    (if (null? strings)
        ""
        (fold-left (lambda (acc s) (string-append acc sep s)) (car strings) (cdr strings))))

  ;; bytevector<? : Bytevector Bytevector -> Boolean   unsigned, byte by byte, as SQLite orders a BLOB
  (define (bytevector<? a b)
    (let ((n (min (bytevector-length a) (bytevector-length b))))
      (let loop ((i 0))
        (cond ((= i n) (< (bytevector-length a) (bytevector-length b)))
              ((< (bytevector-u8-ref a i) (bytevector-u8-ref b i)) #t)
              ((> (bytevector-u8-ref a i) (bytevector-u8-ref b i)) #f)
              (else (loop (+ i 1)))))))

  (define (id-text id) (uuid->string (bytevector->uuid id)))

  ;; secret-hash : String -> Bytevector    D3: BLAKE2b-256 of the secret's bytes,
  ;; from chez-sodium itself, not (techo auth)
  (define (secret-hash secret) (blake2b (string->utf8 secret) 32))

  (define day-ms 86400000)

  ;;; Randomness: xorshift32, seeded. Every call to the generator is
  ;;; sequenced by a let*: Chez's order of arguments is unspecified.

  (define mask32 #xFFFFFFFF)

  (define (xorshift32 x)
    (let* ((x (bitwise-and mask32 (bitwise-xor x (bitwise-arithmetic-shift-left x 13))))
           (x (bitwise-xor x (bitwise-arithmetic-shift-right x 17)))
           (x (bitwise-and mask32 (bitwise-xor x (bitwise-arithmetic-shift-left x 5)))))
      x))

  ;; Rng = (-> Natural), 32 bits a call
  (define (make-rng seed)
    (let ((x (let ((s (bitwise-and mask32 (+ (* (+ seed 1) 2654435761) 12345))))
               (if (= s 0) 1 s))))
      (for-each (lambda (i) (set! x (xorshift32 x))) (from-to 1 8))
      (lambda () (set! x (xorshift32 x)) x)))

  (define (rng-below! rng n) (mod (rng) n))
  (define (rng-pick! rng xs) (list-ref xs (rng-below! rng (length xs))))
  (define (rng-bytes! rng n)
    (let ((bv (make-bytevector n 0)))
      (for-each (lambda (i)
                  (bytevector-u8-set! bv i (bitwise-and 255 (bitwise-arithmetic-shift-right (rng) 11))))
                (from-to 0 (- n 1)))
      bv))
  ;; rng-weighted! : Rng (Listof (Pair Natural A)) -> A
  (define (rng-weighted! rng options)
    (let loop ((r (rng-below! rng (apply + (map car options)))) (os options))
      (if (< r (caar os)) (cdar os) (loop (- r (caar os)) (cdr os)))))

  ;;; The world

  ;; MAccount: tag ('a or 'b), id, username, email, password hash, created
  (define-record-type macct (fields tag id username email password-hash created))

  (define model-accounts
    (list (make-macct 'a (make-bytevector 16 #xA1) "alice" "alice@example.com"
                      "argon2id-hash-of-alice" 1000)
          (make-macct 'b (make-bytevector 16 #xB2) "bob" "bob@example.com"
                      "argon2id-hash-of-bob" 2000)))

  (define (account-of tag) (find (lambda (a) (eq? (macct-tag a) tag)) model-accounts))
  (define (other-tag tag) (if (eq? tag 'a) 'b 'a))

  ;; MKey: id, tag, label, name, created, secret (its current one), gen (how
  ;; many it had before), state (D5's), revoked and last-used (U Natural #f)
  (define-record-type mkey (fields id tag label name created secret gen state revoked last-used))

  (define (mkey-with k state revoked last-used secret gen)
    (make-mkey (mkey-id k) (mkey-tag k) (mkey-label k) (mkey-name k) (mkey-created k)
               secret gen state revoked last-used))
  (define (with-state k s)
    (mkey-with k s (mkey-revoked k) (mkey-last-used k) (mkey-secret k) (mkey-gen k)))
  (define (with-revoked k now)
    (mkey-with k (mkey-state k) now (mkey-last-used k) (mkey-secret k) (mkey-gen k)))

  ;; touched : MKey Natural -> MKey
  ;; D6: a write sets last_used to NOW when it is null or more than a day old.
  (define (touched k now)
    (let ((lu (mkey-last-used k)))
      (if (or (not lu) (> (- now lu) day-ms))
          (mkey-with k (mkey-state k) (mkey-revoked k) now (mkey-secret k) (mkey-gen k))
          k)))

  ;; Dead = (List String String Tag Bytevector): an old secret, its label
  ;; ("a1.0"), its key's account and id.
  ;; World: keys (Listof MKey) in the order made; dead (Listof Dead), newest first.
  (define-record-type world (fields keys dead))

  ;; model-start : World       no key, no dead secret
  (define model-start (make-world '() '()))

  (define (world-put w k)
    (make-world (map (lambda (x) (if (bytevector=? (mkey-id x) (mkey-id k)) k x)) (world-keys w))
                (world-dead w)))
  (define (world-add w k) (make-world (append (world-keys w) (list k)) (world-dead w)))
  (define (key-with-secret w s) (find (lambda (k) (string=? (mkey-secret k) s)) (world-keys w)))
  (define (dead-with-secret w s) (find (lambda (d) (string=? (car d) s)) (world-dead w)))
  (define (key-with-id w id) (find (lambda (k) (bytevector=? (mkey-id k) id)) (world-keys w)))
  (define (own-key w tag id) (let ((k (key-with-id w id))) (and k (eq? (mkey-tag k) tag) k)))
  (define (keys-of w tag) (filter (lambda (k) (eq? (mkey-tag k) tag)) (world-keys w)))
  (define (live-keys w) (filter (lambda (k) (not (mkey-revoked k))) (world-keys w)))
  (define (by-id ks) (list-sort (lambda (x y) (bytevector<? (mkey-id x) (mkey-id y))) ks))
  (define (known-secret? w s) (or (key-with-secret w s) (dead-with-secret w s)))
  (define (next-label w tag)
    (string-append (symbol->string tag) (number->string (+ 1 (length (keys-of w tag))))))

  ;; world-with-new-secret : World Bytevector String -> World
  ;; Key ID's secret is SECRET; its old one is dead.
  (define (world-with-new-secret w id secret)
    (let ((k (key-with-id w id)))
      (make-world (map (lambda (x)
                         (if (eq? x k)
                             (mkey-with k (mkey-state k) (mkey-revoked k) (mkey-last-used k)
                                        secret (+ 1 (mkey-gen k)))
                             x))
                       (world-keys w))
                  (cons (list (mkey-secret k)
                              (string-append (mkey-label k) "." (number->string (mkey-gen k)))
                              (mkey-tag k) (mkey-id k))
                        (world-dead w)))))

  ;; world-key-view : World Bytevector -> (U (List StateKind (U Natural #f) (U Natural #f)) #f)
  ;; Key ID's state, revoked time and last_used; #f for no such key.
  (define (world-key-view w id)
    (let ((k (key-with-id w id)))
      (and k (list (mkey-state k) (mkey-revoked k) (mkey-last-used k)))))

  ;;; Events

  ;; Event: kind now secret id tag name limit after aims
  ;;   create      the test's own step: key ID of account TAG, named NAME,
  ;;               with SECRET, made at NOW
  ;;   account     GET /v1/account with SECRET
  ;;   keys        GET /v1/keys with SECRET, pages of LIMIT (#f: the
  ;;               default) from AFTER (#f: the start), every page walked
  ;;   revoke      POST /v1/keys/ID/revoke with SECRET
  ;;   regenerate  POST /v1/keys/ID/regenerate with SECRET
  ;; NOW is the wall clock for the request. AIMS is what the generator aimed
  ;; at: the asking secret's kind, then the target's, for counting.
  ;; make-event : Symbol Natural String (U Bytevector #f) (U Tag #f) (U String #f)
  ;;              (U Natural #f) (U Bytevector #f) (Listof Symbol) -> Event
  (define-record-type event (fields kind now secret id tag name limit after aims))

  ;;; The oracle

  ;; command-answers : (Listof (List CommandKind Natural (U String #f)))
  ;; What the caller gets for each command a route performs: D5's last
  ;; column, with D7's codes.
  (define command-answers
    '((admit 200 #f) (set-revoked 200 #f) (nothing 200 #f) (replace-hash 200 #f)
      (refuse-401 401 "unauthorized") (refuse-403 403 "forbidden") (refuse-404 404 "not_found")))

  ;; Expectation: status code rows world body fresh problem
  ;;   status    Natural (#f for a create, which is no request)
  ;;   code      the problem's code, for a refusal
  ;;   rows      the (state event) pairs stepped, in order
  ;;   world     the world after
  ;;   body      for a 200: (account MAccount), (key Id) or (keys (Listof MKey))
  ;;   fresh     the key whose secret the answer replaces, or #f
  ;;   problem   why the model cannot take this step, or #f
  ;; expectation-status : Expectation -> (U Natural #f)
  ;; expectation-code : Expectation -> (U String #f)
  ;; expectation-rows : Expectation -> (Listof (List StateKind EventKind))
  ;; expectation-world : Expectation -> World
  ;; expectation-fresh : Expectation -> (U Bytevector #f)
  ;; expectation-problem : Expectation -> (U String #f)
  (define-record-type expectation (fields status code rows world body fresh problem))

  (define (cannot w rows why) (make-expectation #f #f rows w #f #f why))

  (define (answered w rows command body fresh)
    (let ((a (assq command command-answers)))
      (make-expectation (cadr a) (caddr a) rows w body fresh #f)))

  ;; stepped : Step StateKind EventKind -> (U (List StateKind CommandKind) (List 'cannot String))
  (define (stepped step state ev)
    (if (exists (lambda (c) (and (eq? (car c) state) (eq? (cadr c) ev))) key-cant-happen)
        (list 'cannot (format "asked ~a x ~a, which D5 says cannot happen" state ev))
        (guard (e (#t (list 'cannot (format "the step raised for ~a x ~a: ~a" state ev (describe e)))))
          (call-with-values (lambda () (step state ev)) list))))

  ;; expect : Step World Event -> Expectation
  ;; STEP is key-step, or a stand-in of its shape.
  (define (expect step w e)
    (if (eq? (event-kind e) 'create) (expect-create step w e) (expect-request step w e)))

  (define (expect-create step w e)
    (let ((rows (list (list 'none 'create)))
          (s (stepped step 'none 'create)))
      (cond ((eq? (car s) 'cannot) (cannot w rows (cadr s)))
            ((not (eq? (cadr s) 'insert))
             (cannot w rows (format "none x create names ~a, not insert" (cadr s))))
            ((key-with-id w (event-id e)) (cannot w rows "a create makes a key whose id is taken"))
            (else
             (make-expectation
              #f #f rows
              (world-add w (make-mkey (event-id e) (event-tag e) (next-label w (event-tag e))
                                      (event-name e) (event-now e) (event-secret e) 0 (car s) #f #f))
              #f #f #f)))))

  (define (expect-request step w e)
    (let* ((asker (key-with-secret w (event-secret e)))
           (s0 (if asker (mkey-state asker) 'none))
           (rows (list (list s0 'check)))
           (s (stepped step s0 'check)))
      (if (eq? (car s) 'cannot)
          (cannot w rows (cadr s))
          (let ((n0 (car s)) (c0 (cadr s)))
            (if (and (not asker) (not (eq? n0 'none)))
                (cannot w rows (format "none x check moves to ~a: a key the caller does not have" n0))
                (let ((w1 (if asker (world-put w (with-state asker n0)) w)))
                  (case c0
                    ((refuse-401 refuse-403 refuse-404) (answered w1 rows c0 #f #f))
                    ((admit)
                     (if asker
                         (admitted step w1 rows e (key-with-id w1 (mkey-id asker)))
                         (cannot w1 rows "none x check admits: there is no key to act as")))
                    (else (cannot w1 rows (format "~a x check names ~a, which no check performs"
                                                  s0 c0))))))))))

  (define (listing w tag after)
    (filter (lambda (k) (or (not after) (bytevector<? after (mkey-id k))))
            (by-id (keys-of w tag))))

  (define (admitted step w1 rows e asker)
    (case (event-kind e)
      ((account) (answered w1 rows 'admit (list 'account (account-of (mkey-tag asker))) #f))
      ((keys) (answered w1 rows 'admit (list 'keys (listing w1 (mkey-tag asker) (event-after e))) #f))
      ((revoke regenerate) (target-step step w1 rows e asker))
      (else (cannot w1 rows (format "no such request: ~a" (event-kind e))))))

  (define (target-step step w1 rows0 e asker)
    (let* ((now (event-now e))
           (w2 (world-put w1 (touched asker now)))
           (target (own-key w2 (mkey-tag asker) (event-id e)))
           (t0 (if target (mkey-state target) 'none))
           (ev (cond ((eq? (event-kind e) 'revoke) 'revoke)
                     ((bytevector=? (event-id e) (mkey-id asker)) 'regenerate-self)
                     (else 'regenerate-other)))
           (rows (append rows0 (list (list t0 ev))))
           (s (stepped step t0 ev)))
      (if (eq? (car s) 'cannot)
          (cannot w1 rows (cadr s))
          (let ((n1 (car s)) (c1 (cadr s)))
            (cond
             ((and (not target) (not (eq? n1 'none)))
              (cannot w1 rows (format "none x ~a moves to ~a: a key the caller cannot see" ev n1)))
             (else
              (case c1
                ((refuse-401 refuse-403 refuse-404)
                 ;; One transaction: a refusal rolls the touch back with the rest.
                 (answered (if target
                               (world-put w1 (with-state (key-with-id w1 (mkey-id target)) n1))
                               w1)
                           rows c1 #f #f))
                ((set-revoked nothing replace-hash)
                 (if (not target)
                     (cannot w1 rows (format "none x ~a names ~a: an answer with a key the caller cannot see"
                                             ev c1))
                     (let ((after (if (eq? c1 'set-revoked)
                                      (with-revoked (with-state target n1) now)
                                      (with-state target n1))))
                       (answered (world-put w2 after) rows c1 (list 'key (mkey-id target))
                                 (and (eq? c1 'replace-hash) (mkey-id target))))))
                (else (cannot w1 rows (format "~a x ~a names ~a, which no key route performs"
                                              t0 ev c1))))))))))

  ;;; The invariants, whatever the table says

  ;; invariant-breaks : World Event (U Natural #f) (U String #f) -> (Listof String)
  ;; W is the world before the request, already held to the database. P3:
  ;; only a live key's current secret passes a check, so a dead secret, a
  ;; revoked key's and a stranger's are each a 401 `unauthorized`. P2: a
  ;; revoke or a regenerate by a live key naming no key of its own account
  ;; is a 404 `not_found`. D5: a key regenerates only itself, so naming any
  ;; other id never answers 200.
  (define (invariant-breaks w e status code)
    (if (eq? (event-kind e) 'create)
        '()
        (let* ((asker (key-with-secret w (event-secret e)))
               (live (and asker (not (mkey-revoked asker)) asker)))
          (append
           (if (or live (and (eqv? status 401) (equal? code "unauthorized")))
               '()
               (list (format "P3: ~a is no live key's secret, yet the answer is ~a ~s"
                             (secret-label w (event-secret e)) status code)))
           (if (and live
                    (memq (event-kind e) '(revoke regenerate))
                    (not (own-key w (mkey-tag live) (event-id e)))
                    (not (and (eqv? status 404) (equal? code "not_found"))))
               (list (format "P2: ~a names ~a, no key of its account, yet the answer is ~a ~s"
                             (mkey-label live) (id-label w (event-id e)) status code))
               '())
           (if (and live
                    (eq? (event-kind e) 'regenerate)
                    (not (bytevector=? (event-id e) (mkey-id live)))
                    (eqv? status 200))
               (list (format "D5: a key regenerates only itself, yet ~a regenerated ~a"
                             (mkey-label live) (id-label w (event-id e))))
               '())))))

  ;;; Labels, for reports

  (define (secret-label w s)
    (let ((k (key-with-secret w s)))
      (if k
          (format "~a.~a (~a)" (mkey-label k) (mkey-gen k) (mkey-state k))
          (let ((d (dead-with-secret w s)))
            (if d (format "~a (dead)" (cadr d)) "a stranger's secret")))))

  (define (id-label w id)
    (let ((k (key-with-id w id)))
      (if k (format "~a (~a)" (mkey-label k) (mkey-state k)) "an id of no key")))

  (define (hash-label w h)
    (let ((k (find (lambda (k) (bytevector=? h (secret-hash (mkey-secret k)))) (world-keys w))))
      (if k
          (format "hash(~a.~a)" (mkey-label k) (mkey-gen k))
          (let ((d (find (lambda (d) (bytevector=? h (secret-hash (car d)))) (world-dead w))))
            (if d (format "hash(~a, dead)" (cadr d)) "a hash of no secret the test knows")))))

  (define (describe-event w e t0)
    (let ((at (format "t+~a" (- (event-now e) t0))))
      (case (event-kind e)
        ((create) (format "~a make ~a, ~s, by the store" at (next-label w (event-tag e)) (event-name e)))
        ((account) (format "~a GET /v1/account as ~a" at (secret-label w (event-secret e))))
        ((keys) (format "~a GET /v1/keys~a~a as ~a" at
                        (if (event-limit e) (format " limit=~a" (event-limit e)) "")
                        (if (event-after e) (format " after=~a" (id-label w (event-after e))) "")
                        (secret-label w (event-secret e))))
        (else (format "~a ~a ~a as ~a" at (event-kind e) (id-label w (event-id e))
                      (secret-label w (event-secret e)))))))

  (define (rows-text rows)
    (join (map (lambda (r) (format "~a x ~a" (car r) (cadr r))) rows) ", "))

  ;;; The generator

  (define (fresh-id rng w)
    (let ((id (rng-bytes! rng 16)))
      (if (key-with-id w id) (fresh-id rng w) id)))

  (define (next-time rng now)
    (let* ((r (rng-below! rng 100))
           (small (+ 1 (rng-below! rng 1000)))
           (long (rng-below! rng day-ms)))
      (+ now (cond ((< r 70) small)
                   ((< r 80) day-ms)
                   ((< r 90) (+ day-ms 1))
                   (else (+ (* 2 day-ms) long))))))

  (define (create-event rng w now tag)
    (let* ((id (fresh-id rng w))
           (secret (key-secret (rng-bytes! rng 32))))
      (make-event 'create now secret id tag
                  (string-append "device " (number->string (+ 1 (length (world-keys w)))))
                  #f #f '(create))))

  ;; Asker = (List Symbol String Tag (U Bytevector #f)): what was aimed at,
  ;; the secret, the account it speaks for, the key's own id.
  (define (choose-asker rng w)
    (let* ((live (live-keys w))
           (gone (filter mkey-revoked (world-keys w)))
           (dead (world-dead w))
           (aim (rng-weighted! rng (append (if (pair? live) '((60 . live-secret)) '())
                                           (if (pair? gone) '((14 . revoked-secret)) '())
                                           (if (pair? dead) '((16 . dead-secret)) '())
                                           '((10 . stranger-secret))))))
      (case aim
        ((live-secret revoked-secret)
         (let ((k (rng-pick! rng (if (eq? aim 'live-secret) live gone))))
           (list aim (mkey-secret k) (mkey-tag k) (mkey-id k))))
        ((dead-secret)
         (let ((d (rng-pick! rng dead)))
           (list aim (car d) (caddr d) (cadddr d))))
        (else
         (let* ((bytes (rng-bytes! rng 32))
                (tag (rng-pick! rng '(a b))))
           (list aim (key-secret bytes) tag #f))))))

  (define (choose-target rng w asker)
    (let* ((tag (caddr asker))
           (self (cadddr asker))
           (siblings (filter (lambda (k) (not (and self (bytevector=? (mkey-id k) self))))
                             (keys-of w tag)))
           (revoked (filter mkey-revoked siblings))
           (theirs (keys-of w (other-tag tag)))
           (aim (rng-weighted! rng (append (if self '((25 . self)) '())
                                           (if (pair? siblings) '((30 . sibling)) '())
                                           (if (pair? revoked) '((10 . revoked-target)) '())
                                           (if (pair? theirs) '((20 . other-account)) '())
                                           '((15 . no-key))))))
      (case aim
        ((self) (values self aim))
        ((sibling) (values (mkey-id (rng-pick! rng siblings)) aim))
        ((revoked-target) (values (mkey-id (rng-pick! rng revoked)) aim))
        ((other-account) (values (mkey-id (rng-pick! rng theirs)) aim))
        (else (values (fresh-id rng w) aim)))))

  (define (next-event rng w now0)
    (let* ((now (next-time rng now0))
           (live (length (live-keys w)))
           (total (length (world-keys w)))
           (kind (rng-weighted! rng (append (cond ((>= total 14) '())
                                                  ((< live 2) '((30 . create)))
                                                  (else '((6 . create))))
                                            '((8 . account) (12 . keys) (30 . revoke)
                                              (44 . regenerate))))))
      (if (eq? kind 'create)
          (let ((tag (rng-pick! rng '(a b))))
            (create-event rng w now tag))
          (let ((asker (choose-asker rng w)))
            (case kind
              ((account) (make-event 'account now (cadr asker) #f #f #f #f #f (list (car asker))))
              ((keys)
               (let* ((limit (rng-pick! rng '(#f #f #f 1 2 3 100)))
                      (r (rng-below! rng 100))
                      (theirs (keys-of w (other-tag (caddr asker))))
                      (after (cond ((>= r 15) #f)
                                   ((pair? theirs) (mkey-id (rng-pick! rng theirs)))
                                   (else (fresh-id rng w)))))
                 (make-event 'keys now (cadr asker) #f #f #f limit after
                             (if after (list (car asker) 'after) (list (car asker))))))
              (else
               (let-values (((id aim) (choose-target rng w asker)))
                 (make-event kind now (cadr asker) id #f #f #f #f (list (car asker) aim)))))))))

  (define (sequence-length rng)
    (let* ((r (rng-below! rng 100))
           (a (rng-below! rng 8))
           (b (rng-below! rng 31))
           (c (rng-below! rng 51)))
      (cond ((< r 25) (+ 1 a)) ((< r 75) (+ 10 b)) (else (+ 40 c)))))

  ;;; The shell: one request through the stack

  ;; Obs: what the client read. status code json cache (cache-control)
  ;; items (a walk's items, every page) problems (a walk's own) requests
  (define-record-type obs (fields status code json cache items problems requests))

  (define (problem-code a)
    (let ((j (answer-json a)))
      (and (>= (answer-status a) 400) (list? j)
           (let ((c (assoc "code" j))) (and c (cdr c))))))

  (define (single a)
    (make-obs (answer-status a) (problem-code a) (answer-json a) (answer-header a "cache-control")
              #f '() 1))

  (define (keys-target limit after)
    (let ((q (append (if limit (list (string-append "limit=" (number->string limit))) '())
                     (if after (list (string-append "after=" (id-text after))) '()))))
      (if (null? q) "/v1/keys" (string-append "/v1/keys?" (join q "&")))))

  (define (field j name)
    (let ((p (and (list? j) (assoc name j))))
      (if p (cdr p) (assertion-violation 'field "the answer has no such field" name j))))

  ;; walk : Handler Event -> Obs
  ;; GET /v1/keys page by page from the event's AFTER, each `next` followed,
  ;; at most 40 pages.
  (define (walk h e)
    (let ((cap (or (event-limit e) 50))
          (auth (list (bearer (event-secret e)))))
      (let loop ((after (event-after e)) (n 1) (items '()) (problems '()))
        (let ((a (exchange h 'GET (keys-target (event-limit e) after) auth)))
          (if (not (= (answer-status a) 200))
              (make-obs (answer-status a) (problem-code a) (answer-json a) #f items
                        (if (> n 1)
                            (cons (format "page ~a answered ~a after a 200" n (answer-status a)) problems)
                            problems)
                        n)
              (let* ((j (answer-json a))
                     (page (vector->list (field j "items")))
                     (next (field j "next"))
                     (problems
                      (append problems
                              (if (> (length page) cap)
                                  (list (format "page ~a has ~a items, over its limit ~a" n (length page) cap))
                                  '())
                              (if (and (string? next)
                                       (not (and (= (length page) cap)
                                                 (equal? next (field (car (reverse page)) "id")))))
                                  (list (format "page ~a's next is not the last id of a full page" n))
                                  '())))
                     (items (append items page)))
                (cond ((not (string? next)) (make-obs 200 #f j #f items problems n))
                      ((>= n 40) (make-obs 200 #f j #f items
                                           (cons "the walk did not end in 40 pages" problems) n))
                      (else (loop (uuid->bytevector (string->uuid next)) (+ n 1) items problems)))))))))

  ;; observe : Handler Event -> Obs
  (define (observe h e)
    (let ((auth (list (bearer (event-secret e)))))
      (case (event-kind e)
        ((account) (single (exchange h 'GET "/v1/account" auth)))
        ((keys) (walk h e))
        (else (single (exchange h 'POST
                                (string-append "/v1/keys/" (id-text (event-id e)) "/"
                                               (symbol->string (event-kind e)))
                                auth))))))

  ;;; Comparing an answer

  (define (sorted alist) (list-sort (lambda (x y) (string<? (car x) (car y))) alist))
  (define (sorted-json j)
    (if (and (list? j) (for-all (lambda (p) (and (pair? p) (string? (car p)))) j)) (sorted j) j))

  ;; key-json : MKey -> Alist     a key as D9 shows it, never its hash
  (define (key-json k)
    (sorted (list (cons "id" (id-text (mkey-id k))) (cons "name" (mkey-name k))
                  (cons "created" (mkey-created k))
                  (cons "last_used" (or (mkey-last-used k) 'null))
                  (cons "revoked" (or (mkey-revoked k) 'null)))))

  (define (account-json a)
    (sorted (list (cons "id" (id-text (macct-id a))) (cons "username" (macct-username a))
                  (cons "email" (macct-email a)) (cons "created" (macct-created a)))))

  (define (same what want got)
    (if (equal? want got) '() (list (format "~a: the model has ~s, the handlers answered ~s" what want got))))

  (define (secret-breaks w target j o)
    (let ((s (and (list? j) (assoc "key" j))))
      (cond ((not s) (list "regenerate answered 200 with no \"key\""))
            ((not (key-secret? (cdr s))) (list (format "regenerate's \"key\" is no secret: ~s" (cdr s))))
            (else
             (append
              (cond ((string=? (cdr s) (mkey-secret (key-with-id w target)))
                     (list "regenerate answered the key's old secret"))
                    ((known-secret? w (cdr s))
                     (list (format "regenerate answered ~a, a secret already known" (secret-label w (cdr s)))))
                    (else '()))
              (if (equal? (obs-cache o) "no-store")
                  '()
                  (list (format "regenerate's cache-control is ~s, not no-store" (obs-cache o)))))))))

  (define (body-breaks w x e o)
    (let ((body (expectation-body x))
          (j (obs-json o)))
      (case (car body)
        ((account) (same "the account" (account-json (cadr body)) (sorted-json j)))
        ((keys) (same "the listing" (map key-json (cadr body)) (map sorted-json (obs-items o))))
        ((key)
         (let ((k (key-with-id (expectation-world x) (cadr body))))
           (append
            (same (format "the key ~a" (mkey-label k)) (key-json k)
                  (sorted-json (if (list? j) (filter (lambda (p) (not (equal? (car p) "key"))) j) j)))
            (if (eq? (event-kind e) 'regenerate)
                (secret-breaks w (cadr body) j o)
                (if (and (list? j) (assoc "key" j)) (list "a revoke's answer carries a secret") '())))))
        (else (list "the model has no body for this answer")))))

  ;; answer-breaks : World Expectation Event Obs -> (Listof String)
  (define (answer-breaks w x e o)
    (let ((want (expectation-status x)) (got (obs-status o)))
      (append
       (if (eqv? want got) '() (list (format "status: the table says ~a, the handlers answered ~a" want got)))
       (if (and (expectation-code x) (eqv? want got) (not (equal? (expectation-code x) (obs-code o))))
           (list (format "code: the table says ~s, the handlers answered ~s" (expectation-code x) (obs-code o)))
           '())
       (obs-problems o)
       (if (and (eqv? want 200) (eqv? got 200)) (body-breaks w x e o) '()))))

  ;; world-after : Expectation Obs -> World
  ;; The expectation's world, and a regenerate's new secret from its answer.
  (define (world-after x o)
    (let* ((w (expectation-world x))
           (j (obs-json o))
           (s (and (expectation-fresh x) (eqv? (obs-status o) 200) (list? j) (assoc "key" j))))
      (if (and s (string? (cdr s)) (not (known-secret? w (cdr s))))
          (world-with-new-secret w (expectation-fresh x) (cdr s))
          w)))

  ;;; Comparing the database

  (define (row->list v) (map (lambda (c) (if (sql-null? c) #f c)) (vector->list v)))

  (define (db-now store)
    (run-read store
              (lambda (tx)
                (list (map row->list
                           (tx-query tx "SELECT id, account, name, key_hash, created, last_used, revoked FROM api_keys ORDER BY id"))
                      (map row->list
                           (tx-query tx "SELECT id, username, email, password_hash, created FROM accounts ORDER BY id"))))))

  (define (model-row k)
    (list (mkey-id k) (macct-id (account-of (mkey-tag k))) (mkey-name k) (secret-hash (mkey-secret k))
          (mkey-created k) (mkey-last-used k) (mkey-revoked k)))

  (define (account-row a)
    (list (macct-id a) (macct-username a) (macct-email a) (macct-password-hash a) (macct-created a)))

  (define (show-row w r)
    (let ((acct (find (lambda (a) (bytevector=? (macct-id a) (list-ref r 1))) model-accounts)))
      (format "(account ~a, name ~s, key_hash ~a, created ~a, last_used ~a, revoked ~a)"
              (if acct (macct-tag acct) "of no account") (list-ref r 2) (hash-label w (list-ref r 3))
              (list-ref r 4) (list-ref r 5) (list-ref r 6))))

  ;; db-breaks : World (List Rows Rows) -> (Listof String)
  ;; Every key's row is the model's: its account, name, created, last_used
  ;; and revoked, and its key_hash the hash of its current secret; no row
  ;; the model has not; the accounts as made. And the model agrees with
  ;; itself: a key is revoked exactly when it has a revoked time.
  (define (db-breaks w db)
    (let ((rows (car db))
          (want (map model-row (by-id (world-keys w)))))
      (append
       (fold-right
        (lambda (k acc)
          (if (eq? (mkey-state k) (if (mkey-revoked k) 'revoked 'active))
              acc
              (cons (format "the model's ~a is ~a, yet its revoked time is ~a: the table's next and its command disagree"
                            (mkey-label k) (mkey-state k) (mkey-revoked k))
                    acc)))
        '() (world-keys w))
       (if (equal? want rows)
           '()
           (append
            (fold-right
             (lambda (k acc)
               (let ((r (find (lambda (r) (bytevector=? (car r) (mkey-id k))) rows)))
                 (cond ((not r) (cons (format "~a has no row" (mkey-label k)) acc))
                       ((equal? r (model-row k)) acc)
                       (else (cons (format "~a's row is ~a, the model's ~a" (mkey-label k)
                                           (show-row w r) (show-row w (model-row k)))
                                   acc)))))
             '() (by-id (world-keys w)))
            (map (lambda (r) (format "a row the model does not have: ~a ~a" (id-text (car r)) (show-row w r)))
                 (filter (lambda (r) (not (key-with-id w (car r)))) rows))
            (if (equal? (map car rows) (map car want)) '() (list "the rows are not in id order, or not the model's"))))
       (if (equal? (cadr db) (map account-row model-accounts)) '() (list "the accounts table is not as made")))))

  ;;; One sequence

  ;; Verdict: seed requests rows aims cant-happen report
  ;;   requests     HTTP requests sent
  ;;   rows, aims   (Listof (Pair Key Natural)): D5's (state event) pairs
  ;;                stepped, and what the generator aimed at, with counts
  ;;   cant-happen  how many pairs of key-cant-happen the model was asked
  ;;   report       #f when every request agreed; else the first difference
  ;; verdict-seed, verdict-requests, verdict-cant-happen : Verdict -> Natural
  ;; verdict-rows : Verdict -> (Listof (Pair (List StateKind EventKind) Natural))
  ;; verdict-aims : Verdict -> (Listof (Pair Symbol Natural))
  ;; verdict-report : Verdict -> (U String #f)
  (define-record-type verdict (fields seed requests rows aims cant-happen report))

  (define (reset! store)
    (run-write store
               (lambda (tx)
                 (tx-execute! tx "DELETE FROM api_keys")
                 (tx-execute! tx "DELETE FROM accounts")
                 (for-each (lambda (a)
                             (insert-account! tx (macct-id a) (macct-username a) (macct-email a)
                                              (macct-password-hash a) (macct-created a)))
                           model-accounts))))

  (define (attempt thunk)
    (guard (c (#t (list 'raised (describe c))))
      (list 'ok (thunk))))

  (define (hashtable->alist t)
    (let-values (((ks vs) (hashtable-entries t)))
      (map cons (vector->list ks) (vector->list vs))))

  ;; run-sequence : Store Step Natural Boolean -> Verdict
  ;; The sequence SEED makes, on STORE, emptied first: a fresh app on it
  ;; (wrap-server around make-app, its random bytes a sequence of its own,
  ;; its wall clock set by the sequence), 1 to 3 keys for each account,
  ;; then the generated requests, then a listing for each account with a
  ;; live key. STEP is the oracle's step (key-step, or a mutant). TRACE?
  ;; prints each request and its answer as it goes.
  (define (run-sequence store step seed trace?)
    (let* ((rng (make-rng seed))
           (n (sequence-length rng))
           (ca (+ 1 (rng-below! rng 3)))
           (cb (+ 1 (rng-below! rng 3)))
           (t0 (+ 1795515226123 (rng-below! rng 100000)))
           (now-cell (vector t0))
           (clock (step-clock 0 1))
           (h (wrap-server (make-app (store-reader store) (store-writer store)
                                     (lambda () (vector-ref now-cell 0))
                                     (byte-sequence) clock)
                           (lambda (line) #f) 10000 clock))
           (rows (make-hashtable equal-hash equal?))
           (aims (make-hashtable symbol-hash eq?))
           (requests 0)
           (cant 0)
           (log '()))

      (define (count! t k by) (hashtable-update! t k (lambda (c) (+ c by)) 0))

      ;; plan : World Natural Natural -> (U Event 'skip #f)
      (define (plan w now i)
        (cond ((< i ca) (create-event rng w now 'a))
              ((< i (+ ca cb)) (create-event rng w now 'b))
              ((< i (+ ca cb n)) (next-event rng w now))
              ((< i (+ ca cb n 2))
               (let* ((tag (if (= i (+ ca cb n)) 'a 'b))
                      (live (filter (lambda (k) (eq? (mkey-tag k) tag)) (live-keys w))))
                 (if (null? live)
                     'skip
                     (make-event 'keys (+ now 1) (mkey-secret (car live)) #f #f #f #f #f '(closing)))))
              (else #f)))

      (define (report w i e desc x o breaks)
        (string-append
         (format "seed ~a, step ~a: the sequence so far:\n" seed i)
         (apply string-append (map (lambda (l) (string-append "    " l "\n")) (reverse log)))
         (format "  this step: ~a\n" desc)
         (format "  the table says: ~a ~s, stepping ~a~a\n"
                 (expectation-status x) (expectation-code x) (rows-text (expectation-rows x))
                 (if (expectation-problem x) (string-append "; " (expectation-problem x)) ""))
         (if o
             (format "  the handlers answered: ~a ~s ~s\n" (obs-status o) (obs-code o) (obs-json o))
             "")
         (apply string-append (map (lambda (b) (string-append "  - " b "\n")) breaks))
         (format "  replay: TECHO_KEYS_MODEL_SEED=~a\n" seed)))

      ;; step! : World Natural Event -> (U World String)
      ;; The world after E, or the report of its first difference.
      (define (step! w i e)
        (let* ((desc (describe-event w e t0))
               (x (expect step w e)))
          (for-each (lambda (r)
                      (when (exists (lambda (c) (and (eq? (car c) (car r)) (eq? (cadr c) (cadr r))))
                                    key-cant-happen)
                        (set! cant (+ cant 1))))
                    (expectation-rows x))
          (cond
           ((expectation-problem x) (report w i e desc x #f '("the model cannot take this step")))
           ((eq? (event-kind e) 'create)
            (let* ((made (attempt (lambda ()
                                    (run-write store
                                               (lambda (tx)
                                                 (insert-key! tx (event-id e) (macct-id (account-of (event-tag e)))
                                                              (event-name e) (secret-hash (event-secret e))
                                                              (event-now e)))))))
                   (after (expectation-world x))
                   (db (attempt (lambda () (db-now store))))
                   (breaks (append (if (eq? (car made) 'raised) (list (string-append "the insert raised: " (cadr made))) '())
                                   (if (eq? (car db) 'raised)
                                       (list (string-append "reading the database raised: " (cadr db)))
                                       (db-breaks after (cadr db))))))
              (for-each (lambda (r) (count! rows r 1)) (expectation-rows x))
              (count! aims 'create 1)
              (set! log (cons (format "~a. ~a" i desc) log))
              (when trace? (display (format "~a. ~a\n" i desc)))
              (if (null? breaks) after (report w i e desc x #f breaks))))
           (else
            (vector-set! now-cell 0 (event-now e))
            (let ((seen (attempt (lambda () (observe h e)))))
              (if (eq? (car seen) 'raised)
                  (report w i e desc x #f (list (string-append "the request raised: " (cadr seen))))
                  (let* ((o (cadr seen))
                         (after (world-after x o))
                         (db (attempt (lambda () (db-now store))))
                         (breaks (append (guard (c (#t (list (string-append "comparing the answer raised: "
                                                                             (describe c)))))
                                           (answer-breaks w x e o))
                                         (invariant-breaks w e (obs-status o) (obs-code o))
                                         (if (eq? (car db) 'raised)
                                             (list (string-append "reading the database raised: " (cadr db)))
                                             (db-breaks after (cadr db))))))
                    (set! requests (+ requests (obs-requests o)))
                    (for-each (lambda (r) (count! rows r (if (eq? (cadr r) 'check) (obs-requests o) 1)))
                              (expectation-rows x))
                    (count! aims (car (event-aims e)) 1)
                    (when (and (eq? (car (event-aims e)) 'live-secret) (pair? (cdr (event-aims e))))
                      (count! aims (cadr (event-aims e)) 1))
                    (set! log (cons (format "~a. ~a -> ~a~a" i desc (obs-status o)
                                            (if (obs-code o) (format " ~a" (obs-code o)) ""))
                                    log))
                    (when trace? (display (format "~a. ~a -> ~a (the table: ~a, ~a)\n" i desc (obs-status o)
                                                  (expectation-status x) (rows-text (expectation-rows x)))))
                    (if (null? breaks) after (report w i e desc x o breaks)))))))))

      (reset! store)
      (let loop ((w model-start) (now t0) (i 0))
        (let ((e (plan w now i)))
          (cond
           ((not e) (make-verdict seed requests (hashtable->alist rows) (hashtable->alist aims) cant #f))
           ((eq? e 'skip) (loop w now (+ i 1)))
           (else
            (let ((r (step! w i e)))
              (if (string? r)
                  (make-verdict seed requests (hashtable->alist rows) (hashtable->alist aims) cant r)
                  (loop r (event-now e) (+ i 1))))))))))
)
