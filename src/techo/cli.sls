#!r6rs
;;; (techo cli): the program's arguments, parsed into a command. Pure.
;;;
;;; The parser is a table of (word . command) rows; a later slice's
;;; sub-command is one more row.
(library (techo cli)
  (export parse-command usage-text)
  (import (rnrs))

  ;; commands : (Listof (Pairof String Symbol))
  (define commands
    '(("serve" . serve)
      ("migrate" . migrate)
      ("version" . version)))

  ;; usage-text : String
  ;; The commands, one per line.
  (define usage-text
    (string-append
     "usage: techo COMMAND\n"
     "\n"
     "commands:\n"
     "  serve     run the server\n"
     "  migrate   create or update the database; stop the server first\n"
     "  version   print the version\n"
     "  user add --username NAME --email EMAIL   make an account\n"
     "  user password --email EMAIL   set an account's password, revoke its keys\n"
     "\n"
     "user commands read the password from standard input, never the command line.\n"))

  ;; user-commands : (Listof (List String Symbol (Listof String)))
  ;; The word, the command it makes and its options, in the order they are
  ;; handed to the command.
  (define user-commands
    '(("add" user-add ("--username" "--email"))
      ("password" user-password ("--email"))))

  ;; parse-user : (Listof String) -> (U Command-user (List 'usage String))
  ;; ARGS are the arguments after `user`.
  (define (parse-user args)
    (cond
      ((null? args) (list 'usage "no user command given"))
      ((assoc (car args) user-commands)
       => (lambda (row)
            (parse-options (car row) (cadr row) (caddr row) (cdr args) '())))
      (else (list 'usage (string-append "unknown user command: " (car args))))))

  ;; parse-options : String Symbol (Listof String) (Listof String)
  ;;                 (Listof (Pairof String String)) -> (U Command (List 'usage String))
  ;; Reads `--option value` pairs from ARGS into FOUND, then hands the values
  ;; to the command in the order of WANTED.
  (define (parse-options word command wanted args found)
    (define (usage . parts) (list 'usage (apply string-append parts)))
    (cond
      ((null? args)
       (let ((missing (filter (lambda (o) (not (assoc o found))) wanted)))
         (if (pair? missing)
             (usage "user " word " needs " (car missing))
             (cons command (map (lambda (o) (cdr (assoc o found))) wanted)))))
      ((not (member (car args) wanted))
       (if (and (positive? (string-length (car args)))
                (char=? (string-ref (car args) 0) #\-))
           (usage "unknown option for user " word ": " (car args))
           (usage "unexpected argument for user " word ": " (car args))))
      ((null? (cdr args))
       (usage "user " word ": " (car args) " needs a value"))
      ((assoc (car args) found)
       (usage "user " word ": " (car args) " given twice"))
      (else
       (parse-options word command wanted (cddr args)
                      (cons (cons (car args) (cadr args)) found)))))

  ;; parse-command : (Listof String) -> Command
  ;; ARGS are the arguments after the program's name.
  ;; Command is (U 'serve 'migrate 'version (List 'user-add String String)
  ;;                (List 'user-password String) (List 'usage String))
  ;; The words after `user` are options in any order, each needed once; their
  ;; values are passed through unjudged. There is no password option.
  (define (parse-command args)
    (cond
      ((null? args) (list 'usage "no command given"))
      ((string=? (car args) "user") (parse-user (cdr args)))
      ((member (car args) '("--help" "help")) (list 'usage ""))
      ((assoc (car args) commands)
       => (lambda (row)
            (if (null? (cdr args))
                (cdr row)
                (list 'usage
                      (string-append "unexpected argument after "
                                     (car args) ": " (cadr args))))))
      (else (list 'usage (string-append "unknown command: " (car args))))))
)
