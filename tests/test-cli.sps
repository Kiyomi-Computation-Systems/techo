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

(test-equal "usage-text lists serve on a line of its own"
  #t
  (attempt (lambda () (and (exists (lambda (l) (contains? l "serve")) (lines usage-text)) #t))))

(test-equal "usage-text lists version on a line of its own"
  #t
  (attempt (lambda () (and (exists (lambda (l) (contains? l "version")) (lines usage-text)) #t))))

(test-equal "usage-text: serve and version are different lines"
  #t
  (attempt
   (lambda ()
     (let ((ls (lines usage-text)))
       (not (exists (lambda (l) (and (contains? l "serve") (contains? l "version"))) ls))))))

(test-end "cli")

(exit (suite-exit-status runner))
