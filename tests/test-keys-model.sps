#!r6rs
;;; The key model suite: ADR-0007's third layer for D5's key lifecycle
;;; (slice 3a, task 4). Seeded random sequences of requests run against the
;;; real handlers (make-app inside wrap-server, raw HTTP through a test
;;; host) and real SQLite (the test doorway on a migrated file), each
;;; answer compared with what key-step says (P7), P2 and P3 held whatever
;;; the table says, and the whole of api_keys compared with the model after
;;; every request. The machinery and the model are (keys-model).
;;;
;;;   1. the oracle on a hand-made world, pure
;;;   2. the run: SEQUENCES seeds, every one to agree
;;;   3. coverage: every row of key-rows stepped, every aim of the
;;;      generator taken, no pair of key-cant-happen asked
;;;   4. teeth: the oracle given a changed table disagrees with the handlers
;;;
;;; Replay one seed, each request printed as it goes:
;;;   scripts/guix-env sh -c 'TECHO_KEYS_MODEL_SEED=17 make test SUITES=tests/test-keys-model.sps'
;;; Then only that seed runs, and only its agreement is asserted.
;;;
;;; Its files are under build/test-keys-model/<unique>/, emptied at the
;;; start. Everything that can raise is computed under `attempt`, and a
;;; raise comes out as a value the expectation never is.
(import (rnrs)
        (only (chezscheme) getenv real-time format)
        (srfi :64)
        (techo-testing)
        (http-support)
        (techo keys)
        (keys-model))

(define runner (test-runner-simple))
(test-runner-current runner)

(define started (real-time))

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define (from-to a b) (if (> a b) '() (cons a (from-to (+ a 1) b))))
(define (take* xs n) (if (or (null? xs) (= n 0)) '() (cons (car xs) (take* (cdr xs) (- n 1)))))

(test-begin "keys-model")

;;; 1. The oracle, on a hand-made world

;; Key n's id is 16 bytes of n, its secret key-secret of 32 bytes of n.
(define (kid n) (make-bytevector 16 n))
(define (sec n) (key-secret (make-bytevector 32 n)))
(define t0 1795515226123)

(define (create tag n)
  (make-event 'create t0 (sec n) (kid n) tag (string-append "k" (number->string n)) #f #f '(create)))
(define (req-at at kind secret target) (make-event kind at secret target #f #f #f #f '()))
(define (req kind secret target) (req-at (+ t0 5) kind secret target))
(define day+1 (+ t0 5 86400001))

;; summary : Expectation -> (List Status Code Rows Problem)
(define (summary x)
  (list (expectation-status x) (expectation-code x) (expectation-rows x) (expectation-problem x)))

;; The hand world: a's keys 1 and 3 live, 2 revoked by 1; b's key 4 live.
(define hand
  (attempt
   (lambda ()
     (let ((w (fold-left (lambda (w e) (expectation-world (expect key-step w e)))
                         model-start
                         (list (create 'a 1) (create 'a 2) (create 'a 3) (create 'b 4)))))
       (expectation-world (expect key-step w (req 'revoke (sec 1) (kid 2))))))))

(define (oracle step kind secret target)
  (attempt (lambda () (summary (expect step hand (req kind secret target))))))

(test-equal "oracle: a stranger's secret is none x check, a 401"
  '(401 "unauthorized" ((none check)) #f)
  (oracle key-step 'account (sec 99) #f))

(test-equal "oracle: a revoked key's secret is revoked x check, a 401"
  '(401 "unauthorized" ((revoked check)) #f)
  (oracle key-step 'keys (sec 2) #f))

(test-equal "oracle: a key naming the other account's key is none x revoke for it, a 404"
  '(404 "not_found" ((active check) (none revoke)) #f)
  (oracle key-step 'revoke (sec 1) (kid 4)))

(test-equal "oracle: an id of no key is none x regenerate-other, a 404"
  '(404 "not_found" ((active check) (none regenerate-other)) #f)
  (oracle key-step 'regenerate (sec 1) (kid 77)))

(test-equal "oracle: a key regenerating itself is regenerate-self, a 200 that replaces its secret"
  (list '(200 #f ((active check) (active regenerate-self)) #f) (kid 1))
  (attempt (lambda ()
             (let ((x (expect key-step hand (req 'regenerate (sec 1) (kid 1)))))
               (list (summary x) (expectation-fresh x))))))

(test-equal "oracle: a key regenerating a live sibling is a 403; a revoked sibling, a 403 too"
  '((403 "forbidden" ((active check) (active regenerate-other)) #f)
    (403 "forbidden" ((active check) (revoked regenerate-other)) #f))
  (list (oracle key-step 'regenerate (sec 1) (kid 3))
        (oracle key-step 'regenerate (sec 1) (kid 2))))

(test-equal "oracle: revoking a revoked key is nothing, a 200"
  '(200 #f ((active check) (revoked revoke)) #f)
  (oracle key-step 'revoke (sec 1) (kid 2)))

(test-equal "oracle: a day and a ms on, a revoke sets the time and the asker's last_used; a refusal rolls the touch back"
  '(((revoked 1795601626129 #f) (active #f 1795601626129))
    ((active #f #f) (active #f 1795515226128)))
  (attempt
   (lambda ()
     (let ((ok (expectation-world (expect key-step hand (req-at day+1 'revoke (sec 1) (kid 3)))))
           (no (expectation-world (expect key-step hand (req-at day+1 'regenerate (sec 1) (kid 3))))))
       (list (list (world-key-view ok (kid 3)) (world-key-view ok (kid 1)))
             (list (world-key-view no (kid 3)) (world-key-view no (kid 1))))))))

(test-equal "oracle: after a regenerate the old secret is none, the new one is admitted"
  '((401 "unauthorized" ((none check)) #f) (200 #f ((active check)) #f))
  (attempt
   (lambda ()
     (let* ((x (expect key-step hand (req 'regenerate (sec 1) (kid 1))))
            (w (world-with-new-secret (expectation-world x) (kid 1) (sec 11))))
       (list (summary (expect key-step w (req 'account (sec 1) #f)))
             (summary (expect key-step w (req 'account (sec 11) #f))))))))

;; A changed table, as the oracle's step: a revoked key's check admits.
(define (admits-revoked state event)
  (if (and (eq? state 'revoked) (eq? event 'check))
      (values 'revoked 'admit)
      (key-step state event)))

;; A changed table: a key may regenerate a live sibling.
(define (regenerates-siblings state event)
  (if (and (eq? state 'active) (eq? event 'regenerate-other))
      (values 'active 'replace-hash)
      (key-step state event)))

(test-equal "oracle: its answer is its step's: a changed table admits a revoked key"
  '(200 #f ((revoked check)) #f)
  (oracle admits-revoked 'account (sec 2) #f))

(test-equal "oracle: a pair D5 says cannot happen is not stepped, and says why"
  '(#f #f ((revoked check) (revoked regenerate-self))
       "asked revoked x regenerate-self, which D5 says cannot happen")
  (oracle admits-revoked 'regenerate (sec 2) (kid 2)))

(define (break-kinds bs) (map (lambda (b) (substring b 0 2)) bs))

(test-equal "invariants: a revoked key's secret answered 200 breaks P3; a dead or stranger's, too"
  '(("P3") ("P3") ())
  (attempt
   (lambda ()
     (list (break-kinds (invariant-breaks hand (req 'account (sec 2) #f) 200 #f))
           (break-kinds (invariant-breaks hand (req 'keys (sec 99) #f) 403 "forbidden"))
           (break-kinds (invariant-breaks hand (req 'keys (sec 99) #f) 401 "unauthorized"))))))

(test-equal "invariants: the other account's key, or no key, answered other than 404 breaks P2"
  '(("P2") ("P2") ())
  (attempt
   (lambda ()
     (list (break-kinds (invariant-breaks hand (req 'revoke (sec 1) (kid 4)) 200 #f))
           (break-kinds (invariant-breaks hand (req 'regenerate (sec 1) (kid 77)) 403 "forbidden"))
           (break-kinds (invariant-breaks hand (req 'revoke (sec 1) (kid 4)) 404 "not_found"))))))

(test-equal "invariants: a sibling regenerated with a 200 breaks D5's only-itself; itself does not"
  '(("D5") ())
  (attempt
   (lambda ()
     (list (break-kinds (invariant-breaks hand (req 'regenerate (sec 1) (kid 3)) 200 #f))
           (break-kinds (invariant-breaks hand (req 'regenerate (sec 1) (kid 1)) 200 #f))))))

;;; The store every sequence runs on, emptied by each

(define dir (attempt (lambda () (fresh-dir "test-keys-model"))))
(define store (attempt (lambda () (open-test-store dir "model.db"))))

;; run-one : Step Natural Boolean -> (U Verdict (List 'raised String))
(define (run-one step seed trace?)
  (attempt (lambda () (run-sequence store step seed trace?))))

(define (raised? x) (and (pair? x) (eq? (car x) 'raised)))

;; failure : (U Verdict (List 'raised String)) -> (U String #f)
(define (failure v)
  (cond ((raised? v) (string-append "a sequence raised: " (cadr v)))
        ((verdict-report v) => (lambda (r) r))
        (else #f)))

(define replay-seed
  (let ((s (getenv "TECHO_KEYS_MODEL_SEED")))
    (and s (string->number s))))


;;; Replay: one seed, traced

(define replayed (and replay-seed (failure (run-one key-step replay-seed #t))))

(when replay-seed
  (when replayed (display replayed))
  (test-equal (format "replay of seed ~a: every request agrees" replay-seed) #f replayed))

;;; 2. The run

(define sequences 400)
(define verdicts (if replay-seed '() (map (lambda (s) (run-one key-step s #f)) (from-to 1 sequences))))
(define failures (filter (lambda (f) f) (map failure verdicts)))
(define agreed (filter (lambda (v) (not (or (raised? v) (verdict-report v)))) verdicts))

(for-each (lambda (f) (display f) (newline)) (take* failures 3))

;; tally : (Verdict -> (Listof (Pair K Natural))) -> Hashtable
(define (tally of)
  (let ((t (make-hashtable equal-hash equal?)))
    (for-each (lambda (v)
                (for-each (lambda (p) (hashtable-update! t (car p) (lambda (c) (+ c (cdr p))) 0))
                          (of v)))
              agreed)
    t))

(define rows-hit (tally verdict-rows))
(define aims-hit (tally verdict-aims))
(define requests (apply + (map verdict-requests agreed)))
(define cant-happen
  (apply + (map verdict-cant-happen (filter (lambda (v) (not (raised? v))) verdicts))))

(define row-floor 100)
(define aim-floor 100)
(define aims '(create live-secret revoked-secret dead-secret stranger-secret
               self sibling revoked-target other-account no-key after))

(define (at-least floor n) (if (>= n floor) (list 'at-least floor) (list 'only n)))

(unless replay-seed
  (test-equal "the run: every sequence agrees with key-step, and P2 and P3 hold (the first three that do not)"
    '()
    (take* failures 3))

  (test-equal "the run: every one of the sequences ran and agreed" sequences (length agreed))

  (test-equal "the run: at least 10,000 requests" '(at-least 10000) (at-least 10000 requests))

  ;;; 3. Coverage

  (for-each
   (lambda (row)
     (test-equal (format "coverage: ~a x ~a (~a) is stepped at least ~a times"
                         (car row) (cadr row) (cadddr row) row-floor)
       (list 'at-least row-floor)
       (at-least row-floor (hashtable-ref rows-hit (list (car row) (cadr row)) 0))))
   key-rows)

  (test-equal "coverage: no pair D5 says cannot happen was asked, in any sequence" 0 cant-happen)

  (for-each
   (lambda (aim)
     (test-equal (format "coverage: the generator aimed at ~a at least ~a times" aim aim-floor)
       (list 'at-least aim-floor)
       (at-least aim-floor (hashtable-ref aims-hit aim 0))))
   aims)

  (display (format "keys-model: ~a sequences, ~a requests\n" (length agreed) requests))
  (for-each (lambda (row)
              (display (format "  ~a x ~a: ~a\n" (car row) (cadr row)
                               (hashtable-ref rows-hit (list (car row) (cadr row)) 0))))
            key-rows)
  (for-each (lambda (aim) (display (format "  aim ~a: ~a\n" aim (hashtable-ref aims-hit aim 0))))
            (append aims '(closing))))

;;; 4. Teeth: the oracle with a changed table, the handlers as they are

;; first-difference : Step (Listof Natural) -> (U String #f)
(define (first-difference step seeds)
  (let loop ((ss seeds))
    (if (null? ss)
        #f
        (or (failure (run-one step (car ss) #f)) (loop (cdr ss))))))

(unless replay-seed
  (test-equal "teeth: a table that admits a revoked key's check disagrees with the handlers' 401"
    #t
    (let ((f (first-difference admits-revoked (from-to 1 50))))
      (and f
           (contains? f "stepping revoked x check")
           (contains? f "the handlers answered: 401 \"unauthorized\""))))

  (test-equal "teeth: a table that lets a key regenerate a live sibling disagrees with the handlers' 403"
    #t
    (let ((f (first-difference regenerates-siblings (from-to 1 50))))
      (and f
           (contains? f "active x regenerate-other")
           (contains? f "status: the table says 200, the handlers answered 403")))))

(unless (raised? store) (close-test-store! store))

(display (format "keys-model: ~a ms\n" (- (real-time) started)))

(test-end "keys-model")

(exit (suite-exit-status runner))
