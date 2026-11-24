#!r6rs
;;; (techo log): the request log, D10's line, and the note a request carries
;;; to it. The imperative shell.
;;;
;;;   request method=GET path=/v1/keys status=200 ending=written ms=4 db_ms=1 account=0193... address=203.0.113.9
;;;
;;; wrap-request-log puts a note on each request, a mutable record shared by
;;; every copy of the request, and writes one line when the response ends,
;;; from the loop's thread (req-on-done!). (techo auth) writes the account and
;;; the database's time into the note with note-request!, on the loop's
;;; thread, from what a job returned: never from inside a job, which after a
;;; deadline can end later than the line is written.
;;;
;;; Never on the line: a query string, a header, a body. The method, the path
;;; and the address have each control character made a space. A field with
;;; nothing to show is `-`.
(library (techo log)
  (export wrap-request-log request-line
          note-request! req-note note? note-account note-db-ms)
  (import (rnrs)
          (only (chezscheme) real-time)
          (only (circuit) make-req-key req-ref req-set req-method req-path
                req-remote-address req-on-done! res? res-status)
          (only (techo keys) id->string))

  ;; Note : the account the request was made for, and the milliseconds its
  ;; job took, each #f until (techo auth) writes it.
  ;; note? : Any -> Boolean
  ;; note-account : Note -> (U Bytevector #f)
  ;; note-db-ms : Note -> (U Integer #f)
  (define-record-type (note make-note note?)
    (fields (mutable account note-account note-account-set!)
            (mutable db-ms note-db-ms note-db-ms-set!)))

  (define note-key (make-req-key 'techo-request-note))

  ;; req-note : Req -> (U Note #f)
  ;; The note wrap-request-log put on REQ, or one of its copies; #f outside
  ;; the middleware.
  (define (req-note req) (req-ref req note-key #f))

  ;; note-request! : Req (U Bytevector #f) (U Integer #f) -> Void
  ;; Writes ACCOUNT (a 16-byte id, or #f for none known) and DB-MS into
  ;; REQ's note. A request with no note is left as it is. Called on the
  ;; loop's thread only.
  (define (note-request! req account db-ms)
    (let ((n (req-note req)))
      (when n
        (note-account-set! n account)
        (note-db-ms-set! n db-ms))))

  ;; line-char : Char -> Char
  ;; A space for a control character (below U+0020, and U+007F), else C.
  (define (line-char c)
    (if (or (char<? c #\space) (char=? c #\delete)) #\space c))

  ;; field : (U String #f) -> String
  ;; S with its control characters made spaces; - for #f or "".
  (define (field s)
    (if (and s (> (string-length s) 0))
        (list->string (map line-char (string->list s)))
        "-"))

  ;; number-field : (U Integer #f) -> String
  (define (number-field n) (if n (number->string n) "-"))

  ;; request-line : Symbol String (U Integer #f) Symbol Integer (U Integer #f)
  ;;                (U Bytevector #f) (U String #f) -> String
  ;; METHOD, PATH (with no query), STATUS, ENDING, MS, DB-MS, ACCOUNT and
  ;; ADDRESS as D10's one line, with no newline. Pure.
  (define (request-line method path status ending ms db-ms account address)
    (string-append "request method=" (field (symbol->string method))
                   " path=" (field path)
                   " status=" (number-field status)
                   " ending=" (symbol->string ending)
                   " ms=" (number->string ms)
                   " db_ms=" (number-field db-ms)
                   " account=" (if account (id->string account) "-")
                   " address=" (field address)))

  ;; wrap-request-log : (String -> Void) [(-> Integer)] -> Middleware
  ;; Each request gets a fresh note, then its handler is called with it.
  ;; When the response ends, WRITE-LINE is called once with the request's
  ;; line: the method, the path (req-path, never the query), the status the
  ;; handler answered (- when it raised, or answered no response), the
  ;; ending, CLOCK's reading then less its reading when the request came,
  ;; the note's db_ms and account, and req-remote-address. CLOCK reads
  ;; milliseconds; real-time by default. The middleware catches nothing: a
  ;; raise goes on as it was raised. A WRITE-LINE or CLOCK that is no
  ;; procedure is an assertion violation, raised now.
  (define wrap-request-log
    (case-lambda
      ((write-line) (wrap-request-log write-line real-time))
      ((write-line clock)
       (unless (procedure? write-line)
         (assertion-violation 'wrap-request-log "the line writer is a procedure of a string"
                              write-line))
       (unless (procedure? clock)
         (assertion-violation 'wrap-request-log "the clock is a procedure of no arguments" clock))
       (lambda (handler)
         (unless (procedure? handler)
           (assertion-violation 'wrap-request-log "a handler is a procedure" handler))
         (lambda (req)
           (let* ((n (make-note #f #f))
                  (req (req-set req note-key n))
                  (start (clock))
                  (status #f))
             (req-on-done! req
                           (lambda (ending)
                             (write-line
                              (request-line (req-method req) (req-path req) status ending
                                            (- (clock) start) (note-db-ms n) (note-account n)
                                            (req-remote-address req)))))
             (let ((answer (handler req)))
               (set! status (and (res? answer) (res-status answer)))
               answer)))))))
)
