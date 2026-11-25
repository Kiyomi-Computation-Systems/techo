#!r6rs
;;; The login suite: slice 3b's L1 and L2. First (techo login), pure: the
;;; table, its event kinds, how each ending answers and counts, its
;;; diagram, and the body's parser. Then POST /v1/login as make-app serves
;;; it inside the whole stack (wrap-server), against real SQLite through
;;; the test doorway, raw HTTP bytes in through circuit's test host.
;;;
;;;   the table        machine-problems, every row driven from the start
;;;   the endings      each one's answer and what happens to the count (Q6)
;;;   the two wrongs   a wrong email and a wrong password do the same work (Q1)
;;;   event kinds      a raw outcome sorted by the command it answers
;;;   the diagram      .plans/machines/login.md is what the table renders
;;;   the body         parse-login-body's answer and its every refusal (L2)
;;;   the route        201, 400, 401, 409, 413, 415, 429, 503; Q1, Q2, Q4,
;;;                    Q10; the count kept, forgiven, cleared; the rehash;
;;;                    X-Forwarded-For; the log lines
;;;
;;; The route's hashing is fakes that count their calls; its limiter is the
;;; real one; its duration clock steps by 1 a reading, and a test moves it
;;; on by hand. Everything that can raise is computed under `attempt`, and a
;;; raise comes out as a value the expectation never is.
(import (rnrs)
        (rnrs mutable-pairs)
        (srfi :64)
        (techo-testing)
        (techo machine)
        (techo login)
        (techo limiter)
        (only (circuit) req?)
        (only (jsonparse easy) json->string)
        (only (chez-sqlite3) execute! close-database!)
        (only (techo db) open-techo-db)
        (http-support)
        (only (techo keys) key-secret id->string)
        (except (techo store) key-hash)
        (only (techo auth) key-hash)
        (only (techo routes) make-login-kit)
        (only (techo app) make-app wrap-server))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; raised-kind : (-> Any) -> (U 'no-raise 'assertion 'other)
(define (raised-kind thunk)
  (guard (e ((assertion-violation? e) 'assertion)
            (#t 'other))
    (thunk)
    'no-raise))

(define (read-file path)
  (attempt (lambda () (call-with-input-file path get-string-all))))

(define (string-index-of hay needle)
  (let ((n (string-length needle)) (h (string-length hay)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) i)
            (else (loop (+ i 1)))))))

(test-begin "login")

;;; The table

(define (login-problems rows)
  (attempt (lambda () (machine-problems (make-machine rows) '(limiting) '(ended)
                                        login-cant-happen))))

(test-equal "table: machine-problems answers ()"
  '()
  (login-problems login-rows))

(test-equal "table: nineteen rows"
  19
  (length login-rows))

(test-equal "table: dropping verifying + busy is reported"
  '((unlisted-gap verifying busy))
  (login-problems (filter (lambda (r) (not (and (eq? (car r) 'verifying) (eq? (cadr r) 'busy))))
                          login-rows)))

(test-assert "table: every can't-happen reason is a non-empty string"
  (for-all (lambda (c) (and (string? (caddr c)) (> (string-length (caddr c)) 0)))
           login-cant-happen))

(test-equal "start: limiting, and the command to count the try"
  '(limiting (count))
  (attempt (lambda ()
             (let-values (((s c) (login-start))) (list (car s) c)))))

;; The raw outcomes a test feeds back, by event kind. A Try is any value
;; to the table: it only keeps it.
(define acct (make-bytevector 16 #xA1))
(define events
  (list (cons 'allowed 'the-try)
        (cons 'limited '(limited 30))
        (cons 'full '(full 60 #t))
        (cons 'found (cons acct "stored-hash"))
        (cons 'missing #f)
        (cons 'matched '(matched #f))
        (cons 'matched-outdated '(matched #t))
        (cons 'matched-stand-in '(matched #f))
        (cons 'unmatched '(unmatched #f))
        (cons 'busy 'busy)
        (cons 'hashed 'hashed)
        (cons 'failed 'failed)
        (cons 'rehashed "new-hash")
        (cons 'made 'the-key)
        (cons 'stale 'stale)))

(define (ev kind) (cons kind (cdr (assq kind events))))

;; written-full : the writing state's `full`, which the limiting one's
;; raw does not share
(define (ev* kind state)
  (if (and (eq? kind 'full) (eq? state 'writing)) (cons 'full 'full) (ev kind)))

;; walk : (Listof EventKind) -> (List State Command)
;; From the start, each event in turn; the last state and command.
(define (walk kinds)
  (attempt
   (lambda ()
     (let-values (((s c) (login-start)))
       (let loop ((s s) (c c) (ks kinds))
         (if (null? ks)
             (list s c)
             (let-values (((s2 c2) (login-step s (ev* (car ks) (car s)))))
               (loop s2 c2 (cdr ks)))))))))

;; shown : Command -> Any
;; A command as data a test can compare: an answer's ending opened up.
(define (shown c)
  (if (and (pair? c) (eq? (car c) 'answer))
      (let ((e (cadr c)))
        (list 'answer (ending-code e) (ending-count e) (ending-retry-after e)
              (ending-log-full? e) (caddr c) (cadddr c)))
      c))

;; Each row, the path that drives it from the start, the state it reaches
;; and the command it names.
(define paths
  (list
   (list 'limiting 'allowed '(allowed) 'reading '(read))
   (list 'limiting 'limited '(limited) 'ended '(answer rate_limited keep 30 #f #f #f))
   (list 'limiting 'full '(full) 'ended '(answer rate_limited keep 60 #t #f #f))
   (list 'reading 'found '(allowed found) 'verifying '(verify "stored-hash"))
   (list 'reading 'missing '(allowed missing) 'verifying '(verify #f))
   (list 'verifying 'matched '(allowed found matched) 'writing
         (list 'write acct "stored-hash" #f))
   (list 'verifying 'matched-outdated '(allowed found matched-outdated) 'rehashing
         (list 'rehash acct))
   (list 'verifying 'matched-stand-in '(allowed missing matched-stand-in) 'doubting '(doubt))
   (list 'verifying 'unmatched '(allowed found unmatched) 'doubting '(doubt))
   (list 'verifying 'busy '(allowed found busy) 'ended
         '(answer unavailable forgive 5 #f #f the-try))
   (list 'doubting 'hashed '(allowed found unmatched hashed) 'ended
         '(answer invalid_credentials keep #f #f #f the-try))
   (list 'doubting 'failed '(allowed found unmatched failed) 'ended
         '(answer unavailable forgive 5 #f #f the-try))
   (list 'doubting 'busy '(allowed found unmatched busy) 'ended
         '(answer invalid_credentials keep #f #f #f the-try))
   (list 'rehashing 'rehashed '(allowed found matched-outdated rehashed) 'writing
         (list 'write acct "stored-hash" "new-hash"))
   (list 'rehashing 'failed '(allowed found matched-outdated failed) 'writing
         (list 'write acct "stored-hash" #f))
   (list 'rehashing 'busy '(allowed found matched-outdated busy) 'writing
         (list 'write acct "stored-hash" #f))
   (list 'writing 'made '(allowed found matched made) 'ended
         '(answer created clear #f #f the-key the-try))
   (list 'writing 'stale '(allowed found matched stale) 'ended
         '(answer invalid_credentials keep #f #f #f the-try))
   (list 'writing 'full '(allowed found matched full) 'ended
         '(answer too_many_keys clear #f #f #f the-try))))

(for-each
 (lambda (p)
   (test-equal (string-append "row: " (symbol->string (car p)) " + " (symbol->string (cadr p)))
     (list (list-ref p 3) (list-ref p 4))
     (let ((r (walk (list-ref p 2))))
       (if (and (pair? r) (pair? (car r)))
           (list (caar r) (shown (cadr r)))
           r))))
 paths)

(test-equal "row: the paths drive every row, each once"
  (map (lambda (r) (list (car r) (cadr r))) login-rows)
  (map (lambda (p) (list (car p) (cadr p))) paths))

(test-equal "step: a pair with no row raises an assertion violation"
  'assertion
  (raised-kind (lambda () (login-step (cons 'reading '()) (cons 'matched '(matched #f))))))

;;; The endings: the answer and the count, all of them the table's

(test-equal "endings: each one's answer and count, as the table lists them"
  '((limiting limited rate_limited keep)
    (limiting full rate_limited keep)
    (verifying busy unavailable forgive)
    (doubting hashed invalid_credentials keep)
    (doubting failed unavailable forgive)
    (doubting busy invalid_credentials keep)
    (writing made created clear)
    (writing stale invalid_credentials keep)
    (writing full too_many_keys clear))
  (attempt (lambda () login-endings)))

(test-equal "endings: login-endings is what stepping each ending row gives"
  (attempt (lambda () login-endings))
  (map (lambda (p)
         (let ((c (list-ref p 4)))
           (list (car p) (cadr p) (cadr c) (caddr c))))
       (filter (lambda (p) (eq? (list-ref p 3) 'ended)) paths)))

(test-equal "Q6: only verifying + busy and doubting + failed forgive the try"
  '((verifying busy) (doubting failed))
  (attempt (lambda ()
             (map (lambda (e) (list (car e) (cadr e)))
                  (filter (lambda (e) (eq? (cadddr e) 'forgive)) login-endings)))))

(test-equal "endings: only a key made and a full account clear the email's count"
  '((writing made) (writing full))
  (attempt (lambda ()
             (map (lambda (e) (list (car e) (cadr e)))
                  (filter (lambda (e) (eq? (cadddr e) 'clear)) login-endings)))))

;;; Q1 in the table: the two wrongs

;; commands-of : (Listof EventKind) -> (Listof Any)
;; Every command kind on the way, and the ending shown.
(define (commands-of kinds)
  (attempt
   (lambda ()
     (let-values (((s c) (login-start)))
       (let loop ((s s) (c c) (ks kinds) (acc (list (car c))))
         (if (null? ks)
             (reverse (cons (shown c) acc))
             (let-values (((s2 c2) (login-step s (ev* (car ks) (car s)))))
               (loop s2 c2 (cdr ks) (cons (car c2) acc)))))))))

(test-equal "Q1: a wrong email and a wrong password: count, read, verify, doubt, the same 401"
  '((count read verify doubt answer (answer invalid_credentials keep #f #f #f the-try))
    (count read verify doubt answer (answer invalid_credentials keep #f #f #f the-try)))
  (list (commands-of '(allowed missing unmatched hashed))
        (commands-of '(allowed found unmatched hashed))))

;;; Event kinds

(define a-try (attempt (lambda () (limiter-try! (make-limiter) "a@example.com" "v4:1.2.3.4" 0))))

(define kinds
  (list
   (list "a Try is allowed" '(count) a-try 'allowed)
   (list "(limited s) is limited" '(count) '(limited 12) 'limited)
   (list "(full s first?) is full" '(count) '(full 60 #f) 'full)
   (list "an id and a hash is found" '(read) (cons acct "h") 'found)
   (list "#f is missing" '(read) #f 'missing)
   (list "matched against a stored hash at today's limits" '(verify "h") '(matched #f) 'matched)
   (list "matched against an outdated hash" '(verify "h") '(matched #t) 'matched-outdated)
   (list "matched against the stand-in" '(verify #f) '(matched #f) 'matched-stand-in)
   (list "matched against the stand-in, whatever outdated? says" '(verify #f) '(matched #t)
         'matched-stand-in)
   (list "unmatched" '(verify "h") '(unmatched #f) 'unmatched)
   (list "unmatched against the stand-in" '(verify #f) '(unmatched #f) 'unmatched)
   (list "a full hashing queue" '(verify "h") '(busy #f) 'busy)
   (list "the throwaway hashed" '(doubt) 'hashed 'hashed)
   (list "the throwaway failed" '(doubt) 'failed 'failed)
   (list "the throwaway's queue full" '(doubt) 'busy 'busy)
   (list "a new hash" (list 'rehash acct) "new" 'rehashed)
   (list "a rehash that failed" (list 'rehash acct) 'failed 'failed)
   (list "a rehash's queue full" (list 'rehash acct) 'busy 'busy)
   (list "a key's row is made" (list 'write acct "h" #f) (vector 'a-key-row) 'made)
   (list "stale" (list 'write acct "h" #f) 'stale 'stale)
   (list "full" (list 'write acct "h" #f) 'full 'full)))

(for-each
 (lambda (k)
   (test-equal (string-append "event kind: " (car k))
     (list-ref k 3)
     (attempt (lambda () (login-event-kind (cadr k) (caddr k))))))
 kinds)

(for-each
 (lambda (bad)
   (test-equal (string-append "event kind: " (car bad) " is an assertion violation")
     'assertion
     (raised-kind (lambda () (login-event-kind (cadr bad) (caddr bad))))))
 (list (list "a count that answered a symbol" '(count) 'allowed)
       (list "a read that answered a string" '(read) "h")
       (list "a read whose id is no bytevector" '(read) (cons "id" "h"))
       (list "a verify that answered a bare symbol" '(verify "h") 'matched)
       (list "a verify with an unknown verdict" '(verify "h") '(maybe #f))
       (list "a doubt that answered a string" '(doubt) "h")
       (list "a rehash that answered #f" (list 'rehash acct) #f)
       (list "a write that answered #f" (list 'write acct "h" #f) #f)
       (list "a write that answered another symbol" (list 'write acct "h" #f) 'made)
       (list "an answer, which has no outcome" '(answer) 'x)))

(test-assert "event kinds: each kind a command can answer has a row from its state"
  (let ((state-of '((count . limiting) (read . reading) (verify . verifying)
                    (doubt . doubting) (rehash . rehashing) (write . writing))))
    (for-all (lambda (k)
               (let ((s (cdr (assq (car (cadr k)) state-of)))
                     (e (list-ref k 3)))
                 (exists (lambda (r) (and (eq? (car r) s) (eq? (cadr r) e))) login-rows)))
             kinds)))

;;; The diagram, held to its file

(test-equal ".plans/machines/login.md is what the table renders"
  (attempt (lambda () (login-document)))
  (read-file ".plans/machines/login.md"))

(test-assert "the document has the diagram, an edge, and the endings with their counts"
  (let ((doc (attempt (lambda () (login-document)))))
    (and (string? doc)
         (string-index-of doc "stateDiagram-v2")
         (string-index-of doc "verifying --> rehashing: matched-outdated")
         (string-index-of doc "| doubting | failed | 503 unavailable | forgiven |")
         #t)))

;;; The body (L2)

;; repeat : String Natural -> String     S, N times
(define (repeat s n) (if (= n 0) "" (string-append s (repeat s (- n 1)))))

(define (body . members) members)
(define good-body (body '("email" . "a@example.com") '("password" . "hunter2") '("name" . "laptop")))

(test-equal "body: the three members, in any order: (email password name)"
  '(("a@example.com" "hunter2" "laptop") ("a@example.com" "hunter2" "laptop"))
  (attempt (lambda ()
             (list (parse-login-body good-body)
                   (parse-login-body (reverse good-body))))))

(test-equal "body: the email trimmed and lowercased; a short password is kept, as it is"
  '("a@example.com" "x" "laptop")
  (attempt (lambda ()
             (parse-login-body (body '("email" . "  A@Example.COM ") '("password" . "x")
                                     '("name" . "laptop"))))))

(test-equal "body: the password normalised to NFC"
  (list "a@example.com" (string (integer->char #xE9)) "laptop")
  (attempt (lambda ()
             (parse-login-body (body '("email" . "a@example.com")
                                     (cons "password" (string #\e (integer->char #x301)))
                                     '("name" . "laptop"))))))

(test-equal "body: a password of 1,024 bytes is kept"
  1024
  (attempt (lambda ()
             (string-length (cadr (parse-login-body
                                   (body '("email" . "a@example.com")
                                         (cons "password" (make-string 1024 #\p))
                                         '("name" . "laptop"))))))))

(define (with member value)
  (map (lambda (m) (if (string=? (car m) member) (cons member value) m)) good-body))
(define (without member)
  (filter (lambda (m) (not (string=? (car m) member))) good-body))

(for-each
 (lambda (bad)
   (test-equal (string-append "body: " (car bad) " is refused, " (symbol->string (cadr bad)))
     (cadr bad)
     (attempt (lambda () (parse-login-body (caddr bad))))))
 (list (list "an empty object" 'missing-member '())
       (list "an array" 'not-an-object (vector good-body))
       (list "a string" 'not-an-object "a@example.com")
       (list "a number" 'not-an-object 5)
       (list "null" 'not-an-object 'null)
       (list "true" 'not-an-object #t)
       (list "false" 'not-an-object #f)
       (list "a list that is no object" 'not-an-object '(1 2 3))
       (list "the email twice" 'repeated-member (cons '("email" . "b@example.com") good-body))
       (list "the name twice, the same value" 'repeated-member (append good-body '(("name" . "laptop"))))
       (list "a fourth member" 'unknown-member (append good-body '(("remember" . #t))))
       (list "a member in capitals" 'unknown-member (cons '("Email" . "a@example.com") (without "email")))
       (list "no email" 'missing-member (without "email"))
       (list "no password" 'missing-member (without "password"))
       (list "no name" 'missing-member (without "name"))
       (list "an email that is a number" 'not-a-string (with "email" 5))
       (list "a password that is null" 'not-a-string (with "password" 'null))
       (list "a name that is an object" 'not-a-string (with "name" '(("a" . 1))))
       (list "a name that is an array" 'not-a-string (with "name" (vector "laptop")))
       (list "an email with no @" 'bad-email (with "email" "a.example.com"))
       (list "an email of two @" 'bad-email (with "email" "a@b@example.com"))
       (list "an email over 254 characters" 'bad-email
             (with "email" (string-append (make-string 243 #\a) "@example.com")))
       (list "an empty name" 'bad-name (with "name" ""))
       (list "a name of 65 characters" 'bad-name (with "name" (make-string 65 #\n)))
       (list "a name with a newline" 'bad-name (with "name" "lap\ntop"))
       (list "a password over 1,024 bytes" 'password-too-long
             (with "password" (make-string 1025 #\p)))
       (list "a password of 1,024 characters but 1,026 bytes" 'password-too-long
             (with "password" (repeat (string (integer->char #xE9)) 513)))))

(test-equal "body: the bound is on the bytes after NFC: 1,026 bytes that NFC makes 684 pass"
  684
  (attempt (lambda ()
             (bytevector-length
              (string->utf8
               (cadr (parse-login-body
                      (with "password" (repeat (string #\e (integer->char #x301)) 342)))))))))

;;; ===========================================================================
;;; The route: POST /v1/login

(define dir (fresh-dir "test-login"))

(define acct-b (make-bytevector 16 #xB2))
(define now0 1795515226123)

;; The fakes' hashes: "fake1$" and the password is at today's limits,
;; "fake0$" and the password is outdated.
(define (fake-hash pw) (string-append "fake1$" pw))

(define (seed! tx)
  (insert-account! tx acct "alice" "alice@example.com" (fake-hash "right-password") 1000)
  (insert-account! tx acct-b "bob" "bob@example.com" "fake0$bobs-password" 2000))

(define (prefix? p s)
  (and (>= (string-length s) (string-length p))
       (string=? (substring s 0 (string-length p)) p)))

;; A rig: POST sends a body to /v1/login; CALL any request; COUNT reads a
;; counter (read write verify doubt hash needs-rehash ids); MODE! sets how
;; a fake answers (a hash mode of (raise . X) raises X; a write-raises
;; mode X makes the write runner raise X); LINES and KIT-LINES are the
;; request log's lines and the kit's; ADVANCE! moves the duration clock on;
;; JOB is the last write job.
(define-record-type rig
  (fields post call count mode! lines kit-lines advance! store limiter job))

;; with-rig : String Limiter Natural (Rig -> A) -> A
(define (with-rig name limiter proxies body)
  (let ((s (open-test-store dir name)))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (run-write s seed!)
        (let* ((counts (list (cons 'read 0) (cons 'write 0) (cons 'verify 0) (cons 'doubt 0)
                             (cons 'hash 0) (cons 'needs-rehash 0) (cons 'ids 0)))
               (count! (lambda (k) (let ((c (assq k counts))) (set-cdr! c (+ (cdr c) 1)))))
               (modes (list (cons 'verify #f) (cons 'doubt 'hashed) (cons 'hash #f)
                            (cons 'before-verify #f) (cons 'write-raises #f)))
               (mode (lambda (k) (cdr (assq k modes))))
               (last-job #f)
               (lines '())
               (kit-lines '())
               (offset 0)
               (ticks 0)
               (clock (lambda () (set! ticks (+ ticks 1)) (+ ticks offset)))
               (read (lambda (job) (count! 'read) ((store-reader s) job)))
               (write (lambda (job)
                        (count! 'write)
                        (set! last-job job)
                        (when (mode 'write-raises) (raise (mode 'write-raises)))
                        ((store-writer s) job)))
               (verify (lambda (stored pw)
                         (count! 'verify)
                         (when (mode 'before-verify) ((mode 'before-verify)))
                         (cond ((mode 'verify) (mode 'verify))
                               ((and stored (or (string=? stored (fake-hash pw))
                                                (string=? stored (string-append "fake0$" pw))))
                                'matched)
                               (else 'unmatched))))
               (doubt (lambda () (count! 'doubt) (mode 'doubt)))
               (hash (lambda (pw)
                       (count! 'hash)
                       (let ((m (mode 'hash)))
                         (cond ((and (pair? m) (eq? (car m) 'raise)) (raise (cdr m)))
                               (m m)
                               (else (fake-hash pw))))))
               (needs-rehash (lambda (h) (count! 'needs-rehash) (not (prefix? "fake1$" h))))
               (id-bytes (byte-sequence))
               (ids (lambda () (count! 'ids) (id-bytes 16)))
               (kit (make-login-kit verify doubt hash needs-rehash limiter proxies ids
                                    (lambda (l) (set! kit-lines (cons l kit-lines)))))
               (h (wrap-server (make-app read write (lambda () now0) (byte-sequence) clock kit)
                               (lambda (l) (set! lines (cons l lines)))
                               10000 clock))
               (call (case-lambda
                       ((method target headers) (exchange h method target headers))
                       ((method target headers body) (exchange h method target headers body)))))
          (body (make-rig (case-lambda
                            ((text) (call 'POST "/v1/login" json-type text))
                            ((text headers) (call 'POST "/v1/login" (append json-type headers) text)))
                          call
                          (lambda (k) (cdr (assq k counts)))
                          (lambda (k v) (set-cdr! (assq k modes) v))
                          (lambda () (reverse lines))
                          (lambda () (reverse kit-lines))
                          (lambda (ms) (set! offset (+ offset ms)))
                          s limiter
                          (lambda () last-job)))))
      (lambda () (close-test-store! s)))))

(define json-type '(("Content-Type" . "application/json")))

;; login : String String [String] -> String     a body, as JSON text
(define login
  (case-lambda
    ((email password) (login email password "laptop"))
    ((email password name)
     (json->string (list (cons "email" email) (cons "password" password) (cons "name" name))))))

(define alice-right (login "alice@example.com" "right-password"))
(define alice-wrong (login "alice@example.com" "wrong-password"))

;; status+code : Answer -> (List Natural Any)
(define (status+code a)
  (list (answer-status a)
        (let ((j (answer-json a)))
          (if (and (list? j) (assoc "code" j)) (cdr (assoc "code" j)) j))))

;; counts : Rig -> (List Natural ...)   read write verify doubt hash
(define (counts g)
  (map (rig-count g) '(read write verify doubt hash)))

(define (fresh-limiter) (make-limiter))

;; statuses : Rig String Natural -> (Listof Natural)     N posts of TEXT
(define (statuses g text n)
  (let loop ((i 0) (acc '()))
    (if (= i n)
        (reverse acc)
        (loop (+ i 1) (cons (answer-status ((rig-post g) text)) acc)))))

(define first-secret (key-secret ((byte-sequence) 32)))
(define first-id (id->string ((byte-sequence) 16)))

(test-equal "login: 201, no-store, the key's fields and its secret once; one read, one write, one verify"
  (list 201 "application/json" "no-store"
        (list (cons "id" first-id) (cons "name" "laptop") (cons "created" now0)
              (cons "last_used" 'null) (cons "revoked" 'null) (cons "key" first-secret))
        '(1 1 1 0 0))
  (attempt
   (lambda ()
     (with-rig "happy.db" (fresh-limiter) 0
       (lambda (g)
         (let ((a ((rig-post g) alice-right)))
           (list (answer-status a) (answer-header a "content-type")
                 (answer-header a "cache-control") (answer-json a) (counts g))))))))

(test-equal "login: the secret it answers is a key: GET /v1/account with it is alice"
  '(200 "alice")
  (attempt
   (lambda ()
     (with-rig "happy-key.db" (fresh-limiter) 0
       (lambda (g)
         (let* ((a ((rig-post g) alice-right))
                (secret (cdr (assoc "key" (answer-json a))))
                (b ((rig-call g) 'GET "/v1/account" (list (bearer secret)))))
           (list (answer-status b) (cdr (assoc "username" (answer-json b))))))))))

(test-equal "login: the email in any case and with spaces; the content type with a charset, in capitals"
  '(201 201)
  (attempt
   (lambda ()
     (with-rig "happy-case.db" (fresh-limiter) 0
       (lambda (g)
         (list (answer-status ((rig-post g) (login "  Alice@Example.COM " "right-password")))
               (answer-status ((rig-call g) 'POST "/v1/login"
                                            '(("Content-Type" . "APPLICATION/JSON; charset=utf-8"))
                                            alice-right))))))))

;;; Q1: a wrong email and a wrong password

;; whole : Answer -> (List Natural (Listof Header) String)   but the Date
(define (whole a)
  (list (answer-status a)
        (filter (lambda (h) (not (string=? (car h) "date"))) (answer-headers a))
        (answer-body a)))

(test-equal "Q1: a wrong email and a wrong password answer the same bytes but the Date, a 401"
  '(#t 401 "invalid_credentials" "Bearer")
  (attempt
   (lambda ()
     (with-rig "q1.db" (fresh-limiter) 0
       (lambda (g)
         (let ((a ((rig-post g) (login "nobody@example.com" "right-password")))
               (b ((rig-post g) alice-wrong)))
           (append (list (equal? (whole a) (whole b)))
                   (status+code b)
                   (list (answer-header b "www-authenticate")))))))))

(test-equal "Q1: and do the same work: one read, one verify, one doubt each, no write, no hash"
  '((1 0 1 1 0) (1 0 1 1 0) (0 0))
  (attempt
   (lambda ()
     (list (with-rig "q1-email.db" (fresh-limiter) 0
             (lambda (g) ((rig-post g) (login "nobody@example.com" "right-password")) (counts g)))
           (with-rig "q1-password.db" (fresh-limiter) 0
             (lambda (g) ((rig-post g) alice-wrong) (counts g)))
           (with-rig "q1-rehash.db" (fresh-limiter) 0
             (lambda (g)
               ((rig-post g) alice-wrong)
               ((rig-post g) (login "nobody@example.com" "x"))
               (list ((rig-count g) 'needs-rehash) ((rig-count g) 'ids))))))))

(test-equal "login: a verify that says matched for an unknown email is still a 401, after a doubt"
  '(401 "invalid_credentials" (1 0 1 1 0))
  (attempt
   (lambda ()
     (with-rig "stand-in.db" (fresh-limiter) 0
       (lambda (g)
         ((rig-mode! g) 'verify 'matched)
         (let ((a ((rig-post g) (login "nobody@example.com" "anything"))))
           (append (status+code a) (list (counts g)))))))))

;;; The count: five tries an email, then 429; Q2

(test-equal "limit: five wrong tries are 401s; the sixth is a 429, retry-after the window's 900 s"
  '((401 401 401 401 401) (429 "rate_limited") "900")
  (attempt
   (lambda ()
     (with-rig "limit.db" (fresh-limiter) 0
       (lambda (g)
         (let* ((five (statuses g alice-wrong 5))
                (a ((rig-post g) alice-wrong)))
           (list five (status+code a) (answer-header a "retry-after"))))))))

(test-equal "limit: retry-after is the seconds left: 600 five minutes in; the right password too"
  '((429 "rate_limited") "600")
  (attempt
   (lambda ()
     (with-rig "limit-later.db" (fresh-limiter) 0
       (lambda (g)
         (statuses g alice-wrong 5)
         ((rig-advance! g) 300000)
         (let ((a ((rig-post g) alice-right)))
           (list (status+code a) (answer-header a "retry-after"))))))))

(test-equal "limit: once the window has passed, the first try is answered: 201"
  '(429 201)
  (attempt
   (lambda ()
     (with-rig "limit-passed.db" (fresh-limiter) 0
       (lambda (g)
         (statuses g alice-wrong 5)
         ((rig-advance! g) 899000)
         (let* ((a ((rig-post g) alice-right))
                (b (begin ((rig-advance! g) 1000) ((rig-post g) alice-right))))
           (list (answer-status a) (answer-status b))))))))

(test-equal "Q2: a limited try reads nothing and hashes nothing"
  '((5 0 5 5 0) (5 0 5 5 0) 429)
  (attempt
   (lambda ()
     (with-rig "q2.db" (fresh-limiter) 0
       (lambda (g)
         (statuses g alice-wrong 5)
         (let* ((before (counts g))
                (a ((rig-post g) alice-right)))
           (list before (counts g) (answer-status a))))))))

(test-equal "limit: a good login clears the email's count: five more wrong tries are 401s, then 429"
  '(201 (401 401 401 401 401) 429)
  (attempt
   (lambda ()
     (with-rig "clear.db" (fresh-limiter) 0
       (lambda (g)
         (statuses g alice-wrong 4)
         (let* ((a ((rig-post g) alice-right))
                (five (statuses g alice-wrong 5))
                (b ((rig-post g) alice-wrong)))
           (list (answer-status a) five (answer-status b))))))))

;;; Bodies that are refused before the count

;; bad-bodies : (Listof (List String Headers String Status Code))
(define long-name (make-string 16400 #\n))
(define bad-bodies
  (list (list "no content type" '() alice-right 415 "unsupported_media_type")
        (list "text/plain" '(("Content-Type" . "text/plain")) alice-right 415 "unsupported_media_type")
        (list "a +json type" '(("Content-Type" . "application/merge-patch+json")) alice-right
              415 "unsupported_media_type")
        (list "two content types" '(("Content-Type" . "application/json") ("Content-Type" . "application/json"))
              alice-right 415 "unsupported_media_type")
        (list "JSON that does not parse" json-type "{\"email\": \"alice@example.com\", nope" 400 "invalid_json")
        (list "an empty body" json-type "" 400 "invalid_request")
        (list "an array" json-type (string-append "[" alice-right "]") 400 "invalid_request")
        (list "an unknown member" json-type
              "{\"email\":\"alice@example.com\",\"password\":\"right-password\",\"name\":\"l\",\"x\":1}"
              400 "invalid_request")
        (list "the email twice" json-type
              "{\"email\":\"alice@example.com\",\"email\":\"alice@example.com\",\"password\":\"right-password\",\"name\":\"l\"}"
              400 "invalid_request")
        (list "a bad key name" json-type (login "alice@example.com" "right-password" "") 400 "invalid_request")
        (list "a body over 16 KiB" json-type (login "alice@example.com" "right-password" long-name)
              413 "payload_too_large")
        (list "application/jsonx" '(("Content-Type" . "application/jsonx")) alice-right
              415 "unsupported_media_type")
        (list "application/json-seq" '(("Content-Type" . "application/json-seq")) alice-right
              415 "unsupported_media_type")))

(for-each
 (lambda (b)
   (test-equal (string-append "body: " (car b) ": " (number->string (list-ref b 3)) " "
                              (list-ref b 4) ", nothing read, hashed or counted")
     (list (list-ref b 3) (list-ref b 4) '(0 0 0 0 0) 0)
     (attempt
      (lambda ()
        (with-rig "bad-body.db" (fresh-limiter) 0
          (lambda (g)
            (let ((a ((rig-call g) 'POST "/v1/login" (cadr b) (caddr b))))
              (append (status+code a) (list (counts g) (limiter-size (rig-limiter g)))))))))))
 bad-bodies)

(test-equal "body: the media type is application/json in any case, its parameters and the spaces before them ignored"
  '(201 201 201)
  (attempt
   (lambda ()
     (with-rig "types.db" (fresh-limiter) 0
       (lambda (g)
         (map (lambda (type)
                (answer-status ((rig-call g) 'POST "/v1/login" (list (cons "Content-Type" type))
                                             alice-right)))
              '("application/json; charset=utf-8" "APPLICATION/JSON" "application/json ;charset=utf-8")))))))

;; padded : Natural -> String
;; A login body of exactly N bytes, its key name padded with n's. The name
;; is far over 64 characters, so a body the cap lets through is a 400.
(define (padded n)
  (let ((base (bytevector-length (string->utf8 (login "alice@example.com" "right-password" "")))))
    (login "alice@example.com" "right-password" (make-string (- n base) #\n))))

(test-equal "body: the cap is 16,384 bytes: a body of exactly 16,384 is read whole (400 invalid_request: its name is over 64 characters), one of 16,385 is 413"
  '((16384 400 "invalid_request") (16385 413 "payload_too_large"))
  (attempt
   (lambda ()
     (with-rig "cap.db" (fresh-limiter) 0
       (lambda (g)
         (map (lambda (n)
                (let* ((text (padded n))
                       (a ((rig-call g) 'POST "/v1/login" json-type text)))
                  (cons (bytevector-length (string->utf8 text)) (status+code a))))
              '(16384 16385)))))))

(test-equal "body: after six refused bodies for alice, the right password still logs in"
  '((415 415 400 400 400 400) 201)
  (attempt
   (lambda ()
     (with-rig "bad-then-good.db" (fresh-limiter) 0
       (lambda (g)
         (let* ((six (map (lambda (b) (answer-status ((rig-call g) 'POST "/v1/login" (cadr b) (caddr b))))
                          (list (list-ref bad-bodies 0) (list-ref bad-bodies 1) (list-ref bad-bodies 4)
                                (list-ref bad-bodies 5) (list-ref bad-bodies 7) (list-ref bad-bodies 9))))
                (a ((rig-post g) alice-right)))
           (list six (answer-status a))))))))

(test-equal "route: GET /v1/login is the router's 405, allow: POST"
  '(405 "method_not_allowed" "POST")
  (attempt
   (lambda ()
     (with-rig "get.db" (fresh-limiter) 0
       (lambda (g)
         (let ((a ((rig-call g) 'GET "/v1/login" '())))
           (append (status+code a) (list (answer-header a "allow")))))))))

;;; The hashing queue and short memory

(test-equal "busy: a full queue at the verify is a 503, retry-after 5, and forgiven: five, then a 201"
  '((503 "unavailable") "5" (503 503 503 503) 201)
  (attempt
   (lambda ()
     (with-rig "verify-busy.db" (fresh-limiter) 0
       (lambda (g)
         ((rig-mode! g) 'verify 'busy)
         (let* ((a ((rig-post g) alice-right))
                (four (statuses g alice-right 4))
                (b (begin ((rig-mode! g) 'verify #f) ((rig-post g) alice-right))))
           (list (status+code a) (answer-header a "retry-after") four (answer-status b))))))))

(test-equal "busy: a full queue at the doubt is a 401, and stays counted: five, then a 429"
  '((401 "invalid_credentials") (401 401 401 401) 429)
  (attempt
   (lambda ()
     (with-rig "doubt-busy.db" (fresh-limiter) 0
       (lambda (g)
         ((rig-mode! g) 'doubt 'busy)
         (let* ((a ((rig-post g) alice-wrong))
                (four (statuses g alice-wrong 4))
                (b (begin ((rig-mode! g) 'doubt 'hashed) ((rig-post g) alice-right))))
           (list (status+code a) four (answer-status b))))))))

(test-equal "memory: a doubt that failed is a 503, retry-after 5, and forgiven: five, then a 201"
  '((503 "unavailable") "5" (503 503 503 503) 201)
  (attempt
   (lambda ()
     (with-rig "doubt-failed.db" (fresh-limiter) 0
       (lambda (g)
         ((rig-mode! g) 'doubt 'failed)
         (let* ((a ((rig-post g) alice-wrong))
                (four (statuses g alice-wrong 4))
                (b (begin ((rig-mode! g) 'doubt 'hashed) ((rig-post g) alice-right))))
           (list (status+code a) (answer-header a "retry-after") four (answer-status b))))))))

;;; The rehash

;; stored : Rig Bytevector -> String
(define (stored g account)
  (run-read (rig-store g) (lambda (tx) (account-password-hash (account-by-id tx account)))))

(test-equal "rehash: an outdated hash is hashed again and stored with the key; one hash"
  '(201 "fake1$bobs-password" 1 1)
  (attempt
   (lambda ()
     (with-rig "rehash.db" (fresh-limiter) 0
       (lambda (g)
         (let ((a ((rig-post g) (login "bob@example.com" "bobs-password"))))
           (list (answer-status a) (stored g acct-b) ((rig-count g) 'hash)
                 ((rig-count g) 'needs-rehash))))))))

(test-equal "rehash: a hash at today's limits is not hashed again"
  '(201 0 1)
  (attempt
   (lambda ()
     (with-rig "no-rehash.db" (fresh-limiter) 0
       (lambda (g)
         (let ((a ((rig-post g) alice-right)))
           (list (answer-status a) ((rig-count g) 'hash) ((rig-count g) 'needs-rehash))))))))

(for-each
 (lambda (mode)
   (test-equal (string-append "rehash: a rehash that answers " (symbol->string mode)
                              " still logs in, the old hash kept")
     '(201 "fake0$bobs-password" 1)
     (attempt
      (lambda ()
        (with-rig "rehash-fails.db" (fresh-limiter) 0
          (lambda (g)
            ((rig-mode! g) 'hash mode)
            (let ((a ((rig-post g) (login "bob@example.com" "bobs-password"))))
              (list (answer-status a) (stored g acct-b) ((rig-count g) 'hash)))))))))
 '(failed busy))

;;; Q4 and Q10

;; key-count : Rig Bytevector -> Natural
(define (key-count g account)
  (run-read (rig-store g) (lambda (tx) (count-active-keys tx account))))

(test-equal "Q4: the password reset between the verify and the write: 401, no key made"
  '((401 "invalid_credentials") 0 1)
  (attempt
   (lambda ()
     (with-rig "q4.db" (fresh-limiter) 0
       (lambda (g)
         ((rig-mode! g) 'before-verify
          (lambda ()
            ;; techo user password, beside the server
            (let ((db (open-techo-db (store-path (rig-store g)) 'read-write)))
              (execute! db "UPDATE accounts SET password_hash = ? WHERE email = ?"
                        "fake1$a-new-password" "alice@example.com")
              (close-database! db))))
         (let ((a ((rig-post g) alice-right)))
           (list (status+code a) (key-count g acct) ((rig-count g) 'write))))))))

;; keys-up-to! : Rig Natural -> Void     alice's active keys made N in all
(define (keys-up-to! g n)
  (let ((have (key-count g acct)))
    (run-write (rig-store g)
               (lambda (tx)
                 (let loop ((i 0))
                   (when (< i (- n have))
                     (insert-key! tx (make-bytevector 16 (+ 100 i)) acct "filler"
                                  (key-hash (key-secret (make-bytevector 32 (+ 100 i)))) (+ 3000 i))
                     (loop (+ i 1))))))))

(test-equal "Q10: 99 active keys: 201, and 100; then 409 too_many_keys, and still 100"
  '(99 201 100 (409 "too_many_keys") 100)
  (attempt
   (lambda ()
     (with-rig "q10.db" (fresh-limiter) 0
       (lambda (g)
         (keys-up-to! g 99)
         (let* ((before (key-count g acct))
                (a ((rig-post g) alice-right))
                (mid (key-count g acct))
                (b ((rig-post g) alice-right)))
           (list before (answer-status a) mid (status+code b) (key-count g acct))))))))

(test-equal "Q10: a 409 clears the email's count: four wrong, the 409, then five 401s"
  '(409 (401 401 401 401 401) 429)
  (attempt
   (lambda ()
     (with-rig "q10-clear.db" (fresh-limiter) 0
       (lambda (g)
         (keys-up-to! g 100)
         (statuses g alice-wrong 4)
         (let* ((a ((rig-post g) alice-right))
                (five (statuses g alice-wrong 5))
                (b ((rig-post g) alice-wrong)))
           (list (answer-status a) five (answer-status b))))))))

;;; The address: X-Forwarded-For, by the proxy count

;; from : Rig String String -> Natural
;; A wrong login for a fresh email, X-Forwarded-For: XFF; its status.
(define (from g email xff)
  (answer-status ((rig-post g) (login email "wrong") (list (cons "X-Forwarded-For" xff)))))

(test-equal "address: one proxy: the last entry keys the count, whatever comes before it"
  '((401 401 429) 401)
  (attempt
   (lambda ()
     (with-rig "xff-1.db" (make-limiter 100 2) 1
       (lambda (g)
         (list (list (from g "e1@example.com" "1.1.1.1")
                     (from g "e2@example.com" "7.7.7.7, 1.1.1.1")
                     (from g "e3@example.com" "8.8.8.8, 1.1.1.1"))
               (from g "e4@example.com" "1.1.1.1, 2.2.2.2")))))))

(test-equal "address: two proxies: the second from the end"
  '((401 401 429) 401)
  (attempt
   (lambda ()
     (with-rig "xff-2.db" (make-limiter 100 2) 2
       (lambda (g)
         (list (list (from g "e1@example.com" "1.1.1.1, 10.0.0.1")
                     (from g "e2@example.com" "9.9.9.9, 1.1.1.1, 10.0.0.1")
                     (from g "e3@example.com" "1.1.1.1:5678, 10.0.0.2"))
               (from g "e4@example.com" "1.1.1.1, 2.2.2.2, 10.0.0.1")))))))

(test-equal "address: no proxy: the header is ignored, every try is the peer's"
  '(401 401 429)
  (attempt
   (lambda ()
     (with-rig "xff-0.db" (make-limiter 100 2) 0
       (lambda (g)
         (list (from g "e1@example.com" "1.1.1.1")
               (from g "e2@example.com" "2.2.2.2")
               (from g "e3@example.com" "3.3.3.3")))))))

;;; The table of windows full

(test-equal "full: no room for a window is a 429, retry-after 60, and one line, once"
  '(401 ((429 "rate_limited") "60") (429 "rate_limited") ("limiter full=1") (0 0 0 0 0))
  (attempt
   (lambda ()
     (with-rig "full.db" (make-limiter 5 20 900000 2) 0
       (lambda (g)
         (let* ((a ((rig-post g) alice-wrong))
                (before (counts g))
                (b ((rig-post g) (login "e2@example.com" "x")))
                (c ((rig-post g) (login "e3@example.com" "x"))))
           (list (answer-status a)
                 (list (status+code b) (answer-header b "retry-after"))
                 (status+code c)
                 ((rig-kit-lines g))
                 (map - (counts g) before))))))))

;;; The request log

(test-equal "log: a good login has the account, and db_ms the sum of its read and its write"
  (list (string-append "request method=POST path=/v1/login status=201 ending=written ms=6 db_ms=2 account="
                       (id->string acct) " address=-"))
  (attempt
   (lambda ()
     (with-rig "log-good.db" (fresh-limiter) 0
       (lambda (g) ((rig-post g) alice-right) ((rig-lines g)))))))

(test-equal "log: a wrong password has no account; a 409 has it"
  (list "request method=POST path=/v1/login status=401 ending=written ms=4 db_ms=1 account=- address=-"
        (string-append "request method=POST path=/v1/login status=409 ending=written ms=6 db_ms=2 account="
                       (id->string acct) " address=-"))
  (attempt
   (lambda ()
     (with-rig "log-bad.db" (fresh-limiter) 0
       (lambda (g)
         ((rig-post g) alice-wrong)
         (keys-up-to! g 100)
         ((rig-post g) alice-right)
         ((rig-lines g)))))))

(test-equal "log: a limited try and a refused body have neither"
  '("request method=POST path=/v1/login status=429 ending=written ms=2 db_ms=- account=- address=-"
    "request method=POST path=/v1/login status=415 ending=written ms=1 db_ms=- account=- address=-")
  (attempt
   (lambda ()
     (with-rig "log-limited.db" (fresh-limiter) 0
       (lambda (g)
         (statuses g alice-wrong 5)
         ((rig-post g) alice-right)
         ((rig-call g) 'POST "/v1/login" '() alice-right)
         (list-tail ((rig-lines g)) 5))))))

;; field : String String -> (U String #f)     NAME's value in a log line
(define (field line name)
  (let ((at (string-index-of line (string-append " " name "="))))
    (and at
         (let* ((start (+ at (string-length name) 2))
                (end (let loop ((i start))
                       (if (or (= i (string-length line)) (char=? (string-ref line i) #\space))
                           i
                           (loop (+ i 1))))))
           (substring line start end)))))

;; raised-line : Rig -> (List Natural (U String #f) (U String #f) String Natural)
;; Bob's right password (his hash is outdated, so the rehash runs): the
;; status; the status and account of its log line; what wrap-catch wrote
;; on standard output; and how many hashes ran.
(define (raised-line g)
  (let-values (((a printed)
                (capture-output (lambda () ((rig-post g) (login "bob@example.com" "bobs-password"))))))
    (let ((line (car (reverse ((rig-lines g))))))
      (list (answer-status a) (field line "status") (field line "account") printed
            ((rig-count g) 'hash)))))

(test-equal "log: the password matched, then the rehash raised (a deadline mid-hash, say): the 500 still shows the account"
  (list 500 "500" (id->string acct-b) "handler-failed hash-broke\n" 1)
  (attempt
   (lambda ()
     (with-rig "log-rehash-raise.db" (fresh-limiter) 0
       (lambda (g)
         ((rig-mode! g) 'hash (cons 'raise 'hash-broke))
         (raised-line g))))))

(test-equal "log: the password matched and was hashed again, then the write raised: the 500 still shows the account"
  (list 500 "500" (id->string acct-b) "handler-failed write-broke\n" 1)
  (attempt
   (lambda ()
     (with-rig "log-write-raise.db" (fresh-limiter) 0
       (lambda (g)
         ((rig-mode! g) 'write-raises 'write-broke)
         (raised-line g))))))

;;; Secrets

(define (is s) (lambda (x) (and (string? x) (string=? x s))))

(test-equal "secrets: the write job reaches no request, no password and no secret; no line holds them"
  '(#t #f #f #f #f #f)
  (attempt
   (lambda ()
     (with-rig "secrets.db" (fresh-limiter) 0
       (lambda (g)
         (let* ((a ((rig-post g) alice-right))
                (secret (cdr (assoc "key" (answer-json a))))
                (job ((rig-job g)))
                (lines (apply string-append ((rig-lines g)))))
           (list (procedure? job)
                 (reaches? job req?)
                 (reaches? job (is "right-password"))
                 (reaches? job (is secret))
                 (contains? lines "right-password")
                 (contains? lines secret))))))))

(test-end "login")

(exit (suite-exit-status runner))
