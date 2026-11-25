#!r6rs
;;; The login model suite: ADR-0007's third layer for slice 3b's login table
;;; (Q11). Seeded random sequences of logins, malformed bodies, passing time,
;;; password resets (one timed inside an in-flight login's verify), key
;;; fills and key probes run against the real handlers (make-app with a
;;; login kit inside wrap-server, raw HTTP through a test host), real SQLite,
;;; the real limiter and address parsing, and fake hashing; each answer is
;;; compared with a model written from the plan. The machinery and the model
;;; are (login-model).
;;;
;;;   1. the model on hand-made inputs, pure
;;;   2. the run: SEQUENCES seeds, every one to agree
;;;   3. coverage: every row of login's table stepped, every ending, every
;;;      hasher mood, and each limiter case
;;;   4. teeth: the model given a changed ending disagrees with the handlers
;;;
;;; Replay one seed, each event printed as it goes:
;;;   scripts/guix-env sh -c 'TECHO_LOGIN_MODEL_SEED=17 make test SUITES=tests/test-login-model.sps'
;;; Then only that seed runs, and only its agreement is asserted.
;;;
;;; Its files are under build/test-login-model/<unique>/, emptied at the
;;; start. Everything that can raise is computed under `attempt`, and a
;;; raise comes out as a value the expectation never is.
(import (rnrs)
        (only (chezscheme) getenv format)
        (srfi :64)
        (techo-testing)
        (only (http-support) fresh-dir open-test-store close-test-store! contains?)
        (only (techo limiter) make-limiter limiter-size)
        (only (techo login) login-rows)
        (login-model))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define (from-to a b) (if (> a b) '() (cons a (from-to (+ a 1) b))))
(define (take* xs n) (if (or (null? xs) (= n 0)) '() (cons (car xs) (take* (cdr xs) (- n 1)))))

(test-begin "login-model")

;;; 1. The model, on hand-made inputs

(define L plan-limits)

;; tries : Limits Lim (Listof (List Email Address Now)) -> (values (Listof Symbol-or-Seconds) Lim)
;; Each try in turn: allowed, or (limited seconds), or (full 60).
(define (tries L m ts)
  (let loop ((m m) (ts ts) (acc '()))
    (if (null? ts)
        (values (reverse acc) m)
        (let ((out (apply lim-try L m (car ts))))
          (loop (caddr out) (cdr ts)
                (cons (if (eq? (car out) 'allowed) 'allowed (list (car out) (cadr out))) acc))))))

(define (tries-out L m ts) (let-values (((outs m) (tries L m ts))) outs))
(define (tries-lim L m ts) (let-values (((outs m) (tries L m ts))) m))

(define (same-n n x) (map (lambda (i) x) (from-to 1 n)))

(test-equal "limiter: five tries for an email in a window, then the sixth refused for the seconds left, rounded up"
  (append (same-n 5 'allowed) '((limited 900) (limited 600)))
  (attempt (lambda ()
             (tries-out L lim-empty
                        (append (map (lambda (t) (list "e" 'a1 t)) '(0 1 2 3 4))
                                '(("e" a1 10) ("e" a1 300000)))))))

(test-equal "limiter: twenty an address across emails; the 21st refused, though its email is new"
  (append (same-n 20 'allowed) '((limited 900)))
  (attempt (lambda ()
             (tries-out L lim-empty
                        (map (lambda (i) (list (number->string (div i 5)) 'a1 i)) (from-to 0 20))))))

(test-equal "limiter: a refused try counts on neither key: the other address gets no window"
  '(3 (limited 900) 3)
  (attempt (lambda ()
             (let* ((m (tries-lim L lim-empty (map (lambda (t) (list "e" (if (< t 4) 'a1 'a2) t)) '(0 1 2 3 4)))))
               (list (lim-size m) (car (tries-out L m '(("e" a3 5)))) (lim-size (tries-lim L m '(("e" a3 5)))))))))

(test-equal "limiter: when both refuse, Retry-After is the larger"
  '(limited 800)
  (attempt (lambda ()
             (let ((m (tries-lim L lim-empty
                                 (append (map (lambda (i) (list (string-append "x" (number->string (div i 5))) 'a1 i))
                                              (from-to 0 19))
                                         (map (lambda (i) (list "e" 'a2 (+ 100000 i))) (from-to 0 4))))))
               ;; at 200 s: a1's window has 700 s left, e's 800 s
               (car (tries-out L m '(("e" a1 200000))))))))

(test-equal "limiter: the window's last ms still refuses, 1 s; at its end a new one opens"
  '((limited 1) allowed 2)
  (attempt (lambda ()
             (let ((m (tries-lim L lim-empty (map (lambda (t) (list "e" 'a1 t)) '(0 0 0 0 0)))))
               (list (car (tries-out L m '(("e" a1 899999))))
                     (car (tries-out L m '(("e" a1 900000))))
                     (lim-size (tries-lim L m '(("e" a1 900000)))))))))

(define (forgive-tags m t) (let-values (((m2 tags) (lim-forgive m t))) tags))
(define (forgive-lim m t) (let-values (((m2 tags) (lim-forgive m t))) m2))

(test-equal "limiter: forgive gives one back in the window counted; a window at zero is gone"
  '((forgive forgive) 0 allowed)
  (attempt (lambda ()
             (let* ((out (lim-try L lim-empty "e" 'a1 0))
                    (m (forgive-lim (caddr out) (cadr out))))
               (list (forgive-tags (caddr out) (cadr out)) (lim-size m)
                     (car (tries-out L m '(("e" a1 1)))))))))

(test-equal "limiter: a forgive after a clear and a new try leaves the new email window alone; the address's is forgiven"
  '((forgive-reopened forgive) 2 1)
  (attempt (lambda ()
             (let* ((out (lim-try L lim-empty "e" 'a1 0))
                    (try (cadr out))
                    (m1 (let-values (((m tags) (lim-clear (caddr out) "e"))) m))
                    (m2 (caddr (lim-try L m1 "e" 'a2 5))))
               (list (forgive-tags m2 try) (lim-size (forgive-lim m2 try))
                     ;; e's new window keeps its one try: four more, then refused
                     (length (filter pair? (tries-out L (forgive-lim m2 try)
                                                      (map (lambda (t) (list "e" 'a2 t)) '(6 7 8 9 10))))))))))

(test-equal "limiter: no room is full, 60, counting nothing; once the windows expire they are swept"
  '((full 60) 2 allowed 2)
  (attempt (lambda ()
             (let* ((L2 (make-limits 5 20 900000 2))
                    (m (tries-lim L2 lim-empty '(("e1" a1 0)))))
               (list (car (tries-out L2 m '(("e2" a1 1))))
                     (lim-size (tries-lim L2 m '(("e2" a1 1))))
                     (car (tries-out L2 m '(("e2" a1 900000))))
                     (lim-size (tries-lim L2 m '(("e2" a1 900000)))))))))

;; answer : World Event -> (List Status Code Retry Calls Path)
(define (answer w e)
  (let ((x (expect plan-endings L w e)))
    (list (expectation-status x) (expectation-code x) (expectation-retry x) (expectation-calls x)
          (expectation-path x))))

(define (lim-size* x) (lim-size (world-lim (expectation-world x))))

(define (pw-a g) (string-append "alice-secret-" (number->string g)))

(test-equal "oracle: alice's right password is a 201: one read, verify, rehash check and write"
  '(201 #f #f (1 1 1 0 0 1) ((limiting allowed) (reading found) (verifying matched) (writing made)))
  (attempt (lambda () (answer world-start (try-event 1 1 'a (pw-a 0) 'v4a 'normal)))))

(test-equal "oracle: an unknown email and a wrong password do the same work, a 401 each (Q1)"
  '((401 "invalid_credentials" #f (1 1 0 1 0 0)) (401 "invalid_credentials" #f (1 1 0 1 0 0)))
  (attempt (lambda ()
             (map (lambda (e) (take* (answer world-start e) 4))
                  (list (try-event 1 1 #f (pw-a 0) 'v4a 'normal)
                        (try-event 2 1 'a "wrong" 'v4a 'normal))))))

(test-equal "oracle: c's password sent in NFD is the right one; with the fi ligature it is not"
  '(201 401)
  (attempt (lambda ()
             (list (car (answer world-start (try-event 1 1 'c "caf\xe9;-fi-0" 'v4a 'normal)))
                   (car (answer world-start (try-event 2 1 'c "caf\xe9;-\xfb01;-0" 'v4a 'normal)))))))

(test-equal "oracle: a busy verify and a failed doubt are 503s with 5, forgiven; a busy doubt a 401, kept"
  '((503 "5" 0) (503 "5" 0) (401 #f 2))
  (attempt (lambda ()
             (map (lambda (mood)
                    (let ((x (expect plan-endings L world-start (try-event 1 1 'a "wrong" 'v4a mood))))
                      (list (expectation-status x) (expectation-retry x) (lim-size* x))))
                  '(verify-busy doubt-failed doubt-busy)))))

(test-equal "oracle: the sixth wrong try is a 429 with 900, and reads and hashes nothing (Q2)"
  '(429 "rate_limited" "900" (0 0 0 0 0 0) ((limiting limited)))
  (attempt (lambda ()
             (let loop ((w world-start) (i 1))
               (let ((e (try-event i i 'a "wrong" 'v4a 'normal)))
                 (if (= i 6)
                     (answer w e)
                     (loop (expectation-world (expect plan-endings L w e)) (+ i 1))))))))

(test-equal "oracle: a rehash wanted and made goes through rehashing; failed or busy still writes"
  '(((verifying matched-outdated) (rehashing rehashed) (writing made))
    ((verifying matched-outdated) (rehashing failed) (writing made))
    ((verifying matched-outdated) (rehashing busy) (writing made)))
  (attempt (lambda ()
             (map (lambda (mood)
                    (list-tail (list-ref (answer world-start (try-event 1 1 'b "bob secret 0" 'v4a mood)) 4) 2))
                  '(rehash-ok rehash-failed rehash-busy)))))

;;; The store every sequence runs on, emptied by each

(define dir (attempt (lambda () (fresh-dir "test-login-model"))))
(define store (attempt (lambda () (open-test-store dir "model.db"))))

;; run-one : Rules Natural Boolean -> (U Verdict (List 'raised String))
(define (run-one rules seed trace?)
  (attempt (lambda () (run-sequence store rules make-limiter limiter-size seed trace?))))

(define (raised? x) (and (pair? x) (eq? (car x) 'raised)))

;; failure : (U Verdict (List 'raised String)) -> (U String #f)
(define (failure v)
  (cond ((raised? v) (string-append "a sequence raised: " (cadr v)))
        ((verdict-report v) => (lambda (r) r))
        (else #f)))

(define replay-seed
  (let ((s (getenv "TECHO_LOGIN_MODEL_SEED")))
    (and s (string->number s))))

;;; Replay: one seed, traced

(define replayed (and replay-seed (failure (run-one plan-endings replay-seed #t))))

(when replay-seed
  (when replayed (display replayed))
  (test-equal (format "replay of seed ~a: every event agrees" replay-seed) #f replayed))

;;; 2. The run

(define sequences 300)
(define verdicts (if replay-seed '() (map (lambda (s) (run-one plan-endings s #f)) (from-to 1 sequences))))
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
(define tags-hit (tally verdict-tags))
(define events (apply + (map verdict-events agreed)))
(define requests (apply + (map verdict-requests agreed)))

(define (at-least floor n) (if (>= n floor) (list 'at-least floor) (list 'only n)))

;; What must have happened, and how often, across the run.
(define row-floor 40)
(define tag-floors
  '((mood:normal . 100) (mood:verify-busy . 100) (mood:doubt-failed . 100) (mood:doubt-busy . 100)
    (mood:rehash-ok . 100) (mood:rehash-failed . 100) (mood:rehash-busy . 100)
    (mood:stand-in-matches . 100)
    (email-limited . 100) (address-limited . 40) (both-limited . 10)
    (forgive . 100) (forgive-reopened . 15) (forgive-gone . 15)
    (clear . 100) (expiry . 100) (full . 40) (first-full . 20) (sweep . 20)
    (park . 100) (resume . 100) (reset . 100) (reset-in-flight . 40) (reset-same . 30)
    (fill:100 . 15) (fill:99 . 10) (probe-live . 40) (probe-dead . 40)
    (nfd . 40) (ligature . 20) (previous . 40) (long-nfd . 20) (max-length . 10)
    (empty-password . 10) (padded . 15) (respelled . 100)
    (forged . 100) (two-fields . 40) (messy . 40) (no-header . 40)
    (v4-mapped . 40) (v4-mapped-hex . 40) (v4-port . 40) (v6-same-64 . 40) (v6-bracket-port . 40)
    (not-an-address . 40)
    (wait:seconds . 100) (wait:minutes . 100) (wait:past-window . 50) (wait:to-end . 15)
    (wait:to-last-ms . 15)
    (malformed:no-type . 5) (malformed:text-plain . 5) (malformed:bad-json . 5) (malformed:twice . 5)
    (malformed:unknown-field . 5) (malformed:missing-field . 5) (malformed:not-a-string . 5)
    (malformed:empty-name . 5) (malformed:long-name . 5) (malformed:long-password . 5)
    (malformed:bad-email . 5) (malformed:over-cap . 5) (malformed:empty-body . 5) (malformed:array . 5)))

(unless replay-seed
  (test-equal "the run: every sequence agrees with the model (the first three that do not)"
    '()
    (take* failures 3))

  (test-equal "the run: every one of the sequences ran and agreed" sequences (length agreed))

  (test-equal "the run: at least 10,000 events" '(at-least 10000) (at-least 10000 events))

  ;;; 3. Coverage

  (for-each
   (lambda (row)
     (test-equal (format "coverage: ~a x ~a is stepped at least ~a times" (car row) (cadr row) row-floor)
       (list 'at-least row-floor)
       (at-least row-floor (hashtable-ref rows-hit (list (car row) (cadr row)) 0))))
   login-rows)

  (test-equal "coverage: the model steps no pair the table does not have"
    '()
    (filter (lambda (k) (not (exists (lambda (row) (equal? k (list (car row) (cadr row)))) login-rows)))
            (vector->list (hashtable-keys rows-hit))))

  (for-each
   (lambda (t)
     (test-equal (format "coverage: ~a at least ~a times" (car t) (cdr t))
       (list 'at-least (cdr t))
       (at-least (cdr t) (hashtable-ref tags-hit (car t) 0))))
   tag-floors)

  (display (format "login-model: ~a sequences, ~a events, ~a requests\n" (length agreed) events requests))
  (for-each (lambda (row)
              (display (format "  ~a x ~a: ~a\n" (car row) (cadr row)
                               (hashtable-ref rows-hit (list (car row) (cadr row)) 0))))
            login-rows)
  (for-each (lambda (t) (display (format "  ~a: ~a\n" (car t) (hashtable-ref tags-hit (car t) 0))))
            tag-floors))

;;; 4. Teeth: the model with a changed ending, the handlers as they are

;; first-difference : Rules (Listof Natural) -> (U String #f)
(define (first-difference rules seeds)
  (let loop ((ss seeds))
    (if (null? ss)
        #f
        (or (failure (run-one rules (car ss) #f)) (loop (cdr ss))))))

(unless replay-seed
  (test-equal "teeth: a model whose busy doubt forgives disagrees with the handlers"
    #t
    (let ((f (first-difference (ending-with plan-endings 'doubt-busy '(401 "invalid_credentials" forgive #f))
                               (from-to 1 40))))
      (and f (contains? f "doubting x busy") #t)))

  (test-equal "teeth: a model whose 409 keeps the count disagrees with the handlers"
    #t
    (let ((f (first-difference (ending-with plan-endings 'key-cap '(409 "too_many_keys" keep #f))
                               (from-to 1 60))))
      (and f (contains? f "replay: TECHO_LOGIN_MODEL_SEED=") #t))))

(unless (raised? store) (close-test-store! store))

(test-end "login-model")

(exit (suite-exit-status runner))
