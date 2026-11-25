#!r6rs
;;; (techo users): the imperative shell of `techo user add` and
;;; `techo user password` (slice 3b's L9). techo.sps calls the two
;;; -command! procedures and exits with what they answer.
;;;
;;; Each command, in this order:
;;;   1. checks its arguments, purely, and refuses before touching a file;
;;;   2. runs check-db, which opens the file read-only: a file it refuses is
;;;      never opened read-write (ADR-0012). The -command! procedures run
;;;      it before they read the password too, so no one types a password
;;;      for a file that will be refused;
;;;   3. hashes the password, holding no lock;
;;;   4. opens the file read-write and runs ONE write job, by the doorway's
;;;      table, as the server's write thread runs one (ADR-0013), so it
;;;      works beside a running server; then closes it, whatever happens.
;;; The database's refusals (&db-refused, &db-unavailable) are a line and
;;; status 1; any other raise goes on.
;;;
;;; The kit carries the world: the path, the migrations, the hash, the
;;; clock and the ids. techo.sps passes the real ones; tests pass fakes.
;;; Nothing here prints but the two -command! procedures.
(library (techo users)
  (export make-user-kit read-password user-add! user-password!
          user-add-command! user-password-command!)
  (import (rnrs)
          (only (chezscheme) system)
          (only (techo accounts) normalise-email username-problem)
          (only (techo passwords) prepare-password)
          (only (techo migrations) latest-version)
          (only (techo db) check-db)
          (only (techo transaction) write-start write-step)
          (only (techo doorway) doorway-set-up doorway-tear-down run-job!
                make-job-shell db-refused? db-refused-line db-unavailable?
                db-unavailable-reason db-unavailable-expected
                db-unavailable-found)
          (only (techo store) insert-account! account-by-username
                account-by-email account-id account-password-hash
                set-password-hash! revoke-all-keys!)
          (only (techo keys) id->string))

  ;;; The kit

  ;; UserKit : the database's path and migrations, the hash (a prepared
  ;; password to its hash), the wall clock (whole ms since 1970) and the id
  ;; source (a fresh 16-byte id).
  (define-record-type (user-kit %make-user-kit user-kit?)
    (fields path migrations hash clock new-id))

  ;; make-user-kit : String (Listof Migration) (String -> String) (-> Natural)
  ;;                 (-> Bytevector) -> UserKit
  (define (make-user-kit path migrations hash clock new-id)
    (%make-user-kit path migrations hash clock new-id))

  ;;; Reading the password

  ;; read-line : TextualInputPort -> (U String 'empty)
  ;; One line, with one trailing \r dropped. An empty line or the end of
  ;; the input is 'empty. Spaces are kept: they are part of a password.
  (define (read-line in)
    (let ((s (get-line in)))
      (if (eof-object? s)
          'empty
          (let* ((n (string-length s))
                 (s (if (and (> n 0) (char=? (string-ref s (- n 1)) #\return))
                        (substring s 0 (- n 1))
                        s)))
            (if (string=? s "") 'empty s)))))

  ;; say! : TextualOutputPort String -> Void      written and flushed at once
  (define (say! out text)
    (put-string out text)
    (flush-output-port out))

  ;; read-password : TextualInputPort TextualOutputPort Boolean (Boolean -> Boolean)
  ;;                 -> (U String 'empty 'mismatch 'no-echo)
  ;; IN, where the prompts go, whether IN is a terminal, and the echo
  ;; switch (#t on, #f off; it answers #t when the switch worked). Not a
  ;; terminal: one line, no prompt, no switch. A terminal: the echo off
  ;; FIRST; if that fails, nothing is prompted or read, and the answer is
  ;; 'no-echo. Else asked twice, a newline written after each answer (the
  ;; user's Enter was not echoed). Either way the echo is turned back on,
  ;; whatever happens. An empty first answer is 'empty and is not asked
  ;; again; a second that differs, none included, is 'mismatch.
  (define (read-password in out terminal? echo!)
    (if (not terminal?)
        (read-line in)
        (dynamic-wind
          (lambda () #f)
          (lambda ()
            (if (not (echo! #f))
                'no-echo
                (begin
                  (say! out "Password: ")
                  (let ((first (read-line in)))
                    (say! out "\n")
                    (if (eq? first 'empty)
                        'empty
                        (begin
                          (say! out "Again: ")
                          (let ((again (read-line in)))
                            (say! out "\n")
                            (if (equal? first again) first 'mismatch))))))))
          (lambda () (echo! #t)))))

  ;;; The lines

  (define (username-line problem)
    (case problem
      ((empty) "the username is empty")
      ((too-long) "the username is longer than 32 characters")
      ((bad-first-character)
       "the username must start with a lowercase letter or a digit")
      ((bad-character)
       "the username may hold only lowercase letters, digits, _ and -")
      (else "the username is not text")))

  (define email-line
    "the email is not valid: it needs one @ with text on each side, no spaces, and 254 bytes at most")

  ;; Never the password, nor its length.
  (define (password-line problem)
    (case problem
      ((empty) "no password was given")
      ((mismatch) "the two passwords do not match")
      ((no-echo) "cannot turn off the terminal's echo; pipe the password in instead")
      ((too-short) "the password is shorter than 8 characters")
      ((too-long) "the password is longer than 1,024 bytes")
      (else "the password is not text")))

  (define (unavailable-line e)
    (case (db-unavailable-reason e)
      ((busy) "the database is busy: another program holds it")
      ((moved)
       (string-append "the database changed under this command: it is at version "
                      (number->string (db-unavailable-found e))
                      " and this binary expects "
                      (number->string (db-unavailable-expected e))))
      (else "the database is unavailable")))

  ;; prepared : Any -> (U String Symbol)
  ;; The password to hash, or what is wrong with it.
  (define (prepared password)
    (if (memq password '(empty mismatch no-echo))
        password
        (prepare-password password)))

  ;; done, refused : String -> (values Natural (Listof String) (Listof String))
  (define (done line) (values 0 (list line) '()))
  (define (refused line) (values 1 '() (list line)))

  ;;; The one write

  ;; db-refusal : UserKit -> (U String #f)
  ;; check-db's line for a file it refuses, else #f.
  (define (db-refusal kit)
    (let ((verdict (check-db (user-kit-path kit) (user-kit-migrations kit))))
      (and (pair? verdict) (caddr verdict))))

  ;; one-write : UserKit String (String -> (Tx -> Any))
  ;;             -> (U (Pair 'refused String) (Pair 'answered Any))
  ;; Steps 2 to 4 of the header, and its refusals. MAKE-JOB is given the
  ;; hash once the file is open, and answers the job: the clock and the ids
  ;; are read then, so the job holds only plain data.
  (define (one-write kit password make-job)
    (let* ((path (user-kit-path kit))
           (ms (user-kit-migrations kit))
           (refusal (db-refusal kit)))
      (if refusal
          (cons 'refused refusal)
          (let ((hash ((user-kit-hash kit) password)))
            (guard (e ((db-refused? e) (cons 'refused (db-refused-line e)))
                      ((db-unavailable? e) (cons 'refused (unavailable-line e))))
              (let ((b (doorway-set-up path 'read-write ms)))
                (dynamic-wind
                  (lambda () #f)
                  (lambda ()
                    (let ((job (make-job hash)))
                      (let-values (((state command) (write-start (latest-version ms))))
                        (cons 'answered
                              (run-job! write-step state (make-job-shell b) job)))))
                  (lambda () (doorway-tear-down b)))))))))

  ;;; The commands

  ;; user-add! : UserKit String String (U String 'empty 'mismatch 'no-echo)
  ;;             -> (values Natural (Listof String) (Listof String))
  ;; The username, the email and the password as read: the exit status,
  ;; the lines for standard output and for standard error.
  (define (user-add! kit username email password)
    (let ((u (username-problem username))
          (e (normalise-email email))
          (p (prepared password)))
      (cond
        (u (refused (username-line u)))
        ((not e) (refused email-line))
        ((symbol? p) (refused (password-line p)))
        (else
         (let ((r (one-write kit p
                    (lambda (hash)
                      (let* ((now ((user-kit-clock kit)))
                             (id ((user-kit-new-id kit))))
                        (lambda (tx)
                          (cond ((account-by-username tx username) 'username-taken)
                                ((account-by-email tx e) 'email-taken)
                                (else (insert-account! tx id username e hash now)
                                      id))))))))
           (cond ((eq? (car r) 'refused) (refused (cdr r)))
                 ((eq? (cdr r) 'username-taken)
                  (refused (string-append "the username " username " is taken")))
                 ((eq? (cdr r) 'email-taken)
                  (refused (string-append "the email " e " is taken")))
                 (else
                  (done (string-append "added " username " " e " "
                                       (id->string (cdr r)))))))))))

  ;; user-password! : UserKit String (U String 'empty 'mismatch 'no-echo)
  ;;                  -> (values Natural (Listof String) (Listof String))
  ;; The email and the password as read. Sets the account's hash and
  ;; revokes each of its active keys, in the one transaction.
  (define (user-password! kit email password)
    (let ((e (normalise-email email))
          (p (prepared password)))
      (cond
        ((not e) (refused email-line))
        ((symbol? p) (refused (password-line p)))
        (else
         (let ((r (one-write kit p
                    (lambda (hash)
                      (let ((now ((user-kit-clock kit))))
                        (lambda (tx)
                          (let ((a (account-by-email tx e)))
                            (cond
                              ((not a) 'no-account)
                              ((set-password-hash! tx (account-id a)
                                                   (account-password-hash a) hash)
                               (revoke-all-keys! tx (account-id a) now))
                              (else
                               ;; the hash was read in this transaction
                               (assertion-violation 'user-password!
                                 "the account's hash changed inside the transaction"))))))))))
           (cond ((eq? (car r) 'refused) (refused (cdr r)))
                 ((eq? (cdr r) 'no-account)
                  (refused (string-append "no account has the email " e)))
                 (else
                  (let ((n (cdr r)))
                    (done (string-append "password set for " e "; "
                                         (number->string n)
                                         (if (= n 1) " key revoked" " keys revoked")))))))))))

  ;;; The real terminal
  ;;
  ;; These two read the process's own standard input and print. Each
  ;; refuses a bad argument, then a file check-db refuses, before it reads
  ;; the password. CI cannot run the terminal path: its container has no
  ;; terminal. It is tried by hand.

  ;; user-add-command! : UserKit String String -> Natural
  (define (user-add-command! kit username email)
    (let ((early (or (let ((u (username-problem username))) (and u (username-line u)))
                     (and (not (normalise-email email)) email-line)
                     (db-refusal kit))))
      (if early
          (begin (print-lines! '() (list early)) 1)
          (let-values (((status out err)
                        (user-add! kit username email (password-from-stdin))))
            (print-lines! out err)
            status))))

  ;; user-password-command! : UserKit String -> Natural
  (define (user-password-command! kit email)
    (let ((early (or (and (not (normalise-email email)) email-line)
                     (db-refusal kit))))
      (if early
          (begin (print-lines! '() (list early)) 1)
          (let-values (((status out err)
                        (user-password! kit email (password-from-stdin))))
            (print-lines! out err)
            status))))

  ;; password-from-stdin : -> (U String 'empty 'mismatch 'no-echo)
  ;; Prompts on standard error; `stty` switches the terminal's echo, and
  ;; its exit status says whether that worked.
  (define (password-from-stdin)
    (read-password (current-input-port) (current-error-port)
                   (zero? (system "test -t 0"))
                   (lambda (on?) (zero? (system (if on? "stty echo" "stty -echo"))))))

  ;; print-lines! : (Listof String) (Listof String) -> Void
  ;; Each line is one write; standard error's start with "techo: ".
  (define (print-lines! out err)
    (for-each (lambda (l) (say! (current-output-port) (string-append l "\n"))) out)
    (for-each (lambda (l) (say! (current-error-port) (string-append "techo: " l "\n")))
              err))
)
