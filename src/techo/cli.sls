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
      ("version" . version)))

  ;; usage-text : String
  ;; The commands, one per line.
  (define usage-text
    (string-append
     "usage: techo COMMAND\n"
     "\n"
     "commands:\n"
     "  serve     run the server\n"
     "  version   print the version\n"))

  ;; parse-command : (Listof String) -> Command
  ;; ARGS are the arguments after the program's name.
  ;; Command is (U 'serve 'version (List 'usage String))
  (define (parse-command args)
    (cond
      ((null? args) (list 'usage "no command given"))
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
