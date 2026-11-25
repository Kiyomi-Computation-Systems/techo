#!r6rs
;;; The users suite: (techo users), the shell of `techo user add` and
;;; `techo user password` (slice 3b's L9).
;;;
;;;   read-password     string ports, a fake echo switch (one that fails too),
;;;                     a port that raises, the order of echo and prompt
;;;   the arguments     every refusal, before any file is touched
;;;   the file          check-db's refusals, the file left as it was
;;;   user add          the row read back with the store; both duplicates
;;;   user password     the hash set and the keys revoked, in one job
;;;   beside another    the write lock held elsewhere; the file moved; the
;;;                     hash before the read-write open
;;;   the source        never names the two doorway procedures
;;;
;;; Each command runs on a real SQLite file the shipped migrations made,
;;; with a fake hash ("H:" and the password), a fixed clock and a counting
;;; id source, each recording its calls. The two -command! procedures read
;;; the process's standard input: here only their refusals run, which come
;;; before any read, with Chez's port parameters set to string ports. Their
;;; terminal path needs a terminal, which the container has not: it is tried
;;; by hand.
;;;
;;; Every database file is under build/test-users/<unique>/. Everything that
;;; can raise is computed under `attempt`, and a raise comes out as a value
;;; the expectation never is.
(import (rnrs)
        (only (rnrs mutable-strings) string-set!)
        (only (chezscheme) mkdir directory-list delete-directory file-directory?
                           chmod current-time time-second time-nanosecond parameterize)
        (rename (only (chezscheme) current-input-port current-output-port current-error-port)
                (current-input-port input-param) (current-output-port output-param)
                (current-error-port error-param))
        (srfi :64)
        (chez-sqlite3)
        (techo-testing)
        (techo migrations)
        (techo db)
        (only (techo doorway) doorway-set-up doorway-tear-down run-job! make-job-shell)
        (only (techo transaction) write-start write-step read-start read-step)
        (techo store)
        (techo users))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; answers : (-> Any ...) -> (Listof Any)      a command's three values
(define (answers thunk) (call-with-values thunk list))

;;; The directory

(define (rm-tree! p)
  (cond ((file-directory? p)
         (for-each (lambda (n) (rm-tree! (string-append p "/" n)))
                   (directory-list p))
         (delete-directory p))
        ((file-exists? p) (delete-file p))))

(define (make-dir! p) (unless (file-directory? p) (mkdir p #o755)))

(define test-dir
  (let ((t (current-time)))
    (guard (e (#t #f))
      (make-dir! "build")
      (rm-tree! "build/test-users")
      (make-dir! "build/test-users")
      (let ((d (string-append "build/test-users/"
                              (number->string (time-second t)) "-"
                              (number->string (time-nanosecond t)))))
        (make-dir! d)
        d))))

(define (path name) (string-append test-dir "/" name))

(define (clean! p)
  (for-each (lambda (s) (when (file-exists? (string-append p s))
                          (delete-file (string-append p s))))
            '("" "-wal" "-shm" "-journal")))

;; fresh : String -> String
;; A file the shipped migrations made, in WAL, closed cleanly: no -wal or
;; -shm beside it. A read-only open makes both and leaves them.
(define (fresh name)
  (let ((p (path name)))
    (clean! p)
    (migrate! p migrations)
    p))

;; missing : String -> String     a path with nothing there
(define (missing name)
  (let ((p (path name))) (clean! p) p))

(define (beside? p suffix) (file-exists? (string-append p suffix)))

;; files-of : String -> (List Boolean Boolean Boolean)   the file, -wal, -shm
(define (files-of p) (list (file-exists? p) (beside? p "-wal") (beside? p "-shm")))

;; read-bytes : String -> Bytevector     an empty file is an empty bytevector
(define (read-bytes p)
  (let ((bv (call-with-port (open-file-input-port p) get-bytevector-all)))
    (if (eof-object? bv) (make-bytevector 0) bv)))

(define (write-bytes! p bv)
  (when (file-exists? p) (delete-file p))
  (call-with-port (open-file-output-port p) (lambda (o) (put-bytevector o bv))))

;; plain : String -> Database     chez-sqlite3 alone: creates, never waits
(define (plain p) (open-database p '((busy-timeout . 0))))

(define (with-db db proc)
  (dynamic-wind (lambda () #f) (lambda () (proc db))
                (lambda () (guard (e (#t #f)) (close-database! db)))))

;; behind-with-leftover : String -> String
;; A file at version 1 of the shipped migrations whose writer never
;; checkpointed: the version is only in a leftover -wal, copied from a live
;; connection. A read-only open reads it and leaves the main file as it was;
;; a read-write open and close folds the -wal into the main file.
(define (behind-with-leftover name)
  (let ((src (path (string-append "src-" name))) (dst (path name)))
    (clean! src) (clean! dst)
    (with-db (plain src)
      (lambda (db)
        (query-row db "PRAGMA journal_mode = wal")
        (execute! db "PRAGMA wal_autocheckpoint = 0")
        (for-each (lambda (s) (execute! db s)) (caddr (assv 1 migrations)))
        (execute! db "PRAGMA user_version = 1")
        (write-bytes! dst (read-bytes src))
        (write-bytes! (string-append dst "-wal") (read-bytes (string-append src "-wal")))))
    dst))

;;; Jobs, as the doorway's write thread runs them, for setting up and
;;; reading back

;; job-on : String Symbol (Tx -> A) -> A
;; MODE 'read-write runs a write job, 'read-only a read job, on a
;; connection of their own, closed after.
(define (job-on p mode job)
  (let ((b (doorway-set-up p mode migrations))
        (latest (latest-version migrations)))
    (dynamic-wind
      (lambda () #f)
      (lambda ()
        (if (eq? mode 'read-write)
            (let-values (((s c) (write-start latest)))
              (run-job! write-step s (make-job-shell b) job))
            (let-values (((s c) (read-start latest)))
              (run-job! read-step s (make-job-shell b) job))))
      (lambda () (doorway-tear-down b)))))

(define (account->list a)
  (and a (list (account-id a) (account-username a) (account-email a)
               (account-password-hash a) (account-created a))))

;; keys-of : String Bytevector -> (Listof (List Natural (U Natural #f)))
;; Each key of the account as its id's first byte and its revoked time.
(define (keys-of p account)
  (job-on p 'read-only
    (lambda (tx)
      (map (lambda (k) (list (bytevector-u8-ref (key-id k) 0) (key-revoked k)))
           (keys-page tx account #f 100)))))

(define (count-accounts p)
  (with-db (plain p)
    (lambda (db) (vector-ref (query-row db "SELECT count(*) FROM accounts") 0))))

;;; The kit's fakes

(define now-ms 1764000000123)

;; id-of : Natural -> Bytevector      the counting id source's Nth id
(define (id-of n) (make-bytevector 16 (+ #xa0 n)))

;; kit-with : String (U #f (-> Any)) (U #f (-> Any)) -> (values UserKit (-> (Listof Any)))
;; A kit on P, and a thunk giving the fakes' calls in order: (hash PW),
;; clock, (id N). ON-HASH and ON-CLOCK, when given, run inside the fake's
;; call, to act on the file at that moment.
(define (kit-with p on-hash on-clock)
  (let* ((calls '())
         (note! (lambda (c) (set! calls (cons c calls))))
         (n 0)
         (kit (make-user-kit
               p migrations
               (lambda (pw) (note! (list 'hash pw)) (when on-hash (on-hash))
                       (string-append "H:" pw))
               (lambda () (note! 'clock) (when on-clock (on-clock)) now-ms)
               (lambda () (set! n (+ n 1)) (note! (list 'id n)) (id-of n)))))
    (values kit (lambda () (reverse calls)))))

;; kit-on : String -> UserKit
(define (kit-on p) (let-values (((kit calls) (kit-with p #f #f))) kit))

;; hashed : (Listof Any) -> (Listof Any)     only the hash calls
(define (hashed calls) (filter (lambda (c) (and (pair? c) (eq? (car c) 'hash))) calls))

(test-begin "users")

;;; read-password

;; read-with : String Boolean [Boolean] -> (List Answer String (Listof Boolean) String)
;; The answer, what was written to the prompt port, the echo switch's
;; calls in order, and what was left unread. The switch answers #t, as a
;; switch that worked, unless OFF-WORKS? is #f: then turning the echo off
;; answers #f.
(define read-with
  (case-lambda
    ((text terminal?) (read-with text terminal? #t))
    ((text terminal? off-works?)
     (let ((in (open-string-input-port text))
           (echoes '()))
       (let-values (((out written) (open-string-output-port)))
         (let* ((answer (read-password in out terminal?
                                       (lambda (on?)
                                         (set! echoes (cons on? echoes))
                                         (or on? off-works?))))
                (prompts (written))
                (rest (get-string-all in)))
           (list answer prompts (reverse echoes) (if (eof-object? rest) "" rest))))))))

(test-equal "read-password, a pipe: the first line only, no prompt, the echo untouched"
  '("hunter2-pass" "" () "next line\n")
  (attempt (lambda () (read-with "hunter2-pass\nnext line\n" #f))))

(test-equal "read-password, a pipe: one trailing \\r is dropped, and only one"
  '(("secret-pass" "" () "more") ("abc\r" "" () ""))
  (attempt (lambda () (list (read-with "secret-pass\r\nmore" #f)
                            (read-with "abc\r\r\n" #f)))))

(test-equal "read-password, a pipe: spaces at either end are kept; a last line with no newline counts"
  '(("  two  spaces  " "" () "") ("lastline" "" () ""))
  (attempt (lambda () (list (read-with "  two  spaces  \n" #f)
                            (read-with "lastline" #f)))))

(test-equal "read-password, a pipe: an empty line, a lone \\r and end of file are each 'empty"
  '((empty "" () "next") (empty "" () "") (empty "" () ""))
  (attempt (lambda () (list (read-with "\nnext" #f)
                            (read-with "\r\n" #f)
                            (read-with "" #f)))))

(test-equal "read-password, a terminal: asked twice, a newline after each, echo off then on; the two match"
  '("pass word 1" "Password: \nAgain: \n" (#f #t) "rest")
  (attempt (lambda () (read-with "pass word 1\r\npass word 1\nrest" #t))))

(test-equal "read-password, a terminal: two different entries, or none the second time, are 'mismatch"
  '((mismatch "Password: \nAgain: \n" (#f #t) "")
    (mismatch "Password: \nAgain: \n" (#f #t) ""))
  (attempt (lambda () (list (read-with "one-pass\ntwo-pass\n" #t)
                            (read-with "one-pass\n" #t)))))

(test-equal "read-password, a terminal: an empty first entry is 'empty, and nothing more is asked"
  '((empty "Password: \n" (#f #t) "second\n") (empty "Password: \n" (#f #t) ""))
  (attempt (lambda () (list (read-with "\nsecond\n" #t)
                            (read-with "" #t)))))

(test-equal "read-password, a terminal: an echo that will not turn off reads nothing, prompts nothing, is 'no-echo; the echo is turned on again"
  '((no-echo "" (#f #t) "pass word 1\npass word 1\n") (no-echo "" (#f #t) ""))
  (attempt (lambda () (list (read-with "pass word 1\npass word 1\n" #t #f)
                            (read-with "" #t #f)))))

(test-equal "read-password, a pipe: the echo switch is not called, even one that fails"
  '("pass word 1" "" () "")
  (attempt (lambda () (read-with "pass word 1\n" #f #f))))

;; events-of : String -> (Listof Any)
;; A terminal read of TEXT, as one list of what happened in order: each
;; switch of the echo as (echo on?), and the text written between them,
;; each run of writes as one string.
(define (events-of text)
  (let* ((events '())
         (note! (lambda (e) (set! events (cons e events))))
         (out (make-custom-textual-output-port "events"
                (lambda (str start count)
                  (note! (substring str start (+ start count)))
                  count)
                #f #f #f))
         (answer (read-password (open-string-input-port text) out #t
                                (lambda (on?) (note! (list 'echo on?)) #t))))
    (cons answer
          (let loop ((es (reverse events)) (acc '()))
            (cond ((null? es) (reverse acc))
                  ((and (string? (car es)) (pair? acc) (string? (car acc)))
                   (loop (cdr es) (cons (string-append (car acc) (car es)) (cdr acc))))
                  (else (loop (cdr es) (cons (car es) acc))))))))

(test-equal "read-password, a terminal: the echo is off before the first prompt, and on again after the last"
  '(("pass word 1" (echo #f) "Password: \nAgain: \n" (echo #t))
    (empty (echo #f) "Password: \n" (echo #t)))
  (attempt (lambda () (list (events-of "pass word 1\npass word 1\n") (events-of "\n")))))

;; raising-port : Natural -> TextualInputPort
;; Gives the first LINES lines of "line-N\n", then raises 'port-broke.
(define (raising-port lines)
  (let ((given 0))
    (make-custom-textual-input-port "raising"
      (lambda (str start count)
        (if (< given lines)
            (let ((s (string-append "line-" (number->string given) "\n")))
              (set! given (+ given 1))
              (let loop ((i 0))
                (when (< i (string-length s))
                  (string-set! str (+ start i) (string-ref s i))
                  (loop (+ i 1))))
              (string-length s))
            (raise 'port-broke)))
      #f #f #f)))

(test-equal "read-password, a terminal: a read that raises still turns the echo back on, and the raise goes on"
  '((port-broke (#f #t) "Password: ") (port-broke (#f #t) "Password: \nAgain: "))
  (attempt
   (lambda ()
     (map (lambda (lines)
            (let ((echoes '()))
              (let-values (((out written) (open-string-output-port)))
                (let* ((raised (guard (e ((eq? e 'port-broke) 'port-broke)
                                         (#t (list 'other (describe e))))
                                 (read-password (raising-port lines) out #t
                                                (lambda (on?) (set! echoes (cons on? echoes)) #t))
                                 'no-raise))
                       (prompts (written)))
                  (list raised (reverse echoes) prompts)))))
          '(0 1)))))

;;; The arguments (rule 1): refused before any file is touched

(define good-password "correct horse")

;; refusal-everywhere : (UserKit String -> (Listof Any)) -> (List Any Any Any Any Any)
;; RUN on a clean migrated file and on a missing path: both answers, what
;; lies beside each afterwards, and the hash calls. A read-only look would
;; have left a -wal and -shm by the clean file; any open of the missing
;; path, a file.
(define (refusal-everywhere name run)
  (let* ((p (fresh (string-append name ".db")))
         (q (missing (string-append name "-missing.db"))))
    (let-values (((kit calls) (kit-with p #f #f))
                 ((kit-q calls-q) (kit-with q #f #f)))
      (let* ((a (run kit))
             (b (run kit-q)))
        (list a b (files-of p) (files-of q) (append (hashed (calls)) (hashed (calls-q))))))))

;; refused-as : String -> (List Any Any Any Any Any)    what refusal-everywhere should see
(define (refused-as line)
  (list (list 1 '() (list line)) (list 1 '() (list line))
        '(#t #f #f) '(#f #f #f) '()))

(define username-cases
  (list (list "" "the username is empty")
        (list (make-string 33 #\a) "the username is longer than 32 characters")
        (list "_alice" "the username must start with a lowercase letter or a digit")
        (list "Alice" "the username must start with a lowercase letter or a digit")
        (list "ali ce" "the username may hold only lowercase letters, digits, _ and -")
        (list "alicE" "the username may hold only lowercase letters, digits, _ and -")))

(define email-line
  "the email is not valid: it needs one @ with text on each side, no spaces, and 254 bytes at most")

(define email-cases
  (list "no-at-sign" "a@b@c" "@example.com" "alice@" "al ice@example.com"
        (string-append (make-string 250 #\a) "@b.co")))

(define password-cases
  (list (list "zq7-six" "the password is shorter than 8 characters")
        ;; 8 code points, but 7 once NFC joins e and its accent
        (list "abcdefe\x301;" "the password is shorter than 8 characters")
        (list (make-string 1025 #\x) "the password is longer than 1,024 bytes")
        ;; 513 characters, 1,026 bytes
        (list (make-string 513 #\xe9) "the password is longer than 1,024 bytes")
        (list 'empty "no password was given")
        (list 'mismatch "the two passwords do not match")
        (list 'no-echo "cannot turn off the terminal's echo; pipe the password in instead")))

(for-each
 (lambda (c)
   (test-equal (string-append "user add, the username: refused as \"" (cadr c)
                              "\", and no file looked at")
     (refused-as (cadr c))
     (attempt (lambda ()
                (refusal-everywhere "u"
                  (lambda (kit) (answers (lambda () (user-add! kit (car c) "alice@example.com"
                                                               good-password)))))))))
 username-cases)

(test-equal "user add, the email: each bad one refused by the one line, and no file looked at"
  (map (lambda (e) (refused-as email-line)) email-cases)
  (attempt
   (lambda ()
     (map (lambda (e)
            (refusal-everywhere "e"
              (lambda (kit) (answers (lambda () (user-add! kit "alice" e good-password))))))
          email-cases))))

(test-equal "user add, the password: each refused by its line, never holding the password, and no file looked at"
  (map (lambda (c) (refused-as (cadr c))) password-cases)
  (attempt
   (lambda ()
     (map (lambda (c)
            (refusal-everywhere "p"
              (lambda (kit) (answers (lambda () (user-add! kit "alice" "alice@example.com" (car c)))))))
          password-cases))))

(test-equal "user add: the username is judged first, then the email, then the password"
  (list (refused-as "the username is empty") (refused-as email-line))
  (attempt
   (lambda ()
     (list (refusal-everywhere "o1" (lambda (kit) (answers (lambda () (user-add! kit "" "bad" 'empty)))))
           (refusal-everywhere "o2" (lambda (kit) (answers (lambda () (user-add! kit "alice" "bad" 'empty)))))))))

(test-equal "user password: a bad email, then each bad password, refused by its line, and no file looked at"
  (cons (refused-as email-line) (map (lambda (c) (refused-as (cadr c))) password-cases))
  (attempt
   (lambda ()
     (cons (refusal-everywhere "pe" (lambda (kit) (answers (lambda () (user-password! kit "nope" 'empty)))))
           (map (lambda (c)
                  (refusal-everywhere "pp"
                    (lambda (kit) (answers (lambda () (user-password! kit "alice@example.com" (car c)))))))
                password-cases)))))

;;; The file (rule 2): check-db's own line, nothing opened read-write

(test-equal "a missing file: check-db's line, for both commands; no file made, nothing hashed"
  (let ((r (list 1 '() (list "the database file is missing: run `techo migrate`"))))
    (list r r '(#f #f #f) '()))
  (attempt
   (lambda ()
     (let ((q (missing "gone.db")))
       (let-values (((kit calls) (kit-with q #f #f)))
         (let* ((a (answers (lambda () (user-add! kit "alice" "alice@example.com" good-password))))
                (b (answers (lambda () (user-password! kit "alice@example.com" good-password)))))
           (list a b (files-of q) (hashed (calls)))))))))

(test-equal "a file that needs techo migrate: check-db's line, for both commands; the main file byte for byte the same, nothing hashed"
  (let ((r (list 1 '() (list "the database is behind this binary: run `techo migrate`"))))
    (list r r #t #t '()))
  (attempt
   (lambda ()
     (let* ((p (behind-with-leftover "behind.db"))
            (before (read-bytes p)))
       (let-values (((kit calls) (kit-with p #f #f)))
         (let* ((a (answers (lambda () (user-add! kit "alice" "alice@example.com" good-password))))
                (b (answers (lambda () (user-password! kit "alice@example.com" good-password)))))
           (list a b (bytevector=? before (read-bytes p)) (beside? p "-wal") (hashed (calls)))))))))

(test-equal "an empty file and another program's file: check-db's lines; neither changed"
  (list (list 1 '() (list "the database is empty: run `techo migrate`")) #t
        (list 1 '() (list "not Techo's database")) #t)
  (attempt
   (lambda ()
     (let ((e (path "empty.db")) (f (path "foreign.db")))
       (clean! e) (clean! f)
       (write-bytes! e (make-bytevector 0))
       (with-db (plain f) (lambda (db) (execute! db "CREATE TABLE t (x)")))
       (let ((e-before (read-bytes e)) (f-before (read-bytes f)))
         (let* ((a (answers (lambda () (user-add! (kit-on e) "alice" "alice@example.com" good-password))))
                (a-same (bytevector=? e-before (read-bytes e)))
                (b (answers (lambda () (user-password! (kit-on f) "alice@example.com" good-password))))
                (b-same (bytevector=? f-before (read-bytes f))))
           (list a a-same b b-same)))))))

;;; The two -command! procedures: the database before the password

;; with-stdio : String (-> A) -> (List A String String String)
;; THUNK with standard input reading TEXT and standard output and error
;; written to strings, through Chez's port parameters: its value, what it
;; wrote on each, and what it left unread.
(define (with-stdio text thunk)
  (let ((in (open-string-input-port text)))
    (let-values (((out out-text) (open-string-output-port))
                 ((err err-text) (open-string-output-port)))
      (let* ((v (parameterize ((input-param in) (output-param out) (error-param err))
                  (thunk)))
             (rest (get-string-all in)))
        (list v (out-text) (err-text) (if (eof-object? rest) "" rest))))))

(define typed "a password typed\na password typed\n")

;; command-refused : String -> (List Any Any Any)    what each command should see
(define (command-refused line)
  (list 1 "" (string-append "techo: " line "\n") typed))

(test-equal "the commands, a missing file: status 1 and check-db's line, before the password is read or asked for; nothing hashed"
  (let ((r (command-refused "the database file is missing: run `techo migrate`")))
    (list r r '(#f #f #f) '()))
  (attempt
   (lambda ()
     (let ((q (missing "cmd-gone.db")))
       (let-values (((kit calls) (kit-with q #f #f)))
         (let* ((a (with-stdio typed (lambda () (user-add-command! kit "alice" "alice@example.com"))))
                (b (with-stdio typed (lambda () (user-password-command! kit "alice@example.com")))))
           (list a b (files-of q) (hashed (calls)))))))))

(test-equal "the commands, a file that needs techo migrate: status 1 and check-db's line, before the password is read or asked for"
  (let ((r (command-refused "the database is behind this binary: run `techo migrate`")))
    (list r r #t '()))
  (attempt
   (lambda ()
     (let* ((p (behind-with-leftover "cmd-behind.db"))
            (before (read-bytes p)))
       (let-values (((kit calls) (kit-with p #f #f)))
         (let* ((a (with-stdio typed (lambda () (user-add-command! kit "alice" "alice@example.com"))))
                (b (with-stdio typed (lambda () (user-password-command! kit "alice@example.com")))))
           (list a b (bytevector=? before (read-bytes p)) (hashed (calls)))))))))

(test-equal "the commands: a bad username, then a bad email, is refused before the database is looked at"
  (list (command-refused "the username is empty") (command-refused email-line)
        (command-refused email-line) '(#f #f #f))
  (attempt
   (lambda ()
     (let* ((q (missing "cmd-args.db"))
            (kit (kit-on q))
            (a (with-stdio typed (lambda () (user-add-command! kit "" "bad"))))
            (b (with-stdio typed (lambda () (user-add-command! kit "alice" "bad"))))
            (c (with-stdio typed (lambda () (user-password-command! kit "bad")))))
       (list a b c (files-of q))))))

;;; user add

(test-equal "user add: one line with the account's id; the row holds the normalised email, the hash of the password, the clock's time"
  (list (list 0 (list "added alice alice@example.com a1a1a1a1-a1a1-a1a1-a1a1-a1a1a1a1a1a1") '())
        (list (id-of 1) "alice" "alice@example.com" "H:correct horse" now-ms)
        '((hash "correct horse"))
        '(#t #f #f))
  (attempt
   (lambda ()
     (let ((p (fresh "add.db")))
       (let-values (((kit calls) (kit-with p #f #f)))
         (let* ((r (answers (lambda () (user-add! kit "alice" "  Alice@Example.COM " good-password))))
                (files (files-of p))
                (row (account->list (job-on p 'read-only (lambda (tx) (account-by-username tx "alice"))))))
           (list r row (hashed (calls)) files)))))))

(test-equal "user add: the password is hashed in its NFC form, and kept with its spaces"
  '("H: caf\xe9; au lait " ((hash " caf\xe9; au lait ")))
  (attempt
   (lambda ()
     (let ((p (fresh "add-nfc.db")))
       (let-values (((kit calls) (kit-with p #f #f)))
         (let* ((r (answers (lambda () (user-add! kit "bob" "bob@example.com" " cafe\x301; au lait "))))
                (a (job-on p 'read-only (lambda (tx) (account-by-username tx "bob")))))
           (list (account-password-hash a) (hashed (calls)))))))))

(test-equal "user add: a username or an email already there is refused by name; nothing is written"
  (list (list 1 '() '("the username alice is taken"))
        (list 1 '() '("the email alice@example.com is taken"))
        1
        (list (id-of 1) "alice" "alice@example.com" "H:correct horse" now-ms))
  (attempt
   (lambda ()
     (let* ((p (fresh "add-dup.db"))
            (kit (kit-on p)))
       (user-add! kit "alice" "alice@example.com" good-password)
       (let* ((a (answers (lambda () (user-add! kit "alice" "other@example.com" "another password"))))
              (b (answers (lambda () (user-add! kit "bob" " ALICE@example.com" "another password"))))
              (n (count-accounts p))
              (row (account->list (job-on p 'read-only (lambda (tx) (account-by-email tx "alice@example.com"))))))
         (list a b n row))))))

;;; user password

;; with-accounts : String (UserKit String -> A) -> A
;; alice (id 1) with keys 1 and 2 active and 3 revoked at 500; bob (id 2)
;; with key 4 active; carol (id 3) with key 5 active. Keys made at 100.
(define (with-accounts name body)
  (let* ((p (fresh name))
         (kit (kit-on p)))
    (user-add! kit "alice" "alice@example.com" "alice's password")
    (user-add! kit "bob" "bob@example.com" "bob's password")
    (user-add! kit "carol" "carol@example.com" "carol's password")
    (job-on p 'read-write
      (lambda (tx)
        (insert-key! tx (make-bytevector 16 1) (id-of 1) "one" (make-bytevector 32 1) 100)
        (insert-key! tx (make-bytevector 16 2) (id-of 1) "two" (make-bytevector 32 2) 100)
        (insert-key! tx (make-bytevector 16 3) (id-of 1) "three" (make-bytevector 32 3) 100)
        (revoke-key! tx (id-of 1) (make-bytevector 16 3) 500)
        (insert-key! tx (make-bytevector 16 4) (id-of 2) "four" (make-bytevector 32 4) 100)
        (insert-key! tx (make-bytevector 16 5) (id-of 3) "five" (make-bytevector 32 5) 100)))
    (body kit p)))

(define (hash-of p email)
  (job-on p 'read-only
    (lambda (tx) (account-password-hash (account-by-email tx email)))))

(test-equal "user password: the hash is set, every active key of the account revoked at the clock's time, and the count told"
  (list (list 0 '("password set for alice@example.com; 2 keys revoked") '())
        "H:a new password"
        (list (list 1 now-ms) (list 2 now-ms) (list 3 500))
        "H:bob's password"
        '((4 #f)))
  (attempt
   (lambda ()
     (with-accounts "reset.db"
       (lambda (kit p)
         (let* ((r (answers (lambda () (user-password! kit " Alice@Example.com" "a new password")))))
           (list r (hash-of p "alice@example.com") (keys-of p (id-of 1))
                 (hash-of p "bob@example.com") (keys-of p (id-of 2)))))))))

(test-equal "user password: one key is \"1 key\", none is \"0 keys\""
  (list (list 0 '("password set for carol@example.com; 1 key revoked") '())
        (list 0 '("password set for carol@example.com; 0 keys revoked") '())
        "H:the third one")
  (attempt
   (lambda ()
     (with-accounts "reset-count.db"
       (lambda (kit p)
         (let* ((a (answers (lambda () (user-password! kit "carol@example.com" "the second one"))))
                (b (answers (lambda () (user-password! kit "carol@example.com" "the third one")))))
           (list a b (hash-of p "carol@example.com"))))))))

(test-equal "user password: an email no account has is refused by name; nothing changes"
  (list (list 1 '() '("no account has the email nobody@example.com"))
        "H:alice's password"
        (list (list 1 #f) (list 2 #f) (list 3 500)))
  (attempt
   (lambda ()
     (with-accounts "reset-none.db"
       (lambda (kit p)
         (let ((r (answers (lambda () (user-password! kit "NOBODY@example.com" "a new password")))))
           (list r (hash-of p "alice@example.com") (keys-of p (id-of 1)))))))))

;;; Beside another connection

(test-equal "user password while another connection holds the write lock: the busy line after the busy timeout, not a hang; nothing changes"
  (list (list 1 '() '("the database is busy: another program holds it"))
        "H:alice's password"
        (list (list 1 #f) (list 2 #f) (list 3 500)))
  (attempt
   (lambda ()
     (with-accounts "busy.db"
       (lambda (kit p)
         (let ((r (with-db (open-techo-db p 'read-write 0)
                    (lambda (other)
                      (execute! other "BEGIN IMMEDIATE")
                      (let ((r (answers (lambda () (user-password! kit "alice@example.com" "a new password")))))
                        (execute! other "ROLLBACK")
                        r)))))
           (list r (hash-of p "alice@example.com") (keys-of p (id-of 1)))))))))

(test-equal "the hash runs before the read-write open: a file made read-only while hashing is refused at the open"
  (list (list 1 '() '("cannot write the database file: check its permissions"))
        '((hash "correct horse"))
        0)
  (attempt
   (lambda ()
     (let ((p (fresh "order.db")))
       (let-values (((kit calls) (kit-with p (lambda () (chmod p #o444)) #f)))
         (let ((r (dynamic-wind
                    (lambda () #f)
                    (lambda () (answers (lambda () (user-add! kit "alice" "alice@example.com" good-password))))
                    (lambda () (chmod p #o644)))))
           (list r (hashed (calls)) (count-accounts p))))))))

(test-equal "a file migrated under the command, once it is open: the moved line, and nothing written"
  (list (list 1 '() (list (string-append
                           "the database changed under this command: it is at version "
                           (number->string (+ 1 (latest-version migrations)))
                           " and this binary expects "
                           (number->string (latest-version migrations)))))
        0)
  (attempt
   (lambda ()
     (let ((p (fresh "moved.db")))
       (let-values (((kit calls)
                     (kit-with p #f
                       (lambda ()
                         (with-db (plain p)
                           (lambda (db)
                             (execute! db (string-append "PRAGMA user_version = "
                                                         (number->string (+ 1 (latest-version migrations)))))))))))
         (let ((r (answers (lambda () (user-add! kit "alice" "alice@example.com" good-password)))))
           (list r (count-accounts p))))))))

(test-equal "a raise that is not the database's goes on"
  '(hash-broke 0)
  (attempt
   (lambda ()
     (let ((p (fresh "raise.db")))
       (let-values (((kit calls) (kit-with p (lambda () (raise 'hash-broke)) #f)))
         (let ((r (guard (e ((eq? e 'hash-broke) 'hash-broke))
                    (user-add! kit "alice" "alice@example.com" good-password)
                    'no-raise)))
           (list r (count-accounts p))))))))

;;; The source

(define users-source
  (guard (e (#t #f)) (call-with-input-file "src/techo/users.sls" get-string-all)))

;; contains? : String String -> Boolean
(define (contains? s word)
  (let ((n (string-length s)) (k (string-length word)))
    (let loop ((i 0))
      (cond ((> (+ i k) n) #f)
            ((string=? (substring s i (+ i k)) word) #t)
            (else (loop (+ i 1)))))))

(test-equal "the source: read, and it never writes either doorway procedure's name, not even in a comment"
  '(#t #f #f)
  (attempt (lambda ()
             (list (and (string? users-source) (contains? users-source "doorway-set-up"))
                   (contains? users-source (string-append "db-" "read"))
                   (contains? users-source (string-append "db-" "write"))))))

(test-equal "the source: (techo doorway) is imported with only"
  '(only)
  (attempt
   (lambda ()
     (let* ((lib (call-with-input-file "src/techo/users.sls" read))
            (imports (cdr (assq 'import (cddr lib)))))
       (fold-right (lambda (spec acc)
                     (cond ((equal? spec '(techo doorway)) (cons 'plain acc))
                           ((and (pair? spec) (pair? (cdr spec))
                                 (equal? (cadr spec) '(techo doorway)))
                            (cons (car spec) acc))
                           (else acc)))
                   '() imports)))))

(test-end "users")

(exit (suite-exit-status runner))
