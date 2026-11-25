#!r6rs
;;; (login-model): the model-based test of POST /v1/login, ADR-0007's third
;;; layer for slice 3b's login table (its Q11), for tests/test-login-model.sps.
;;; Test-only: it lives in tests/, which make test puts on Chez's library path.
;;;
;;; The model (pure)
;;; ----------------
;;; Written from the plan's words (L1, L2, L3, L4), not from the code: this
;;; library imports neither (techo login) nor (techo limiter). The suite hands
;;; it the real make-limiter and limiter-size.
;;;
;;; A world is three fixed accounts (a, b, and c, whose password holds an
;;; e-acute), each with its password's generation, the one before the last
;;; reset, the stored hash's text, and its active and total keys; the secrets
;;; logins have issued, live or revoked; the limiter (a window per email and
;;; per address group: an identity, a start and a count); at most one login
;;; in flight, parked inside its verify; and the time.
;;;
;;; The limiter is L3 as written: 5 tries an email and 20 an address in 15
;;; minutes (a sequence may lower the most windows, and gives the real one
;;; the same numbers); the address checked first; both counts or neither; the
;;; larger Retry-After; a full table swept of expired windows, then 429 with
;;; 60; forgive takes one back only from the window the try was counted in;
;;; clear drops the email's window. Where the plan is silent the model says
;;; so where it chooses (a window forgiven to zero is gone, as if never
;;; opened).
;;;
;;; The hasher is the test's fakes, whose answers the model knows by their
;;; definition: a stored hash is the text "<origin>$<password>", verify
;;; matches when the password after NFC is that one; a "mood" per try makes
;;; verify busy, the doubt failed or busy, the rehash wanted and then made,
;;; failed or busy, or the stand-in match.
;;;
;;; The run (the shell)
;;; -------------------
;;; `run-sequence` resets one migrated file, generates a seeded sequence of
;;; events (xorshift32), and runs each through make-app with a login kit
;;; inside wrap-server, raw HTTP through ONE test host for the sequence, so
;;; that a login parked in its verify can wait while other events run. After
;;; every event it compares the model's prediction with what the stack did:
;;; the status, the code, Retry-After, the fakes' calls, a new key's body and
;;; that its secret works for its account, every account's stored hash and
;;; key counts, and the real limiter's number of windows. The first event
;;; that differs ends the sequence with a report replayable from its seed.
(library (login-model)
  (export make-limits plan-limits limits-max
          lim-empty lim-try lim-forgive lim-clear lim-size
          plan-endings ending-with
          world-start world-lim expect expectation-status expectation-code expectation-retry
          expectation-calls expectation-path expectation-world expectation-tags
          try-event
          run-sequence verdict-seed verdict-events verdict-requests verdict-rows
          verdict-tags verdict-report)
  (import (rnrs)
          (only (chezscheme) format)
          (only (circuit http-server) circuit->handler await)
          (http-server testing)
          (only (jsonparse easy) string->json json->string)
          (techo-testing)
          (only (http-support) request-bytes byte-sequence run-write run-read store-reader store-writer)
          (only (techo store) insert-account! insert-key! account-by-email account-id
                account-password-hash set-password-hash! revoke-all-keys!)
          (only (techo doorway) tx-query tx-execute!)
          (only (techo routes) make-login-kit)
          (only (techo app) make-app wrap-server))

  ;;; Helpers

  (define (from-to a b) (if (> a b) '() (cons a (from-to (+ a 1) b))))

  (define (repeat s n) (if (= n 0) "" (string-append s (repeat s (- n 1)))))

  (define (join strings sep)
    (if (null? strings)
        ""
        (fold-left (lambda (acc s) (string-append acc sep s)) (car strings) (cdr strings))))

  (define (sym . parts)
    (string->symbol
     (apply string-append (map (lambda (p) (if (symbol? p) (symbol->string p) p)) parts))))

  (define (aref al k) (let ((p (assoc k al))) (and p (cdr p))))
  (define (adel al k) (filter (lambda (p) (not (equal? (car p) k))) al))
  (define (aset al k v) (cons (cons k v) (adel al k)))

  (define hex-digits "0123456789abcdef")

  ;; hex-of : Bytevector Natural Natural -> String    lowercase, bytes FROM to TO
  (define (hex-of bv from to)
    (let loop ((i (- to 1)) (acc '()))
      (if (< i from)
          (list->string acc)
          (let ((b (bytevector-u8-ref bv i)))
            (loop (- i 1) (cons (string-ref hex-digits (div b 16))
                                (cons (string-ref hex-digits (mod b 16)) acc)))))))

  ;; uuid-text : Bytevector -> String     8-4-4-4-12, lowercase
  (define (uuid-text bv)
    (string-append (hex-of bv 0 4) "-" (hex-of bv 4 6) "-" (hex-of bv 6 8) "-"
                   (hex-of bv 8 10) "-" (hex-of bv 10 16)))

  ;; secret-shape? : Any -> Boolean    techo_ and 64 lowercase hex digits
  (define (secret-shape? s)
    (and (string? s) (= (string-length s) 70) (string=? (substring s 0 6) "techo_")
         (for-all (lambda (c) (and (memv c (string->list hex-digits)) #t))
                  (string->list (substring s 6 70)))))

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
  ;; rng-weighted! : Rng (Listof (Pair Natural A)) -> A
  (define (rng-weighted! rng options)
    (let loop ((r (rng-below! rng (apply + (map car options)))) (os options))
      (if (< r (caar os)) (cdar os) (loop (- r (caar os)) (cdr os)))))

  ;;; The model's limiter (L3), pure

  ;; Limits : email address window (ms) max (windows)
  ;; make-limits : Natural Natural Natural Natural -> Limits
  ;; limits-max : Limits -> Natural
  (define-record-type limits (fields email address window max))

  ;; plan-limits : Limits     D12: 5 an email, 20 an address, 15 minutes, 10,000 windows
  (define plan-limits (make-limits 5 20 900000 10000))

  ;; Win = (List Serial Start Count): a window's identity, when it opened, its tries
  (define (win-serial x) (car x))
  (define (win-start x) (cadr x))
  (define (win-count x) (caddr x))

  ;; Lim : emails addresses (each an alist, key -> Win) and the next serial
  (define-record-type lim (fields emails addresses next))

  ;; lim-empty : Lim
  (define lim-empty (make-lim '() '() 1))

  ;; lim-size : Lim -> Natural      windows held, expired ones too until swept
  (define (lim-size m) (+ (length (lim-emails m)) (length (lim-addresses m))))

  (define (live? L x now) (< now (+ (win-start x) (limits-window L))))

  ;; refused-for : Limits (U Win #f) Natural Natural -> (U Natural #f)
  ;; At the limit in a live window: the seconds left, rounded up.
  (define (refused-for L x limit now)
    (and x (live? L x now) (>= (win-count x) limit)
         (div (+ (- (+ (win-start x) (limits-window L)) now) 999) 1000)))

  (define (sweep L m now)
    (let ((keep (lambda (al) (filter (lambda (p) (live? L (cdr p) now)) al))))
      (make-lim (keep (lim-emails m)) (keep (lim-addresses m)) (lim-next m))))

  ;; bump : Limits Alist Key Natural Serial -> (values Alist Win Serial Tags)
  ;; One more try in the key's live window, or a new window opened now.
  (define (bump L al k now serial)
    (let ((x (aref al k)))
      (if (and x (live? L x now))
          (let ((y (list (win-serial x) (win-start x) (+ 1 (win-count x)))))
            (values (aset al k y) y serial '()))
          (let ((y (list serial now 1)))
            (values (aset al k y) y (+ serial 1) (if x '(expiry) '()))))))

  ;; lim-try : Limits Lim Key Key Natural -> (List Kind Value Lim Tags)
  ;;   (allowed Try Lim Tags)   Try = (List EmailKey Serial AddressKey Serial)
  ;;   (limited Seconds Lim Tags)
  ;;   (full 60 Lim Tags)
  (define (lim-try L m e a now)
    (let* ((ra (refused-for L (aref (lim-addresses m) a) (limits-address L) now))
           (re (refused-for L (aref (lim-emails m) e) (limits-email L) now)))
      (if (or ra re)
          (list 'limited (max (or ra 0) (or re 0)) m
                (list (cond ((and ra re) 'both-limited) (ra 'address-limited) (else 'email-limited))))
          (let* ((grow (lambda (m) (+ (if (aref (lim-emails m) e) 0 1)
                                      (if (aref (lim-addresses m) a) 0 1))))
                 (over? (lambda (m) (> (+ (lim-size m) (grow m)) (limits-max L))))
                 (m1 (if (over? m) (sweep L m now) m))
                 (tags (if (< (lim-size m1) (lim-size m)) '(sweep) '())))
            (if (over? m1)
                (list 'full 60 m1 (cons 'full tags))
                (let*-values (((es ew n1 t1) (bump L (lim-emails m1) e now (lim-next m1)))
                              ((as aw n2 t2) (bump L (lim-addresses m1) a now n1)))
                  (list 'allowed (list e (win-serial ew) a (win-serial aw))
                        (make-lim es as n2) (append tags t1 t2))))))))

  ;; forgive-in : Alist Key Serial -> (values Alist Symbol)
  (define (forgive-in al k serial)
    (let ((x (aref al k)))
      (cond ((not x) (values al 'forgive-gone))
            ((not (= (win-serial x) serial)) (values al 'forgive-reopened))
            ;; The plan is silent on a window forgiven to zero; the model
            ;; reads it as a window that never opened.
            ((<= (win-count x) 1) (values (adel al k) 'forgive))
            (else (values (aset al k (list (win-serial x) (win-start x) (- (win-count x) 1)))
                          'forgive)))))

  ;; lim-forgive : Lim Try -> (values Lim Tags)
  ;; One back from each count, only in the window the try was counted in.
  (define (lim-forgive m t)
    (let*-values (((es te) (forgive-in (lim-emails m) (car t) (cadr t)))
                  ((as ta) (forgive-in (lim-addresses m) (caddr t) (cadddr t))))
      (values (make-lim es as (lim-next m)) (list te ta))))

  ;; lim-clear : Lim Key -> (values Lim Tags)
  (define (lim-clear m e)
    (values (make-lim (adel (lim-emails m) e) (lim-addresses m) (lim-next m))
            (if (aref (lim-emails m) e) '(clear) '(clear-nothing))))

  ;;; The accounts

  ;; MAcct, fixed: tag id username email (normalised)
  (define-record-type macct (fields tag id username email))

  (define model-accounts
    (list (make-macct 'a (make-bytevector 16 #xA1) "alice" "alice@example.com")
          (make-macct 'b (make-bytevector 16 #xB2) "bob" "bob@example.net")
          (make-macct 'c (make-bytevector 16 #xC3) "chloe" "chloe@example.org")))

  (define (macct-of tag) (find (lambda (m) (eq? (macct-tag m) tag)) model-accounts))

  ;; password-of : Tag Natural -> String     generation G's password, in NFC
  (define (password-of tag g)
    (case tag
      ((a) (string-append "alice-secret-" (number->string g)))
      ((b) (string-append "bob secret " (number->string g)))
      (else (string-append "caf\xe9;-fi-" (number->string g)))))

  ;; c's password in NFD: e and a combining acute, which NFC makes one character
  (define (nfd-of g) (string-append "cafe\x301;-fi-" (number->string g)))
  ;; c's password with the fi ligature, which NFC keeps (only NFKC folds it)
  (define (ligature-of g) (string-append "caf\xe9;-\xfb01;-" (number->string g)))

  ;; hash-text : String Natural String -> String     the fakes' stored hash
  (define (hash-text origin label pw)
    (string-append origin (if label (number->string label) "") "$" pw))

  ;; Acct: tag gen prev hash active total
  (define-record-type acct (fields tag gen prev hash active total))

  ;;; The world

  ;; Flight: a login parked in its verify, and what it learnt before
  (define-record-type flight (fields label tag ekey try stored pw mood name verdict))

  ;; World: now accts lim secrets (Listof (List String Tag Boolean)) flight fulls
  ;; world-lim : World -> Lim
  (define-record-type world (fields now accts lim secrets flight fulls))

  ;; world-start : World     the three accounts as seeded, no window, no key
  (define world-start
    (make-world 0
                (map (lambda (m) (make-acct (macct-tag m) 0 #f (hash-text "seed" #f (password-of (macct-tag m) 0)) 0 0))
                     model-accounts)
                lim-empty '() #f 0))

  (define (world-acct w tag) (find (lambda (a) (eq? (acct-tag a) tag)) (world-accts w)))
  (define (with-now w now)
    (make-world now (world-accts w) (world-lim w) (world-secrets w) (world-flight w) (world-fulls w)))
  (define (with-lim w m)
    (make-world (world-now w) (world-accts w) m (world-secrets w) (world-flight w) (world-fulls w)))
  (define (with-flight w f)
    (make-world (world-now w) (world-accts w) (world-lim w) (world-secrets w) f (world-fulls w)))
  (define (with-acct w a)
    (make-world (world-now w)
                (map (lambda (x) (if (eq? (acct-tag x) (acct-tag a)) a x)) (world-accts w))
                (world-lim w) (world-secrets w) (world-flight w) (world-fulls w)))
  (define (with-secrets w s)
    (make-world (world-now w) (world-accts w) (world-lim w) s (world-flight w) (world-fulls w)))
  (define (with-full w)
    (make-world (world-now w) (world-accts w) (world-lim w) (world-secrets w) (world-flight w)
                (+ 1 (world-fulls w))))

  ;;; Events

  ;; Event: kind label at args desc
  ;;   try, park   a login; park stops it inside its verify
  ;;   resume      the parked login's verify answers
  ;;   malformed   a body refused before the count
  ;;   wait        time passes
  ;;   reset       techo user password, through the store
  ;;   fill        an account's active keys made up to N, through the store
  ;;   probe       GET /v1/account with a secret a login issued
  (define-record-type ev (fields kind label at args desc))

  (define (arg e k) (let ((p (assq k (ev-args e)))) (and p (cdr p))))

  ;; try-event : Natural Natural Tag-or-#f String String Symbol Symbol -> Event
  ;; For the suite's hand checks: a login at AT for TAG's email (or an
  ;; unknown one), PW sent and in NFC, from address group AKEY, in MOOD.
  (define (try-event label at tag pw akey mood)
    (let ((email (if tag (macct-email (macct-of tag)) "nobody@example.com")))
      (make-ev 'try label at
               (list (cons 'email email) (cons 'ekey email) (cons 'tag tag) (cons 'password pw)
                     (cons 'pw pw) (cons 'name "laptop") (cons 'xff '()) (cons 'akey akey)
                     (cons 'mood mood) (cons 'park? #f) (cons 'aims '()))
               "a hand-made try")))

  ;;; The endings (L1, L2), as the plan words them

  ;; Rule = (List Status Code Count Retry): Count keep forgive clear; Retry
  ;; seconds, #f, or event (the limiter's seconds)
  ;; plan-endings : (Listof (Pair Symbol Rule))
  (define plan-endings
    '((limited 429 "rate_limited" keep event)
      (full 429 "rate_limited" keep 60)
      (verify-busy 503 "unavailable" forgive 5)
      (wrong 401 "invalid_credentials" keep #f)
      (doubt-failed 503 "unavailable" forgive 5)
      (doubt-busy 401 "invalid_credentials" keep #f)
      (made 201 #f clear #f)
      (stale 401 "invalid_credentials" keep #f)
      (key-cap 409 "too_many_keys" clear #f)))

  ;; ending-with : (Listof (Pair Symbol Rule)) Symbol Rule -> (Listof (Pair Symbol Rule))
  ;; The endings with KEY's rule replaced: a changed model, for the teeth.
  (define (ending-with rules key rule)
    (map (lambda (p) (if (eq? (car p) key) (cons key rule) p)) rules))

  ;;; The oracle

  ;; Calls = (List read verify needs-rehash doubt hash write)
  (define no-calls '(0 0 0 0 0 0))
  (define parked-calls '(1 1 0 0 0 0))

  ;; Expectation: status code retry calls path made world tags extra
  ;;   status  Natural; 'parked for a login stopped in its verify; #f for no request
  ;;   retry   Retry-After's text, or #f for none
  ;;   calls   the fakes' and runners' calls this event makes (#f: not compared)
  ;;   path    the (state event) pairs the plan's table steps, by the code's
  ;;           row names (for the coverage count only)
  ;;   made    for a 201: (List Tag Name Created)
  ;;   tags    what happened, for the coverage count
  ;;   extra   for a probe: ((account . Tag)), whose key the secret was
  ;; expectation-status : Expectation -> (U Natural 'parked #f)
  ;; expectation-code expectation-retry : Expectation -> (U String #f)
  ;; expectation-calls : Expectation -> (U (Listof Natural) #f)
  ;; expectation-path : Expectation -> (Listof (List Symbol Symbol))
  ;; expectation-world : Expectation -> World
  ;; expectation-tags : Expectation -> (Listof Symbol)
  (define-record-type expectation (fields status code retry calls path made world tags extra))

  (define (quiet w tags) (make-expectation #f #f #f #f '() #f w tags '()))

  ;; end : Rules World Path Symbol (U Natural #f) Calls Tags Made (U Flight #f) -> Expectation
  (define (end R w path key seconds calls tags made f)
    (let* ((rule (cdr (assq key R)))
           (retry (if (eq? (cadddr rule) 'event) seconds (cadddr rule))))
      (let-values (((m ctags)
                    (cond ((not f) (values (world-lim w) '()))
                          ((eq? (caddr rule) 'forgive) (lim-forgive (world-lim w) (flight-try f)))
                          ((eq? (caddr rule) 'clear) (lim-clear (world-lim w) (flight-ekey f)))
                          (else (values (world-lim w) '())))))
        (make-expectation (car rule) (cadr rule) (and retry (number->string retry)) calls path made
                          (with-lim w m) (append tags ctags) '()))))

  ;; expect : Rules Limits World Event -> Expectation
  (define (expect R L w e)
    (let ((w (with-now w (ev-at e))))
      (case (ev-kind e)
        ((try park) (expect-try R L w e))
        ((resume) (expect-resume R w e))
        ((malformed)
         (make-expectation (arg e 'status) (arg e 'code) #f no-calls '() #f w
                           (list (sym "malformed:" (arg e 'case))) '()))
        ((wait) (quiet w (list (sym "wait:" (arg e 'kind)))))
        ((reset) (expect-reset w e))
        ((fill)
         (let ((a (world-acct w (arg e 'tag))))
           (quiet (with-acct w (make-acct (acct-tag a) (acct-gen a) (acct-prev a) (acct-hash a)
                                          (+ (acct-active a) (arg e 'n)) (+ (acct-total a) (arg e 'n))))
                  (list (sym "fill:" (number->string (+ (acct-active a) (arg e 'n))))))))
        ((probe)
         (let ((s (assoc (arg e 'secret) (world-secrets w))))
           (make-expectation (if (caddr s) 200 401) (if (caddr s) #f "unauthorized") #f #f '()
                             #f w (list (if (caddr s) 'probe-live 'probe-dead))
                             (list (cons 'account (cadr s))))))
        (else (assertion-violation 'expect "no such event" (ev-kind e))))))

  (define (expect-try R L w e)
    (let* ((out (lim-try L (world-lim w) (arg e 'ekey) (arg e 'akey) (ev-at e)))
           (w1 (with-lim w (caddr out)))
           (tags (cadddr out)))
      (case (car out)
        ((limited) (end R w1 '((limiting limited)) 'limited (cadr out) no-calls tags #f #f))
        ((full) (end R (with-full w1) '((limiting full)) 'full #f no-calls
                     (if (= 0 (world-fulls w)) (cons 'first-full tags) tags) #f #f))
        (else
         (let* ((tag (arg e 'tag))
                (a (and tag (world-acct w1 tag)))
                (mood (arg e 'mood))
                (verdict (cond ((eq? mood 'verify-busy) 'busy)
                               ((not a) (if (eq? mood 'stand-in-matches) 'matched 'unmatched))
                               ((string=? (arg e 'pw) (password-of tag (acct-gen a))) 'matched)
                               (else 'unmatched)))
                (f (make-flight (ev-label e) tag (arg e 'ekey) (cadr out) (and a (acct-hash a))
                                (arg e 'pw) mood (arg e 'name) verdict))
                (path (list '(limiting allowed) (if a '(reading found) '(reading missing))))
                (tags (append tags (list (sym "mood:" mood)) (arg e 'aims))))
           (if (eq? (ev-kind e) 'park)
               (make-expectation 'parked #f #f parked-calls path #f (with-flight w1 f) (cons 'park tags) '())
               (finish R w1 f path tags)))))))

  (define (expect-resume R w e)
    (let* ((f (world-flight w))
           (x (finish R (with-flight w #f) f '() '(resume))))
      (make-expectation (expectation-status x) (expectation-code x) (expectation-retry x)
                        (map - (expectation-calls x) parked-calls)
                        (expectation-path x) (expectation-made x) (expectation-world x)
                        (expectation-tags x) '())))

  ;; finish : Rules World Flight Path Tags -> Expectation
  ;; From the verify's answer on: L1's steps 3 to 6.
  (define (finish R w f path0 tags)
    (let ((mood (flight-mood f)))
      (case (flight-verdict f)
        ((busy) (end R w (append path0 '((verifying busy))) 'verify-busy #f '(1 1 0 0 0 0) tags #f f))
        ((matched)
         (if (flight-stored f)
             (let* ((outdated (and (memq mood '(rehash-ok rehash-failed rehash-busy)) #t))
                    (new-hash (and (eq? mood 'rehash-ok) (hash-text "rehash" (flight-label f) (flight-pw f))))
                    (path (append path0
                                  (if outdated '((verifying matched-outdated)) '((verifying matched)))
                                  (case mood
                                    ((rehash-ok) '((rehashing rehashed)))
                                    ((rehash-failed) '((rehashing failed)))
                                    ((rehash-busy) '((rehashing busy)))
                                    (else '()))))
                    (calls (list 1 1 1 0 (if outdated 1 0) 1))
                    (a (world-acct w (flight-tag f))))
               (cond
                ((not (string=? (acct-hash a) (flight-stored f)))
                 (end R w (append path '((writing stale))) 'stale #f calls tags #f f))
                ((>= (acct-active a) 100)
                 (end R w (append path '((writing full))) 'key-cap #f calls tags #f f))
                (else
                 (end R (with-acct w (make-acct (acct-tag a) (acct-gen a) (acct-prev a)
                                                (or new-hash (acct-hash a))
                                                (+ 1 (acct-active a)) (+ 1 (acct-total a))))
                      (append path '((writing made))) 'made #f calls tags
                      (list (flight-tag f) (flight-name f) (world-now w)) f))))
             (doubt R w (append path0 '((verifying matched-stand-in))) f tags)))
        (else (doubt R w (append path0 '((verifying unmatched))) f tags)))))

  (define (doubt R w path f tags)
    (let ((calls '(1 1 0 1 0 0)))
      (case (flight-mood f)
        ((doubt-failed) (end R w (append path '((doubting failed))) 'doubt-failed #f calls tags #f f))
        ((doubt-busy) (end R w (append path '((doubting busy))) 'doubt-busy #f calls tags #f f))
        (else (end R w (append path '((doubting hashed))) 'wrong #f calls tags #f f)))))

  (define (expect-reset w e)
    (let* ((tag (arg e 'tag))
           (a (world-acct w tag))
           (gen (if (arg e 'same?) (acct-gen a) (+ 1 (acct-gen a))))
           (prev (if (arg e 'same?) (acct-prev a) (acct-gen a)))
           (f (world-flight w)))
      (make-expectation
       #f #f #f #f '() #f
       (with-secrets (with-acct w (make-acct tag gen prev (hash-text "reset" (ev-label e) (password-of tag gen))
                                             0 (acct-total a)))
                     (map (lambda (s) (if (eq? (cadr s) tag) (list (car s) tag #f) s)) (world-secrets w)))
       (append (list 'reset (if (arg e 'same?) 'reset-same 'reset-new))
               (if (and f (eq? (flight-tag f) tag)) '(reset-in-flight) '()))
       '())))

  ;;; The generator

  (define unknown-emails '("nobody@example.com" "ghost@example.org" "eve@example.net"))

  (define key-names
    (list "laptop" "phone" "work machine" "T\xe9;l\xe9;phone" (make-string 64 #\k) "a"))

  ;; spell : Rng String -> String     the same email in random ASCII case, sometimes padded
  (define (spell rng s)
    (let loop ((cs (string->list s)) (acc '()))
      (if (null? cs)
          (let* ((r (rng-below! rng 10))
                 (t (list->string (reverse acc))))
            (cond ((= r 0) (string-append "  " t)) ((= r 1) (string-append t " ")) (else t)))
          (let* ((c (car cs))
                 (flip (and (char<=? #\a c #\z) (= 0 (rng-below! rng 3)))))
            (loop (cdr cs) (cons (if flip (char-upcase c) c) acc))))))

  ;; Spelling = (List (U String #f) Group): an address as a proxy writes it,
  ;; and its group by L3's rules, worked out by hand: every spelling of one
  ;; address, and every address of one /64, is one group.
  (define spellings
    '(("203.0.113.7" v4a) ("::ffff:203.0.113.7" v4a) ("::FFFF:CB00:7107" v4a) ("203.0.113.7:5555" v4a)
      ("2001:db8:1:2::1" v6n1) ("2001:DB8:1:2:abcd::5" v6n1) ("[2001:db8:1:2::9]:443" v6n1)
      ("2001:db8:1:3::1" v6n2)
      ("198.51.100.20" v4b)
      ("unknown" unknown) (#f unknown)))

  (define spelling-aims
    '(("::ffff:203.0.113.7" . v4-mapped) ("::FFFF:CB00:7107" . v4-mapped-hex)
      ("203.0.113.7:5555" . v4-port) ("2001:DB8:1:2:abcd::5" . v6-same-64)
      ("[2001:db8:1:2::9]:443" . v6-bracket-port) ("unknown" . not-an-address)))

  ;; gen-address : Rng Group -> (List (Listof String) Group Aims)
  ;; X-Forwarded-For's fields, one proxy: the client is the last entry.
  (define (gen-address rng hot)
    (let* ((pool (if (< (rng-below! rng 100) 65)
                     (filter (lambda (s) (eq? (cadr s) hot)) spellings)
                     spellings))
           (s (rng-pick! rng pool))
           (text (car s))
           (shape (rng-below! rng 20))
           (aim (let ((p (assoc text spelling-aims))) (if p (list (cdr p)) '()))))
      (cond ((not text) (list '() 'unknown '(no-header)))
            ((< shape 10) (list (list text) (cadr s) aim))
            ((< shape 15) (list (list (string-append "6.6.6.6, " text)) (cadr s) (cons 'forged aim)))
            ((< shape 18) (list (list "6.6.6.6" text) (cadr s) (cons 'two-fields aim)))
            (else (list (list (string-append " 6.6.6.6 ,, " text " , ")) (cadr s) (cons 'messy aim))))))

  ;; gen-password : Rng World (U Tag #f) Boolean -> (List Sent NFC Aims)
  (define (gen-password rng attack? w tag park?)
    (if (not tag)
        (if (< (rng-below! rng (if attack? 6 2)) 1)
            (let ((t (rng-pick! rng '(a b c)))) (list (password-of t 0) (password-of t 0) '()))
            (list "wrong-guess" "wrong-guess" '()))
        (let* ((a (world-acct w tag))
               (g (acct-gen a))
               (pw (password-of tag g))
               (c? (eq? tag 'c))
               (kind (rng-weighted!
                      rng
                      (append (list (cons (cond (park? 70) (attack? 6) (else 44)) 'right)
                                    (cons (if attack? 40 14) 'wrong) '(4 . padded) '(3 . empty)
                                    '(3 . short) '(3 . long-nfd) '(2 . max-length))
                              (if c? '((14 . nfd) (6 . ligature)) '())
                              (if (acct-prev a) '((8 . previous)) '())))))
          (case kind
            ((right) (list pw pw '()))
            ((nfd) (list (nfd-of g) pw '(nfd)))
            ((ligature) (let ((l (ligature-of g))) (list l l '(ligature))))
            ((previous) (let ((p (password-of tag (acct-prev a)))) (list p p '(previous))))
            ((padded) (let ((p (string-append pw " "))) (list p p '(padded))))
            ((empty) (list "" "" '(empty-password)))
            ((short) (list "abc" "abc" '(short-password)))
            ((long-nfd) (list (repeat "e\x301;" 400) (repeat "\xe9;" 400) '(long-nfd)))
            ((max-length) (let ((p (make-string 1024 #\x))) (list p p '(max-length))))
            (else (list "wrong-guess" "wrong-guess" '(wrong)))))))

  (define (gen-mood rng tag park?)
    (rng-weighted! rng
                   (append (list (cons (if park? 20 34) 'normal) (cons (if park? 22 8) 'verify-busy)
                                 (cons (if park? 16 9) 'doubt-failed) '(9 . doubt-busy) '(10 . rehash-ok)
                                 '(7 . rehash-failed) '(7 . rehash-busy))
                           (if tag '((3 . stand-in-matches)) '((30 . stand-in-matches))))))

  ;; gen-try : Rng Group Boolean World Natural Natural Boolean -> Event
  ;; A login; HOT is the sequence's favoured address group, ATTACK? makes
  ;; wrong passwords likelier; it follows a parked login's email half the time.
  (define (gen-try rng hot attack? w i at park?)
    (let* ((f (world-flight w))
           (follow? (and f (< (rng-below! rng 100) 50)))
           (tag (if follow? (flight-tag f) (and (< (rng-below! rng 100) 75) (rng-pick! rng '(a b c c)))))
           (base (cond (tag (macct-email (macct-of tag)))
                       (follow? (flight-ekey f))
                       (else (rng-pick! rng unknown-emails))))
           (email (spell rng base))
           (pwk (gen-password rng attack? w tag park?))
           (name (rng-pick! rng key-names))
           (addr (gen-address rng hot))
           (mood (gen-mood rng tag park?)))
      (make-ev (if park? 'park 'try) i at
               (list (cons 'email email) (cons 'ekey base) (cons 'tag tag) (cons 'password (car pwk))
                     (cons 'pw (cadr pwk)) (cons 'name name) (cons 'xff (car addr)) (cons 'akey (cadr addr))
                     (cons 'mood mood) (cons 'park? park?)
                     (cons 'aims (append (caddr pwk) (caddr addr)
                                         (if (string=? email base) '() '(respelled)))))
               (format "~a ~s ~a pw=~a name=~s xff=~s (~a) mood=~a"
                       (if park? "PARK login" "login") email (if tag (format "(~a)" tag) "(unknown)")
                       (password-label pwk) name (car addr) (cadr addr) mood))))

  (define (password-label pwk)
    (let ((aims (caddr pwk)))
      (if (null? aims)
          (if (> (string-length (car pwk)) 30) "long" (format "~s" (car pwk)))
          (format "~a" (car aims)))))

  ;; Case = (List Symbol (U String #f) String Status Code)
  (define (malformed-cases email pw)
    (let* ((q (lambda (s) (json->string s)))
           (body (lambda (members) (string-append "{" (join members ",") "}")))
           (e (string-append "\"email\":" (q email)))
           (p (string-append "\"password\":" (q pw)))
           (n "\"name\":\"n\"")
           (ok (body (list e p n))))
      (list
       (list 'no-type #f ok 415 "unsupported_media_type")
       (list 'text-plain "text/plain" ok 415 "unsupported_media_type")
       (list 'bad-json "application/json" (string-append "{" e ", nope") 400 "invalid_json")
       (list 'twice "application/json" (body (list e e p n)) 400 "invalid_request")
       (list 'unknown-field "application/json" (body (list e p n "\"x\":1")) 400 "invalid_request")
       (list 'missing-field "application/json" (body (list e p)) 400 "invalid_request")
       (list 'not-a-string "application/json" (body (list e "\"password\":12345" n)) 400 "invalid_request")
       (list 'empty-name "application/json" (body (list e p "\"name\":\"\"")) 400 "invalid_request")
       (list 'long-name "application/json" (body (list e p (string-append "\"name\":" (q (make-string 65 #\k)))))
             400 "invalid_request")
       (list 'long-password "application/json"
             (body (list e (string-append "\"password\":" (q (make-string 1025 #\x))) n)) 400 "invalid_request")
       (list 'bad-email "application/json" (body (list "\"email\":\"alice.example.com\"" p n)) 400 "invalid_request")
       (list 'over-cap "application/json"
             (body (list e (string-append "\"password\":" (q (make-string 16400 #\p))) n)) 413 "payload_too_large")
       (list 'empty-body "application/json" "" 400 "invalid_request")
       (list 'array "application/json" (string-append "[" ok "]") 400 "invalid_request"))))

  (define (gen-malformed rng hot w i at)
    (let* ((tag (rng-pick! rng '(a b c)))
           (email (spell rng (macct-email (macct-of tag))))
           (c (rng-pick! rng (malformed-cases email (password-of tag (acct-gen (world-acct w tag))))))
           (addr (gen-address rng hot)))
      (make-ev 'malformed i at
               (list (cons 'case (car c)) (cons 'type (cadr c)) (cons 'body (caddr c))
                     (cons 'status (cadddr c)) (cons 'code (list-ref c 4)) (cons 'xff (car addr)))
               (format "malformed ~a for ~a" (car c) tag))))

  (define (gen-wait rng w i at0)
    (let* ((r (rng-below! rng 100))
           (small (+ 1000 (rng-below! rng 9000)))
           (minutes (+ 60000 (rng-below! rng 240000)))
           (long (+ 900000 (rng-below! rng 300000)))
           (k (+ 1 (rng-below! rng 2)))
           (wins (filter (lambda (x) (> (- (+ (win-start x) 900000) at0 k) 0))
                         (map cdr (append (lim-emails (world-lim w)) (lim-addresses (world-lim w))))))
           (pick (and (pair? wins) (rng-pick! rng wins))))
      (let-values (((kind ms) (cond ((< r 40) (values 'seconds small))
                                    ((< r 62) (values 'minutes minutes))
                                    ((< r 77) (values 'past-window long))
                                    ((not pick) (values 'seconds small))
                                    ;; the next request's tick lands on the window's
                                    ;; end (k = 1) or its last ms (k = 2)
                                    (else (values (if (= k 1) 'to-end 'to-last-ms)
                                                  (- (+ (win-start pick) 900000) at0 k))))))
        (make-ev 'wait i (+ at0 ms) (list (cons 'kind kind)) (format "wait ~a ms (~a)" ms kind)))))

  (define (live-secrets w tag)
    (filter (lambda (s) (and (eq? (cadr s) tag) (caddr s))) (world-secrets w)))

  (define (gen-reset rng w i at tag)
    (let* ((same? (< (rng-below! rng 100) 30))
           (live (live-secrets w tag))
           (probe (if (pair? live) (list (car live)) '())))
      (make-ev 'reset i at (list (cons 'tag tag) (cons 'same? same?) (cons 'probe (map car probe)))
               (format "reset ~a's password (~a)~a" tag (if same? "the same one" "a new one")
                       (if (and (world-flight w) (eq? (flight-tag (world-flight w)) tag))
                           ", while its login is in flight" "")))))

  (define (gen-fill rng w i at)
    (let* ((open (filter (lambda (a) (< (acct-active a) 99)) (world-accts w)))
           (a (rng-pick! rng (if (pair? open) open (world-accts w))))
           (target (if (< (rng-below! rng 100) 70) 100 99))
           (n (max 0 (- target (acct-active a)))))
      (make-ev 'fill i at (list (cons 'tag (acct-tag a)) (cons 'n n))
               (format "fill ~a with ~a keys" (acct-tag a) n))))

  (define (gen-probe rng w i at)
    (let ((s (rng-pick! rng (world-secrets w))))
      (make-ev 'probe i at (list (cons 'secret (car s)))
               (format "GET /v1/account with ~a's ~a secret" (cadr s) (if (caddr s) "live" "revoked")))))

  (define (next-event rng hot attack? w i at0)
    (let* ((f (world-flight w))
           (kind (rng-weighted!
                  rng
                  (append (if f '((30 . resume)) '((9 . park)))
                          (list '(52 . try) '(6 . malformed) (cons (if attack? 3 13) 'wait) '(4 . reset)
                                '(2 . fill))
                          (if (and f (flight-tag f)) '((16 . reset-flight)) '())
                          (if (pair? (world-secrets w)) '((5 . probe)) '())))))
      (case kind
        ((try) (gen-try rng hot attack? w i (+ at0 1) #f))
        ((park) (gen-try rng hot attack? w i (+ at0 1) #t))
        ((resume) (make-ev 'resume i at0 '() (format "resume the parked login ~a" (flight-label f))))
        ((malformed) (gen-malformed rng hot w i (+ at0 1)))
        ((wait) (gen-wait rng w i at0))
        ((reset-flight) (gen-reset rng w i at0 (flight-tag f)))
        ((reset) (gen-reset rng w i at0 (rng-pick! rng '(a b c))))
        ((fill) (gen-fill rng w i at0))
        (else (gen-probe rng w i at0)))))

  ;;; The shell: what the client read

  (define (latin-1 bv) (list->string (map integer->char (bytevector->u8-list bv))))

  ;; Got: status headers json
  (define-record-type got (fields status headers json))

  (define (->got r)
    (let ((body (utf8->string (test-response-body r))))
      (make-got (test-response-status r)
                (map (lambda (h) (cons (string-downcase (latin-1 (car h))) (latin-1 (cdr h))))
                     (test-response-headers r))
                (if (= 0 (string-length body)) 'empty (guard (e (#t 'not-json)) (string->json body))))))

  (define (got-header g name) (let ((p (assoc name (got-headers g)))) (and p (cdr p))))
  (define (got-field g name) (let ((j (got-json g))) (and (list? j) (let ((p (assoc name j))) (and p (cdr p))))))

  (define (unset name) #f)

  ;; send! : Host Symbol String Headers (U String #f) -> Client
  (define (send! host method target headers body)
    (let ((c (test-host-connect! host)))
      (test-client-send! c (request-bytes method target headers body))
      c))

  (define (bearer-of s) (list (cons "Authorization" (string-append "Bearer " s))))

  ;; probe : Host String -> Got
  (define (probe host secret)
    (let ((rs (test-client-responses (send! host 'GET "/v1/account" (bearer-of secret) #f))))
      (if (= 1 (length rs)) (->got (car rs)) (make-got 'no-answer '() #f))))

  (define (same what want got)
    (if (equal? want got) '() (list (format "~a: the model has ~s, the stack ~s" what want got))))

  ;;; The database

  (define wall0 1795515226123)

  (define (seed-db! store)
    (run-write store
               (lambda (tx)
                 (tx-execute! tx "DELETE FROM api_keys")
                 (tx-execute! tx "DELETE FROM accounts")
                 (for-each (lambda (m)
                             (insert-account! tx (macct-id m) (macct-username m) (macct-email m)
                                              (hash-text "seed" #f (password-of (macct-tag m) 0)) 1000))
                           model-accounts))))

  ;; db-now : Store -> (Listof (List Bytevector String Natural Natural))
  ;; Each account, in id order: its id, stored hash, active and all keys.
  (define (db-now store)
    (run-read store
              (lambda (tx)
                (map (lambda (r) (vector->list r))
                     (tx-query tx (string-append
                                   "SELECT a.id, a.password_hash, "
                                   "(SELECT count(*) FROM api_keys k WHERE k.account = a.id AND k.revoked IS NULL), "
                                   "(SELECT count(*) FROM api_keys k WHERE k.account = a.id) "
                                   "FROM accounts a ORDER BY a.id"))))))

  (define (model-rows w)
    (map (lambda (m)
           (let ((a (world-acct w (macct-tag m))))
             (list (macct-id m) (acct-hash a) (acct-active a) (acct-total a))))
         model-accounts))

  (define (db-breaks w rows)
    (let loop ((ms model-accounts) (want (model-rows w)) (rows rows) (acc '()))
      (cond ((and (null? want) (null? rows)) (reverse acc))
            ((or (null? want) (null? rows)) (reverse (cons "the accounts table has other rows" acc)))
            (else
             (let ((t (macct-tag (car ms))) (x (car want)) (r (car rows)))
               (loop (cdr ms) (cdr want) (cdr rows)
                     (append (reverse
                              (append (same (format "~a's stored hash" t) (cadr x) (cadr r))
                                      (same (format "~a's active keys" t) (caddr x) (caddr r))
                                      (same (format "~a's keys in all" t) (cadddr x) (cadddr r))))
                             acc)))))))

  ;; filler-bytes : Natural Natural Natural -> Bytevector     N bytes: FIRST, K big-endian, then #x11
  (define (filler-bytes n first k)
    (let ((bv (make-bytevector n #x11)))
      (bytevector-u8-set! bv 0 first)
      (bytevector-u32-set! bv 1 k (endianness big))
      bv))

  ;;; One sequence

  ;; Verdict: seed events requests rows tags report
  ;;   rows, tags   (Listof (Pair Key Natural)): the table's (state event)
  ;;                pairs stepped and what happened, with counts
  ;;   report       #f when every event agreed; else the first difference
  ;; verdict-seed verdict-events verdict-requests : Verdict -> Natural
  ;; verdict-rows : Verdict -> (Listof (Pair (List Symbol Symbol) Natural))
  ;; verdict-tags : Verdict -> (Listof (Pair Symbol Natural))
  ;; verdict-report : Verdict -> (U String #f)
  (define-record-type verdict (fields seed events requests rows tags report))

  (define (hashtable->alist t)
    (let-values (((ks vs) (hashtable-entries t)))
      (map cons (vector->list ks) (vector->list vs))))

  (define (attempt thunk)
    (guard (c (#t (list 'raised (describe c))))
      (list 'ok (thunk))))

  ;; run-sequence : Store Rules (Natural Natural Natural Natural -> Limiter)
  ;;                (Limiter -> Natural) Natural Boolean -> Verdict
  ;; The sequence SEED makes, on STORE, emptied first: a fresh app with a
  ;; login kit (the fakes; MAKE-LIMITER's limiter with the sequence's
  ;; numbers; one proxy), one test host, then the generated events, then a
  ;; resume of a login still in flight. R is the model's endings
  ;; (plan-endings, or a changed copy). LIMITER-SIZE reads the real
  ;; limiter's windows. TRACE? prints each event as it goes.
  (define (run-sequence store R make-limiter limiter-size seed trace?)
    (let* ((rng (make-rng seed))
           (n (+ 20 (rng-below! rng 61)))
           (small? (< (rng-below! rng 100) 30))
           (maxw (if small? (+ 4 (rng-below! rng 6)) 10000))
           (hot (rng-pick! rng '(v4a v6n1 v6n2 v4b unknown v4a v6n1)))
           (attack? (< (rng-below! rng 100) 35))
           (L (make-limits 5 20 900000 maxw))
           (limiter (make-limiter 5 20 900000 maxw))
           (rows (make-hashtable equal-hash equal?))
           (tags (make-hashtable symbol-hash eq?))
           (requests 0)
           (log '())
           ;; the fakes' and the clocks' state
           (calls (make-vector 6 0))
           (mood 'normal)
           (label 0)
           (armed #f)
           (parked #f)
           (flight-client #f)
           (kit-lines 0)
           (now 0)
           (fillers 0))

      (define (bump! i) (vector-set! calls i (+ 1 (vector-ref calls i))))
      (define (calls-now) (vector->list calls))
      (define (count! t k by) (hashtable-update! t k (lambda (c) (+ c by)) 0))

      (define (stored-password h)
        (let loop ((i 0))
          (cond ((= i (string-length h)) "")
                ((char=? (string-ref h i) #\$) (substring h (+ i 1) (string-length h)))
                (else (loop (+ i 1))))))

      (define (verify stored pw)
        (bump! 1)
        (let ((v (cond ((eq? mood 'verify-busy) 'busy)
                       ((not stored) (if (eq? mood 'stand-in-matches) 'matched 'unmatched))
                       ((string=? (stored-password stored) pw) 'matched)
                       (else 'unmatched))))
          (if armed
              (begin (set! armed #f)
                     (await (lambda (resume) (set! parked (cons resume v)))))
              v)))
      (define (needs-rehash h) (bump! 2) (and (memq mood '(rehash-ok rehash-failed rehash-busy)) #t))
      (define (doubt) (bump! 3) (case mood ((doubt-failed) 'failed) ((doubt-busy) 'busy) (else 'hashed)))
      (define (hash pw)
        (bump! 4)
        (case mood ((rehash-failed) 'failed) ((rehash-busy) 'busy) (else (hash-text "rehash" label pw))))

      (define (reader job) (bump! 0) ((store-reader store) job))
      (define (writer job) (bump! 5) ((store-writer store) job))

      (define clock (lambda () now))
      (define wall (lambda () (+ wall0 now)))
      (define ids (let ((bs (byte-sequence))) (lambda () (bs 16))))
      (define kit (make-login-kit verify doubt hash needs-rehash limiter 1 ids
                                  (lambda (line) (set! kit-lines (+ kit-lines 1)))))
      (define h (wrap-server (make-app reader writer wall (byte-sequence) clock kit)
                             (lambda (line) #f) 10000 clock))
      (define host (make-test-host (circuit->handler h unset) unset))

      ;; login-headers : Event -> Headers
      (define (login-headers e type)
        (append (if type (list (cons "Content-Type" type)) '())
                (map (lambda (f) (cons "X-Forwarded-For" f)) (arg e 'xff))))

      (define (login-body e)
        (json->string (list (cons "email" (arg e 'email)) (cons "password" (arg e 'password))
                            (cons "name" (arg e 'name)))))

      ;; answer-breaks : Expectation Got (Listof Natural) Natural -> (values Breaks (U String #f))
      ;; The answer against the model, and a 201's secret.
      (define (answer-breaks w x g delta lines)
        (let* ((want (expectation-status x))
               (status (got-status g))
               (b (append
                   (same "the status" want status)
                   (if (and (eqv? want status) (expectation-code x))
                       (same "the code" (expectation-code x) (got-field g "code"))
                       '())
                   (if (eqv? want status) (same "retry-after" (expectation-retry x) (got-header g "retry-after")) '())
                   (if (and (eqv? want 401) (eqv? status 401))
                       (same "www-authenticate" "Bearer" (got-header g "www-authenticate"))
                       '())
                   (same "the calls (read verify needs-rehash doubt hash write)" (expectation-calls x) delta)
                   (let ((full? (member '(limiting full) (expectation-path x)))
                         (first? (memq 'first-full (expectation-tags x))))
                     (cond (first? (same "the limiter's full line" 1 lines))
                           (full? (if (<= lines 1) '() (list (format "~a full lines for one refusal" lines))))
                           (else (same "the limiter's full lines" 0 lines)))))))
          (if (and (eqv? want 201) (eqv? status 201))
              (made-breaks w x g b)
              (values b #f))))

      (define (made-breaks w x g b)
        (let* ((made (expectation-made x))
               (secret (got-field g "key"))
               (m (macct-of (car made)))
               (b (append b
                          (same "the key's name" (cadr made) (got-field g "name"))
                          (same "the key's created" (+ wall0 (caddr made)) (got-field g "created"))
                          (same "the key's last_used" 'null (got-field g "last_used"))
                          (same "the key's revoked" 'null (got-field g "revoked"))
                          (same "cache-control" "no-store" (got-header g "cache-control"))
                          (if (and (string? (got-field g "id")) (= 36 (string-length (got-field g "id"))))
                              '()
                              (list (format "the key's id is ~s" (got-field g "id"))))
                          (cond ((not (secret-shape? secret)) (list (format "the key is ~s" secret)))
                                ((assoc secret (world-secrets w)) (list "the key is a secret issued before"))
                                (else '())))))
          (if (secret-shape? secret)
              (let ((p (probe host secret)))
                (set! requests (+ requests 1))
                (values (append b
                                (same "GET /v1/account with the new key" 200 (got-status p))
                                (same "its account" (uuid-text (macct-id m)) (got-field p "id"))
                                (same "its email" (macct-email m) (got-field p "email")))
                        secret))
              (values b #f))))

      ;; perform : World Expectation Event -> (values Breaks World String)
      ;; The event done to the stack; what differed; the world after; what
      ;; was seen, for the log.
      (define (perform w x e)
        (set! now (ev-at e))
        (case (ev-kind e)
          ((try park malformed)
           (let* ((login? (memq (ev-kind e) '(try park)))
                  (before (calls-now))
                  (lines kit-lines))
             (set! mood (if login? (arg e 'mood) 'normal))
             (set! label (ev-label e))
             (set! armed (eq? (ev-kind e) 'park))
             (let* ((c (send! host 'POST "/v1/login"
                              (login-headers e (if login? "application/json" (arg e 'type)))
                              (if login? (login-body e) (arg e 'body))))
                    (rs (test-client-responses c))
                    (delta (map - (calls-now) before)))
               (set! armed #f)
               (set! requests (+ requests 1))
               (cond
                ((and (null? rs) (test-client-waiting? c))
                 (set! flight-client (list c (arg e 'mood) (ev-label e)))
                 (values (append (same "the status" (expectation-status x) 'parked)
                                 (same "the calls (read verify needs-rehash doubt hash write)"
                                       (expectation-calls x) delta))
                         (expectation-world x) "parked"))
                ((not (= 1 (length rs)))
                 (values (list (format "~a responses, and the handler is not waiting" (length rs)))
                         (expectation-world x) "no answer"))
                (else (answered w x (->got (car rs)) delta (- kit-lines lines)))))))
          ((resume)
           (let ((before (calls-now)) (lines kit-lines))
             (if (not (and parked flight-client))
                 (values (list "no login is parked in its verify") (expectation-world x) "nothing to resume")
                 (let ((c (car flight-client)) (p parked))
                   (set! mood (cadr flight-client))
                   (set! label (caddr flight-client))
                   (set! parked #f)
                   (set! flight-client #f)
                   ((car p) (cdr p))
                   (test-host-advance! host 0)
                   (let ((rs (test-client-responses c))
                         (delta (map - (calls-now) before)))
                     (if (not (= 1 (length rs)))
                         (values (list (format "the resumed login has ~a responses" (length rs)))
                                 (expectation-world x) "no answer")
                         (answered w x (->got (car rs)) delta (- kit-lines lines))))))))
          ((wait) (values '() (expectation-world x) ""))
          ((reset)
           (let* ((tag (arg e 'tag))
                  (m (macct-of tag))
                  (a (world-acct (expectation-world x) tag))
                  (stamp (wall)))
             (run-write store
                        (lambda (tx)
                          (let ((row (account-by-email tx (macct-email m))))
                            (set-password-hash! tx (account-id row) (account-password-hash row) (acct-hash a))
                            (revoke-all-keys! tx (account-id row) stamp))))
             (let ((b (apply append
                             (map (lambda (s)
                                    (let ((p (probe host s)))
                                      (same "GET /v1/account with a key issued before the reset" 401 (got-status p))))
                                  (arg e 'probe)))))
               (set! requests (+ requests (length (arg e 'probe))))
               (values b (expectation-world x) ""))))
          ((fill)
           (let* ((m (macct-of (arg e 'tag)))
                  (k (arg e 'n))
                  (start fillers)
                  (stamp (wall)))
             (set! fillers (+ fillers k))
             (run-write store
                        (lambda (tx)
                          (let loop ((j 0))
                            (when (< j k)
                              (insert-key! tx (filler-bytes 16 #xFF (+ start j)) (macct-id m) "filler"
                                           (filler-bytes 32 #xEE (+ start j)) stamp)
                              (loop (+ j 1))))))
             (values '() (expectation-world x) "")))
          ((probe)
           (let* ((g (probe host (arg e 'secret)))
                  (m (macct-of (cdr (assq 'account (expectation-extra x))))))
             (set! requests (+ requests 1))
             (values (append (same "the status" (expectation-status x) (got-status g))
                             (if (and (eqv? 200 (got-status g)) (eqv? 200 (expectation-status x)))
                                 (same "the account" (uuid-text (macct-id m)) (got-field g "id"))
                                 '()))
                     (expectation-world x) (format "~a" (got-status g)))))
          (else (assertion-violation 'perform "no such event" (ev-kind e)))))

      (define (answered w x g delta lines)
        (let-values (((b secret) (answer-breaks w x g delta lines)))
          (values b
                  (if secret
                      (let ((w2 (expectation-world x)))
                        (with-secrets w2 (cons (list secret (car (expectation-made x)) #t) (world-secrets w2))))
                      (expectation-world x))
                  (format "~a~a" (got-status g)
                          (let ((c (got-field g "code"))) (if c (format " ~a" c) ""))))))

      (define (report i e x breaks seen)
        (string-append
         (format "seed ~a, event ~a: the sequence so far (most windows ~a, hot address ~a~a):\n"
                 seed i maxw hot (if attack? ", an attack" ""))
         (apply string-append (map (lambda (l) (string-append "    " l "\n")) (reverse log)))
         (format "  this event: t=~a ~a\n" (ev-at e) (ev-desc e))
         (format "  the model: ~a ~s retry ~s calls ~s, stepping ~a\n"
                 (expectation-status x) (expectation-code x) (expectation-retry x) (expectation-calls x)
                 (join (map (lambda (r) (format "~a x ~a" (car r) (cadr r))) (expectation-path x)) ", "))
         (format "  the stack: ~a\n" seen)
         (apply string-append (map (lambda (b) (string-append "  - " b "\n")) breaks))
         (format "  replay: TECHO_LOGIN_MODEL_SEED=~a\n" seed)))

      ;; step! : World Natural Event -> (U World String)
      (define (step! w i e)
        (let* ((x (expect R L w e))
               (done (attempt (lambda () (call-with-values (lambda () (perform w x e)) list)))))
          (if (eq? (car done) 'raised)
              (report i e x (list (string-append "the event raised: " (cadr done))) "a raise")
              (let* ((r (cadr done))
                     (w2 (cadr r))
                     (db (attempt (lambda () (db-now store))))
                     (breaks (append (car r)
                                     (if (eq? (car db) 'raised)
                                         (list (string-append "reading the database raised: " (cadr db)))
                                         (db-breaks w2 (cadr db)))
                                     (same "the limiter's windows" (lim-size (world-lim w2))
                                           (limiter-size limiter)))))
                (set! log (cons (format "~a. t=~a ~a -> ~a" i (ev-at e) (ev-desc e) (caddr r)) log))
                (when trace? (display (format "~a. t=~a ~a -> ~a\n" i (ev-at e) (ev-desc e) (caddr r))))
                (if (null? breaks)
                    (begin
                      (for-each (lambda (p) (count! rows p 1)) (expectation-path x))
                      (for-each (lambda (t) (count! tags t 1)) (expectation-tags x))
                      w2)
                    (report i e x breaks (caddr r)))))))

      (seed-db! store)
      (let loop ((w world-start) (i 1))
        (let ((e (cond ((<= i n) (next-event rng hot attack? w i (world-now w)))
                       ((world-flight w) (make-ev 'resume i (world-now w) '() "resume the parked login (closing)"))
                       (else #f))))
          (if (not e)
              (make-verdict seed (- i 1) requests (hashtable->alist rows) (hashtable->alist tags) #f)
              (let ((r (step! w i e)))
                (if (string? r)
                    (make-verdict seed i requests (hashtable->alist rows) (hashtable->alist tags) r)
                    (loop r (+ i 1)))))))))
)
