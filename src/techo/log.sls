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
;;; deadline can end later than the line is written. A login writes them a
;;; piece at a time, note-account! and note-add-db-ms!: its db_ms is the
;;; sum of its two jobs.
;;;
;;; Never on the line: a query string, a header, a body. The method, the path
;;; and the address have each control character made a space. A field with
;;; nothing to show is `-`.
(library (techo log)
  (export wrap-request-log request-line
          note-request! note-account! note-add-db-ms!
          req-note note? note-account note-db-ms)
  (import (rnrs)
          (only (chezscheme) real-time)
          (only (circuit) make-req-key req-ref req-set req-method req-path
                req-remote-address req-header-values req-on-done! res? res-status)
          (only (techo address) client-address)
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

  ;; note-account! : Req (U Bytevector #f) -> Void
  ;; Writes ACCOUNT into REQ's note and leaves its db_ms. For login, whose
  ;; account is known once the password matched, between its two jobs. A
  ;; request with no note is left as it is. On the loop's thread only.
  (define (note-account! req account)
    (let ((n (req-note req)))
      (when n (note-account-set! n account))))

  ;; note-add-db-ms! : Req Integer -> Void
  ;; Adds MS to REQ's note's db_ms (none yet counts as 0) and leaves its
  ;; account: a login's db_ms is the sum of its jobs. A request with no
  ;; note is left as it is. On the loop's thread only.
  (define (note-add-db-ms! req ms)
    (let ((n (req-note req)))
      (when n (note-db-ms-set! n (+ (or (note-db-ms n) 0) ms)))))

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

  ;; wrap-request-log : (String -> Void) [(-> Integer) [Natural]] -> Middleware
  ;; Each request gets a fresh note, then its handler is called with it.
  ;; When the response ends, WRITE-LINE is called once with the request's
  ;; line: the method, the path (req-path, never the query), the status the
  ;; handler answered (- when it raised, or answered no response), the
  ;; ending, CLOCK's reading then less its reading when the request came,
  ;; the note's db_ms and account, and the client's address. CLOCK reads
  ;; milliseconds; real-time by default. PROXIES is how many proxies stand
  ;; in front (TECHO_BEHIND_PROXY), 0 by default: the address is then
  ;; (techo address)'s client-address, the Nth from the end of
  ;; X-Forwarded-For when that is an address, else the peer's, as the login
  ;; limit takes it. The middleware catches nothing: a raise goes on as it
  ;; was raised. A WRITE-LINE or CLOCK that is no procedure, or a PROXIES
  ;; that is no whole number from 0, is an assertion violation, raised now.
  (define wrap-request-log
    (case-lambda
      ((write-line) (wrap-request-log write-line real-time 0))
      ((write-line clock) (wrap-request-log write-line clock 0))
      ((write-line clock proxies)
       (unless (procedure? write-line)
         (assertion-violation 'wrap-request-log "the line writer is a procedure of a string"
                              write-line))
       (unless (procedure? clock)
         (assertion-violation 'wrap-request-log "the clock is a procedure of no arguments" clock))
       (unless (and (integer? proxies) (exact? proxies) (>= proxies 0))
         (assertion-violation 'wrap-request-log "the proxy count is a whole number" proxies))
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
                                            (client-address
                                             proxies
                                             (req-header-values req "x-forwarded-for")
                                             (req-remote-address req))))))
             (let ((answer (handler req)))
               (set! status (and (res? answer) (res-status answer)))
               answer)))))))
)
