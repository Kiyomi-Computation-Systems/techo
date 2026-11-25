#!r6rs
;;; The wiring suite: (techo wiring), how techo.sps builds the program's
;;; parts from the real ones. A wrong argument there would pass every other
;;; suite but the integration one, so each part is held to what it must do:
;;;
;;;   sodium-hasher      the hasher over chez-sodium's verbs: a real hash
;;;                      verifies; short memory is 'failed, and only that
;;;   program-login-kit  the kit over that hasher: a wrong try costs one
;;;                      throwaway hash, a refused one none; the limits are
;;;                      5 tries in 15 minutes; an outdated hash is hashed
;;;                      again, a current one kept
;;;   duration-clock     milliseconds that only go forward, not the time of day
;;;   id-source          UUIDs of version 7 carrying the given clock's time
;;;   program-user-kit   `user add`'s hash at the pinned limits, NFC, the
;;;                      clock's time and version 7 ids
;;;
;;; The real verbs run at 'interactive (about 50 ms each), so the suite
;;; keeps to what it needs: one hasher, opened once; accounts whose wrong
;;; tries verify against a hash made at the smallest limits.
;;;
;;; A call to the hasher waits for its worker's thread, so each one, and
;;; each login, runs in a test host that is run until its answer is in.
;;; Everything that can raise is computed under `attempt` or a guard, and a
;;; raise comes out as a value the expectation never is.
(import (rnrs)
        (only (chezscheme) make-time sleep current-time time-second time-nanosecond)
        (srfi :64)
        (techo-testing)
        (only (chez-sodium) random-bytes password-hash make-password-limits)
        (only (chez-sodium private conditions) make-sodium-failed)
        (only (circuit) make-res)
        (only (circuit http-server) circuit->handler)
        (only (http-server testing) make-test-host test-host-connect! test-client-send!
              test-host-advance! test-client-responses test-response-status
              test-response-header test-response-body test-response-complete?)
        (only (jsonparse easy) string->json json->string)
        (only (unique-id) bytevector->uuid string->uuid uuid->bytevector uuid-version
              uuid-v7-timestamp)
        (only (http-support) request-bytes fresh-dir open-test-store store-reader store-writer
              store-path run-write run-read close-test-store!)
        (only (techo store) insert-account! account-by-email account-password-hash
              account-created)
        (only (techo migrations) migrations)
        (only (techo hasher) hasher-open! hasher-stop! hasher-verify hasher-doubt)
        (only (techo passwords) sodium-hash)
        (only (techo users) user-add!)
        (only (techo app) wrap-server)
        (techo wiring))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; pinned : String     how a hash at 'interactive starts: 64 MiB, 2 passes, 1 lane
(define pinned "$argon2id$v=19$m=65536,t=2,p=1$")

;; prefix : String -> (U String #f)
;; A hash's text up to its fourth $: the algorithm, version and limits.
(define (prefix s)
  (and (string? s)
       (let loop ((i 0) (dollars 0))
         (cond ((= i (string-length s)) #f)
               ((char=? (string-ref s i) #\$)
                (if (= dollars 3) (substring s 0 (+ i 1)) (loop (+ i 1) (+ dollars 1))))
               (else (loop (+ i 1) dollars))))))

(define nfc-password "caf\xe9;-au-lait")    ; e acute, one character
(define nfd-password "cafe\x301;-au-lait")   ; e, then a combining acute

(test-begin "wiring")

;;; The host: a call that waits for the hasher's thread

(define unset (lambda (name) #f))

;; settle! : TestHost (-> Boolean) -> Void
;; Runs the host until DONE? answers true, or 10 s have passed.
(define (settle! host done?)
  (let ((deadline (+ (time-second (current-time)) 10)))
    (let loop ()
      (test-host-advance! host 0)
      (unless (or (done?) (> (time-second (current-time)) deadline))
        (sleep (make-time 'time-duration 1000000 0))
        (loop)))))

;; hosted : (-> A) -> (U (List 'returned A) (List 'raised Any) 'no-answer)
;; THUNK as the handler of one request; the raised object itself, so a test
;; can ask whether it is the one raised.
(define (hosted thunk)
  (let* ((cell (vector #f))
         (app (lambda (req)
                (vector-set! cell 0 (guard (e (#t (list 'raised e))) (list 'returned (thunk))))
                (make-res 200 '() "ok")))
         (host (make-test-host (circuit->handler app unset) unset))
         (c (test-host-connect! host)))
    (test-client-send! c (string->utf8 "GET /x HTTP/1.1\r\nHost: x\r\n\r\n"))
    (settle! host (lambda () (vector-ref cell 0)))
    (or (vector-ref cell 0) 'no-answer)))

;; Login = (List Natural (U String #f) Any)    status, retry-after, the body's JSON

;; post : Handler String String -> (U Login 'no-answer)
;; One POST /v1/login of EMAIL and PASSWORD through HANDLER, its key named
;; "wiring", the host run until the client has read the whole answer.
(define (post handler email password)
  (let* ((host (make-test-host (circuit->handler handler unset) unset))
         (c (test-host-connect! host))
         (text (json->string (list (cons "email" email) (cons "password" password)
                                   (cons "name" "wiring")))))
    (test-client-send! c (request-bytes 'POST "/v1/login" '(("Content-Type" . "application/json"))
                                        text))
    (settle! host (lambda () (let ((rs (test-client-responses c)))
                               (and (pair? rs) (test-response-complete? (car rs))))))
    (let ((rs (test-client-responses c)))
      (if (null? rs)
          'no-answer
          (let ((r (car rs)))
            (list (test-response-status r)
                  (let ((v (test-response-header r "retry-after"))) (and v (utf8->string v)))
                  (guard (e (#t 'not-json)) (string->json (utf8->string (test-response-body r))))))))))

(define (status-of login) (if (pair? login) (car login) login))

;;; The world: one file, one hasher, one app

;; The hash the hasher is given: sodium-hash, counted; or a raise of
;; RAISING, when it is set.
(define hash-calls 0)
(define raising #f)
(define (counted-hash password)
  (set! hash-calls (+ hash-calls 1))
  (when raising (raise raising))
  (sodium-hash password))

;; with-raising : Any (-> A) -> A     THUNK with the hash raising X
(define (with-raising x thunk)
  (dynamic-wind (lambda () (set! raising x)) thunk (lambda () (set! raising #f))))

(define now-ms 1764000000123)
(define (wall-clock) now-ms)
(define weak-limits (make-password-limits 1 8))

(define weak-id (make-bytevector 16 #xA1))
(define strong-id (make-bytevector 16 #xA2))
(define tries-id (make-bytevector 16 #xA3))

(define-record-type (world-record make-world world?)
  (fields (immutable store world-store) (immutable hasher world-hasher)
          (immutable app world-app) (immutable strong-hash world-strong-hash)))

;; world : (U World (List 'raised String))
;; weak@ and tries@ hold hashes made at the smallest limits, so a verify
;; against them is quick; strong@ holds one sodium-hash made.
(define world
  (attempt
   (lambda ()
     (let* ((s (open-test-store (fresh-dir "test-wiring") "wiring.db"))
            (strong (sodium-hash "strong password")))
       (run-write s (lambda (tx)
                      (insert-account! tx weak-id "weak" "weak@example.com"
                                       (password-hash "weak password" weak-limits) 1000)
                      (insert-account! tx strong-id "strong" "strong@example.com" strong 1000)
                      (insert-account! tx tries-id "tries" "tries@example.com"
                                       (password-hash "tries password" weak-limits) 1000)))
       (let* ((h (sodium-hasher random-bytes counted-hash))
              (kit (begin (hasher-open! h)
                          (program-login-kit h 0 (id-source wall-clock random-bytes)
                                             (lambda (line) #f))))
              (app (wrap-server (program-app (store-reader s) (store-writer s) wall-clock
                                             random-bytes kit)
                                (lambda (line) #f))))
         (make-world s h app strong))))))

(define (stored-hash email)
  (run-read (world-store world)
            (lambda (tx) (account-password-hash (account-by-email tx email)))))

;;; sodium-hasher

(test-equal "sodium-hasher: a hash sodium-hash made verifies its password, matched, and not another, unmatched"
  '((returned matched) (returned unmatched))
  (attempt
   (lambda ()
     (let* ((h (world-hasher world))
            (stored (world-strong-hash world))
            (right (hosted (lambda () (hasher-verify h stored "strong password"))))
            (wrong (hosted (lambda () (hasher-verify h stored "strong passwore")))))
       (list right wrong)))))

(test-equal "sodium-hasher: a hash that raises chez-sodium's &sodium-failed makes the doubt failed: memory is short"
  '(returned failed)
  (attempt
   (lambda ()
     (let ((h (world-hasher world)))
       (with-raising (make-sodium-failed "crypto_pwhash_str" -1)
         (lambda () (hosted (lambda () (hasher-doubt h)))))))))

(test-equal "sodium-hasher: any other raise in the doubt's hash goes on as itself, and is not failed"
  '(raised #t)
  (attempt
   (lambda ()
     (let* ((h (world-hasher world))
            (other (make-message-condition "not a short memory"))
            (r (with-raising other (lambda () (hosted (lambda () (hasher-doubt h)))))))
       (if (and (pair? r) (eq? (car r) 'raised))
           (list 'raised (eq? (cadr r) other))
           r)))))

;;; program-login-kit and program-app

;; tries : Natural -> (List (Listof Natural) (Listof Natural))
;; N wrong tries for tries@: each one's status, and how many hashes each ran.
(define (tries n)
  (let loop ((i 0) (statuses '()) (hashes '()))
    (if (= i n)
        (list (reverse statuses) (reverse hashes))
        (let* ((before hash-calls)
               (a (post (world-app world) "tries@example.com" "not the password"))
               (ran (- hash-calls before)))
          (loop (+ i 1) (cons (status-of a) statuses) (cons ran hashes))))))

(test-equal "program-login-kit: five wrong tries are 401s, each one throwaway hash; the sixth is a 429 with no hash, retry-after 890 to 900"
  '(((401 401 401 401 401) (1 1 1 1 1)) 429 0 #t)
  (attempt
   (lambda ()
     (let* ((five (tries 5))
            (before hash-calls)
            (sixth (post (world-app world) "tries@example.com" "not the password"))
            (ran (- hash-calls before))
            (retry (and (pair? sixth) (cadr sixth) (string->number (cadr sixth)))))
       (list five (status-of sixth) ran (and (integer? retry) (<= 890 retry 900)))))))

(test-equal "program-login-kit: a good login rehashes a hash made at the smallest limits to the pinned ones"
  (list "$argon2id$v=19$m=8,t=1,p=1$" 201 pinned)
  (attempt
   (lambda ()
     (let* ((before (prefix (stored-hash "weak@example.com")))
            (a (post (world-app world) "weak@example.com" "weak password"))
            (after (prefix (stored-hash "weak@example.com"))))
       (list before (status-of a) after)))))

(test-equal "program-login-kit: a good login keeps a hash at the pinned limits exactly as it was"
  '(201 #t)
  (attempt
   (lambda ()
     (let* ((before (stored-hash "strong@example.com"))
            (a (post (world-app world) "strong@example.com" "strong password"))
            (after (stored-hash "strong@example.com")))
       (list (status-of a) (string=? before after))))))

;;; duration-clock

(test-equal "duration-clock: far below a time of day in ms, never back, and on after a short wait"
  '(#t #t #t)
  (attempt
   (lambda ()
     (let* ((first (duration-clock))
            (readings (let loop ((i 0) (acc '()))
                        (if (= i 1000) (reverse acc) (loop (+ i 1) (cons (duration-clock) acc)))))
            (never-back? (let loop ((prev first) (rs readings))
                           (or (null? rs) (and (>= (car rs) prev) (loop (car rs) (cdr rs))))))
            ;; a busy wait, for one second of the time of day at most
            (stop (+ (time-second (current-time)) 1))
            (moved? (let loop ()
                      (cond ((> (duration-clock) first) #t)
                            ((> (time-second (current-time)) stop) #f)
                            (else (loop))))))
       (list (and (integer? first) (exact? first) (< first (expt 10 11))) never-back? moved?)))))

;;; id-source

(test-equal "id-source: 16 bytes, version 7, the clock's time, the second greater"
  (list 16 16 7 7 now-ms now-ms #t)
  (attempt
   (lambda ()
     (let* ((next (id-source wall-clock random-bytes))
            (a (next))
            (b (next))
            (ua (bytevector->uuid a))
            (ub (bytevector->uuid b)))
       (list (bytevector-length a) (bytevector-length b) (uuid-version ua) (uuid-version ub)
             (uuid-v7-timestamp ua) (uuid-v7-timestamp ub)
             (let loop ((i 0))
               (and (< i 16)
                    (let ((x (bytevector-u8-ref a i)) (y (bytevector-u8-ref b i)))
                      (or (< x y) (and (= x y) (loop (+ i 1))))))))))))

;;; program-user-kit

;; id-of-line : String -> (U Bytevector #f)     the id at the end of `added NAME EMAIL ID`
(define (id-of-line line)
  (let ((n (string-length line)))
    (and (>= n 36)
         (let ((u (string->uuid (substring line (- n 36) n))))
           (and u (uuid->bytevector u))))))

(test-equal "program-user-kit: user add stores the pinned hash of the NFC password, the clock's time, and a version 7 id of that time"
  (list 0 pinned now-ms 7 now-ms)
  (attempt
   (lambda ()
     (let* ((kit (program-user-kit (store-path (world-store world)) migrations wall-clock
                                   random-bytes))
            (r (call-with-values (lambda () (user-add! kit "nfd" "nfd@example.com" nfd-password))
                 list))
            (row (run-read (world-store world)
                           (lambda (tx) (account-by-email tx "nfd@example.com"))))
            (id (and (pair? (cadr r)) (id-of-line (car (cadr r))))))
       (list (car r) (prefix (account-password-hash row)) (account-created row)
             (uuid-version (bytevector->uuid id)) (uuid-v7-timestamp (bytevector->uuid id)))))))

(test-equal "program-user-kit: the password typed in NFD logs in when sent in NFC"
  201
  (attempt (lambda () (status-of (post (world-app world) "nfd@example.com" nfc-password)))))

(guard (e (#t #f)) (hasher-stop! (world-hasher world)))
(guard (e (#t #f)) (close-test-store! (world-store world)))

(test-end "wiring")

(exit (suite-exit-status runner))
