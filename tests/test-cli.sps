#!r6rs
;;; The cli suite: (techo cli) turns the arguments after the program's name
;;; into a command, or into a usage line saying what was wrong.
;;;
;;; Everything that can raise is computed under a guard, and a raise comes
;;; out as a sentinel the expected value never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (techo cli))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; parse : (Listof String) -> (U Command (List 'raised String))
(define (parse args) (attempt (lambda () (parse-command args))))

;; usage-message : (Listof String) -> (U String 'not-usage (List 'raised String))
(define (usage-message args)
  (let ((c (parse args)))
    (if (and (pair? c) (eq? (car c) 'usage) (pair? (cdr c)) (string? (cadr c)))
        (cadr c)
        'not-usage)))

;; contains? : String String -> Boolean
(define (contains? s sub)
  (let ((n (string-length s)) (m (string-length sub)))
    (let loop ((i 0))
      (cond ((> (+ i m) n) #f)
            ((string=? (substring s i (+ i m)) sub) #t)
            (else (loop (+ i 1)))))))

;; lines : String -> (Listof String)
(define (lines s)
  (let loop ((cs (string->list s)) (cur '()) (acc '()))
    (cond ((null? cs) (reverse (if (null? cur) acc (cons (list->string (reverse cur)) acc))))
          ((char=? (car cs) #\newline) (loop (cdr cs) '() (cons (list->string (reverse cur)) acc)))
          (else (loop (cdr cs) (cons (car cs) cur) acc)))))

(test-begin "cli")

(test-equal "serve parses to serve" 'serve (parse '("serve")))
(test-equal "version parses to version" 'version (parse '("version")))
(test-equal "migrate parses to migrate" 'migrate (parse '("migrate")))

(test-equal "extra arguments after migrate: usage naming the extra word"
  #t
  (let ((m (usage-message '("migrate" "x"))))
    (and (string? m) (contains? m "x"))))

(test-equal "migrate x: a usage form"
  'usage
  (let ((c (parse '("migrate" "x")))) (and (pair? c) (car c))))

(test-equal "no arguments: usage with a message"
  #t
  (let ((m (usage-message '()))) (and (string? m) (> (string-length m) 0))))

(test-equal "no arguments: is a usage form"
  'usage
  (let ((c (parse '()))) (and (pair? c) (car c))))

(test-equal "unknown command: usage naming the word"
  #t
  (let ((m (usage-message '("frobnicate"))))
    (and (string? m) (contains? m "frobnicate"))))

(test-equal "unknown command: the message is one line"
  '(#t)
  (let ((m (usage-message '("frobnicate"))))
    (list (and (string? m) (= (length (lines m)) 1)))))

(test-equal "extra arguments after serve: usage naming the extra word"
  #t
  (let ((m (usage-message '("serve" "--port"))))
    (and (string? m) (contains? m "--port"))))

(test-equal "extra arguments after version: usage naming the extra word"
  #t
  (let ((m (usage-message '("version" "now"))))
    (and (string? m) (contains? m "now"))))

(test-equal "--help: usage with an empty message"
  '(usage "")
  (parse '("--help")))

(test-equal "help: usage with an empty message"
  '(usage "")
  (parse '("help")))

(test-equal "a command is matched exactly, not by prefix"
  #t
  (let ((m (usage-message '("serv")))) (and (string? m) (contains? m "serv"))))

(test-equal "a command is case-sensitive"
  #t
  (let ((m (usage-message '("SERVE")))) (string? m)))

(test-equal "usage-text is a string"
  #t
  (attempt (lambda () (string? usage-text))))

;; starts-with? : String String -> Boolean
(define (starts-with? s prefix)
  (and (>= (string-length s) (string-length prefix))
       (string=? (substring s 0 (string-length prefix)) prefix)))

;; line-for : String -> (U String #f)
;; The usage line that BEGINS with "  WORD " (the command's own line), not one
;; that merely mentions the word.
(define (line-for word)
  (let ((hits (filter (lambda (l) (starts-with? l (string-append "  " word " ")))
                      (lines usage-text))))
    (and (= (length hits) 1) (car hits))))

(test-equal "usage-text has one line that begins with the serve command"
  #t
  (attempt (lambda () (and (line-for "serve") #t))))

(test-equal "usage-text has one line that begins with the version command"
  #t
  (attempt (lambda () (and (line-for "version") #t))))

(test-equal "usage-text has one line that begins with the migrate command"
  #t
  (attempt (lambda () (and (line-for "migrate") #t))))

(test-equal "usage-text: serve and version are different lines"
  #t
  (attempt (lambda () (not (equal? (line-for "serve") (line-for "version"))))))

(test-equal "usage-text: the serve line does not mention the other commands"
  #f
  (attempt (lambda ()
             (let ((l (line-for "serve")))
               (or (not l) (contains? l "migrate") (contains? l "version"))))))

(test-equal "usage-text: the migrate line tells you to stop the server first (D6)"
  #t
  (attempt (lambda ()
             (let ((l (line-for "migrate")))
               (and l (contains? l "stop the server first"))))))

(test-equal "usage-text: the migrate line is one short line"
  #t
  (attempt (lambda ()
             (let ((l (line-for "migrate")))
               (and l (< (string-length l) 80))))))

;;; techo user

(test-equal "user add: the options in one order"
  '(user-add "ann" "a@example.com")
  (parse '("user" "add" "--username" "ann" "--email" "a@example.com")))
(test-equal "user add: the options in the other order"
  '(user-add "ann" "a@example.com")
  (parse '("user" "add" "--email" "a@example.com" "--username" "ann")))
(test-equal "user password: parses"
  '(user-password "a@example.com")
  (parse '("user" "password" "--email" "a@example.com")))

(test-equal "user add: any string is passed through, even an odd one"
  '(user-add "" "not an email")
  (parse '("user" "add" "--username" "" "--email" "not an email")))
(test-equal "user add: a value that starts with - follows its option"
  '(user-add "-x" "--username")
  (parse '("user" "add" "--username" "-x" "--email" "--username")))
(test-equal "user password: a value that starts with - follows its option"
  '(user-password "--email")
  (parse '("user" "password" "--email" "--email")))

(test-equal "user add: no username"
  '(usage "user add needs --username")
  (parse '("user" "add" "--email" "a@b")))
(test-equal "user add: no email"
  '(usage "user add needs --email")
  (parse '("user" "add" "--username" "ann")))
(test-equal "user add: no options at all names the first one missing"
  '(usage "user add needs --username")
  (parse '("user" "add")))
(test-equal "user password: no email"
  '(usage "user password needs --email")
  (parse '("user" "password")))
(test-equal "user add: a repeated option"
  '(usage "user add: --username given twice")
  (parse '("user" "add" "--username" "a" "--email" "b" "--username" "c")))
(test-equal "user password: a repeated option"
  '(usage "user password: --email given twice")
  (parse '("user" "password" "--email" "a" "--email" "a")))
(test-equal "user add: an unknown option"
  '(usage "unknown option for user add: --foo")
  (parse '("user" "add" "--username" "a" "--email" "b" "--foo" "c")))
(test-equal "user password: --username is unknown there"
  '(usage "unknown option for user password: --username")
  (parse '("user" "password" "--username" "a" "--email" "b")))
(test-equal "user add: --password is an unknown option"
  '(usage "unknown option for user add: --password")
  (parse '("user" "add" "--username" "a" "--email" "b" "--password" "hunter2")))
(test-equal "user password: --password is an unknown option"
  '(usage "unknown option for user password: --password")
  (parse '("user" "password" "--password" "hunter2" "--email" "b")))
(test-equal "user add: an option with no value at the end"
  '(usage "user add: --email needs a value")
  (parse '("user" "add" "--username" "a" "--email")))
(test-equal "user password: an option with no value"
  '(usage "user password: --email needs a value")
  (parse '("user" "password" "--email")))
(test-equal "user add: a stray argument"
  '(usage "unexpected argument for user add: stray")
  (parse '("user" "add" "stray" "--username" "a" "--email" "b")))
(test-equal "user add: a stray argument at the end"
  '(usage "unexpected argument for user add: stray")
  (parse '("user" "add" "--username" "a" "--email" "b" "stray")))
(test-equal "user: alone"
  '(usage "no user command given")
  (parse '("user")))
(test-equal "user: an unknown word"
  '(usage "unknown user command: foo")
  (parse '("user" "foo")))
(test-equal "user: a command is case-sensitive"
  '(usage "unknown user command: Add")
  (parse '("user" "Add" "--username" "a" "--email" "b")))

(test-equal "usage-text: the user add line names its options and is short"
  #t
  (attempt (lambda ()
             (let ((l (line-for "user add")))
               (and l (contains? l "--username") (contains? l "--email")
                    (< (string-length l) 80))))))
(test-equal "usage-text: the user password line names its option and is short"
  #t
  (attempt (lambda ()
             (let ((l (line-for "user password")))
               (and l (contains? l "--email") (not (contains? l "--password"))
                    (< (string-length l) 80))))))
(test-equal "usage-text: says the password is read from standard input"
  #t
  (attempt (lambda () (contains? usage-text "standard input"))))

(test-end "cli")

(exit (suite-exit-status runner))
