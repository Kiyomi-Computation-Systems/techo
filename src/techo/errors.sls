#!r6rs
;;; (techo errors): D7's table of error codes, each one's status and message,
;;; the &refusal condition, and the answer in RFC 9457's format made from
;;; them. A response is data: nothing here reads a request, a clock or the
;;; database. Pure (ADR-0007).
;;;
;;;   error-codes         every code, in the table's order
;;;   error-status        a code's HTTP status
;;;   error-message       a code's message, one plain sentence
;;;   status->code        the code a bare status gets
;;;   &refusal            a refusal: a code and the account it concerns
;;;   status-phrase       an error status's standard phrase (slice 3a, task 3)
;;;   problem-res         a code's answer in the format (task 3)
;;;   status-problem-res  a bare status's answer in the format (task 3)
(library (techo errors)
  (export error-codes error-status error-message status->code
          &refusal make-refusal refusal? refusal-code refusal-account
          status-phrase problem-res status-problem-res)
  (import (rnrs)
          (only (circuit) make-res res-body header-value header-remove)
          (only (circuit json) make-json-res))

  ;; table : (Listof (List Symbol (U Natural #f) String))
  ;; Code, status, message. `error` is the fallback and has no fixed status.
  (define table
    '((invalid_json 400 "The request body is not valid JSON.")
      (invalid_request 400 "The request is not valid.")
      (unauthorized 401 "A valid API key is needed.")
      (invalid_credentials 401 "The email or password is wrong.")
      (forbidden 403 "A key can only regenerate itself.")
      (not_found 404 "There is no such thing here.")
      (method_not_allowed 405 "That method is not allowed here.")
      (too_many_keys 409 "This account has 100 active keys; revoke one first.")
      (kind_fixed 409 "A node's kind cannot be changed.")
      (precondition_failed 412 "The node has changed or already exists; read it again.")
      (payload_too_large 413 "The request body is too large.")
      (unsupported_media_type 415 "The request body must be application/json.")
      (precondition_required 428 "A write needs If-Match, or If-None-Match: * to create.")
      (rate_limited 429 "Too many login attempts; try again later.")
      (internal 500 "Something went wrong on the server.")
      (unavailable 503 "The service is busy or not ready; try again soon.")
      (timeout 504 "The request took too long.")
      (error #f "The request could not be completed.")))

  ;; error-codes : (Listof Symbol)
  (define error-codes (map car table))

  ;; entry : Symbol Any -> (List Symbol (U Natural #f) String)
  (define (entry who code)
    (let ((e (and (symbol? code) (assq code table))))
      (unless e (assertion-violation who "not an error code" code))
      e))

  ;; error-status : Symbol -> (U Natural #f)
  ;; The code's HTTP status; #f for `error`, which has none. An assertion
  ;; violation for an unknown code.
  (define (error-status code) (cadr (entry 'error-status code)))

  ;; error-message : Symbol -> String
  ;; An assertion violation for an unknown code.
  (define (error-message code) (caddr (entry 'error-message code)))

  ;; status->code : Natural -> Symbol
  ;; The code a bare status gets: 400 is invalid_request (invalid_json is
  ;; a handler's own choice); 401, 403, 404, 405, 412, 413, 415, 428, 500,
  ;; 503 and 504 are theirs; any other is `error`. invalid_credentials,
  ;; too_many_keys, kind_fixed and rate_limited are a handler's own choice,
  ;; like invalid_json: a bare 401, 409 or 429 never gets them.
  (define (status->code status)
    (case status
      ((400) 'invalid_request)
      ((401) 'unauthorized)
      ((403) 'forbidden)
      ((404) 'not_found)
      ((405) 'method_not_allowed)
      ((412) 'precondition_failed)
      ((413) 'payload_too_large)
      ((415) 'unsupported_media_type)
      ((428) 'precondition_required)
      ((500) 'internal)
      ((503) 'unavailable)
      ((504) 'timeout)
      (else 'error)))

  ;; &refusal : a condition type with fields code and account. It carries no
  ;; message and no irritants: nothing of a request may ride on it.
  (define-condition-type &refusal &condition
    make-refusal-condition refusal?
    (code refusal-code)
    (account refusal-account))

  ;; make-refusal : Symbol (U Bytevector #f) -> &refusal
  ;; CODE is one of error-codes; ACCOUNT is a 16-byte bytevector or #f.
  ;; An assertion violation for an unknown code or a bad account.
  ;; refusal? : Any -> Boolean
  ;; refusal-code : &refusal -> Symbol
  ;; refusal-account : &refusal -> (U Bytevector #f)
  (define (make-refusal code account)
    (entry 'make-refusal code)
    (unless (or (not account)
                (and (bytevector? account) (= (bytevector-length account) 16)))
      (assertion-violation 'make-refusal "account must be #f or 16 bytes"))
    (make-refusal-condition code account))

;;; The answer in the format (D7, RFC 9457)

  ;; phrases : (Listof (Pair Natural String))
  ;; RFC 9110 section 15's reason phrases for 4xx and 5xx, and RFC 6585's
  ;; for 428, 429, 431 and 511: chez-http-server's own table, so a body's
  ;; title is the status line's phrase.
  (define phrases
    '((400 . "Bad Request") (401 . "Unauthorized") (402 . "Payment Required")
      (403 . "Forbidden") (404 . "Not Found") (405 . "Method Not Allowed")
      (406 . "Not Acceptable") (407 . "Proxy Authentication Required")
      (408 . "Request Timeout") (409 . "Conflict") (410 . "Gone")
      (411 . "Length Required") (412 . "Precondition Failed")
      (413 . "Content Too Large") (414 . "URI Too Long")
      (415 . "Unsupported Media Type") (416 . "Range Not Satisfiable")
      (417 . "Expectation Failed") (421 . "Misdirected Request")
      (422 . "Unprocessable Content") (426 . "Upgrade Required")
      (428 . "Precondition Required") (429 . "Too Many Requests")
      (431 . "Request Header Fields Too Large")
      (500 . "Internal Server Error") (501 . "Not Implemented")
      (502 . "Bad Gateway") (503 . "Service Unavailable")
      (504 . "Gateway Timeout") (505 . "HTTP Version Not Supported")
      (511 . "Network Authentication Required")))

  ;; status-phrase : Natural -> String
  ;; The standard phrase of an error status, 400 to 599. One with none of
  ;; its own is "Client Error" (4xx) or "Server Error" (5xx). Anything else
  ;; is an assertion violation.
  (define (status-phrase status)
    (unless (and (integer? status) (exact? status) (<= 400 status 599))
      (assertion-violation 'status-phrase "an error status is a whole number from 400 to 599"
                           status))
    (cond ((assv status phrases) => cdr)
          ((< status 500) "Client Error")
          (else "Server Error")))

  ;; problem : Symbol Natural Symbol Headers -> Res
  ;; STATUS with content-type application/problem+json first, then HEADERS
  ;; less any content-type and content-length, then, for a 401 that has
  ;; none, www-authenticate: Bearer. The body is RFC 9457's members in its
  ;; order, and Techo's `code`.
  (define (problem who status code headers)
    (unless (and (list? headers)
                 (for-all (lambda (h) (and (pair? h) (string? (car h)) (string? (cdr h))))
                          headers))
      (assertion-violation who "headers are a list of string pairs" headers))
    (let* ((kept (header-remove (header-remove headers "content-type") "content-length"))
           (kept (if (and (= status 401) (not (header-value kept "www-authenticate")))
                     (append kept (list (cons "www-authenticate" "Bearer")))
                     kept)))
      (make-res status
                (cons (cons "content-type" "application/problem+json") kept)
                (res-body
                 (make-json-res status
                                (list (cons "type" "about:blank")
                                      (cons "title" (status-phrase status))
                                      (cons "status" status)
                                      (cons "code" (symbol->string code))
                                      (cons "detail" (error-message code))))))))

  ;; problem-res : Symbol [Headers] -> Res
  ;; CODE's answer in the format, at CODE's status: content-type
  ;; application/problem+json, HEADERS ('() unless given) less their
  ;; content-type and content-length, and www-authenticate: Bearer on a 401
  ;; that has none. The body is
  ;;   {"type":"about:blank","title":<the status's phrase>,"status":<n>,
  ;;    "code":<code>,"detail":<the code's message>}
  ;; `error`, which has no status, an unknown code and headers that are no
  ;; list of string pairs are assertion violations.
  (define problem-res
    (case-lambda
      ((code) (problem-res code '()))
      ((code headers)
       (let ((status (error-status code)))
         (unless status
           (assertion-violation 'problem-res
                                "`error` has no status of its own: use status-problem-res" code))
         (problem 'problem-res status code headers)))))

  ;; status-problem-res : Natural [Headers] -> Res
  ;; The answer in the format for a bare STATUS, 400 to 599: status->code's
  ;; code for it, `error` where it has none, at STATUS itself; HEADERS as
  ;; problem-res takes them. A status outside 400 to 599 is an assertion
  ;; violation.
  (define status-problem-res
    (case-lambda
      ((status) (status-problem-res status '()))
      ((status headers)
       (status-phrase status)
       (problem 'status-problem-res status (status->code status) headers))))
)
