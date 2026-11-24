#!r6rs
;;; The errors suite: D7's table of codes, each one's status and message,
;;; the &refusal condition, and the answer in RFC 9457's format that
;;; problem-res and status-problem-res make (slice 3a, task 3). A body is
;;; parsed with jsonparse and compared as a value, never as a string.
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (circuit)
        (circuit test)
        (jsonparse easy)
        (techo errors))

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

(define (last-char s) (string-ref s (- (string-length s) 1)))

(test-begin "errors")

(test-equal "codes: the twelve of 3a, in order"
  '(invalid_json invalid_request unauthorized forbidden not_found
    method_not_allowed payload_too_large unsupported_media_type
    internal unavailable timeout error)
  error-codes)

(test-assert "codes: no two share a name"
  (let loop ((l error-codes))
    (or (null? l) (and (not (memq (car l) (cdr l))) (loop (cdr l))))))

(define fixed (filter (lambda (c) (not (eq? c 'error))) error-codes))

(test-assert "status: every fixed code has one in 400 to 599"
  (for-all (lambda (c) (let ((s (attempt (lambda () (error-status c)))))
                         (and (integer? s) (<= 400 s 599))))
           fixed))

(test-equal "status: the table, code by code"
  '(400 400 401 403 404 405 413 415 500 503 504)
  (attempt (lambda () (map error-status fixed))))

(test-equal "status: the fallback has none" #f (attempt (lambda () (error-status 'error))))

(test-assert "message: every code has a non-empty sentence ending in a full stop"
  (for-all (lambda (c) (let ((m (attempt (lambda () (error-message c)))))
                         (and (string? m) (> (string-length m) 1)
                              (char=? (last-char m) #\.))))
           error-codes))

(test-assert "message: no two codes share one"
  (let ((ms (map error-message error-codes)))
    (let loop ((l ms))
      (or (null? l) (and (not (member (car l) (cdr l))) (loop (cdr l)))))))

(test-equal "status: unknown code raises" 'assertion
  (raised-kind (lambda () (error-status 'nope))))
(test-equal "message: unknown code raises" 'assertion
  (raised-kind (lambda () (error-message 'nope))))
(test-equal "message: a non-symbol raises" 'assertion
  (raised-kind (lambda () (error-message "forbidden"))))

;;; status->code

(test-equal "status->code: each code's status gets the code, but invalid_json shares 400"
  '(invalid_request invalid_request unauthorized forbidden not_found
    method_not_allowed payload_too_large unsupported_media_type
    internal unavailable timeout)
  (attempt (lambda () (map (lambda (c) (status->code (error-status c))) fixed))))

(test-equal "status->code: 400 is invalid_request" 'invalid_request (status->code 400))
(test-equal "status->code: 418 is error" 'error (status->code 418))
(test-equal "status->code: 599 is error" 'error (status->code 599))
(test-equal "status->code: 200 is error" 'error (status->code 200))
(test-equal "status->code: 409 is error (3b's code, not 3a's)" 'error (status->code 409))

;;; &refusal

(define acct (make-bytevector 16 7))

(test-equal "refusal: raised and caught reads back its fields"
  (list #t 'forbidden acct)
  (attempt (lambda ()
             (guard (e ((refusal? e) (list #t (refusal-code e) (refusal-account e))))
               (raise (make-refusal 'forbidden acct))))))

(test-equal "refusal: no account"
  (list 'unauthorized #f)
  (attempt (lambda ()
             (guard (e ((refusal? e) (list (refusal-code e) (refusal-account e))))
               (raise (make-refusal 'unauthorized #f))))))

(test-equal "refusal: carries no message and no irritants"
  '(#f #f #f)
  (attempt (lambda ()
             (let ((r (make-refusal 'not_found acct)))
               (list (message-condition? r) (irritants-condition? r) (who-condition? r))))))

(test-equal "refusal: an ordinary condition is not one"
  #f
  (refusal? (make-assertion-violation)))

(test-equal "refusal: an unknown code raises" 'assertion
  (raised-kind (lambda () (make-refusal 'nope #f))))
(test-equal "refusal: a string for a code raises" 'assertion
  (raised-kind (lambda () (make-refusal "forbidden" #f))))
(test-equal "refusal: a 15-byte account raises" 'assertion
  (raised-kind (lambda () (make-refusal 'forbidden (make-bytevector 15 0)))))
(test-equal "refusal: a 17-byte account raises" 'assertion
  (raised-kind (lambda () (make-refusal 'forbidden (make-bytevector 17 0)))))
(test-equal "refusal: a string account raises" 'assertion
  (raised-kind (lambda () (make-refusal 'forbidden "account"))))

;;; The answer in the format (D7, RFC 9457)

(define d7-statuses '(400 401 403 404 405 413 415 500 503 504))

(test-equal "status-phrase: RFC 9110's phrase for each status of D7's table"
  '("Bad Request" "Unauthorized" "Forbidden" "Not Found" "Method Not Allowed"
    "Content Too Large" "Unsupported Media Type" "Internal Server Error"
    "Service Unavailable" "Gateway Timeout")
  (attempt (lambda () (map status-phrase d7-statuses))))

(test-equal "status-phrase: 409, 429 and 431 have theirs; 418 and 599 have none, so their class's"
  '("Conflict" "Too Many Requests" "Request Header Fields Too Large" "Client Error" "Server Error")
  (attempt (lambda () (map status-phrase '(409 429 431 418 599)))))

(test-equal "status-phrase: 200, 399, 600 and a string raise"
  '(assertion assertion assertion assertion)
  (map (lambda (s) (raised-kind (lambda () (status-phrase s)))) (list 200 399 600 "404")))

;; header-of : Res String -> (U String #f)
(define (header-of res name)
  (let loop ((hs (res-headers res)))
    (cond ((null? hs) #f)
          ((string=? (string-downcase (caar hs)) name) (cdar hs))
          (else (loop (cdr hs))))))

;; problem-summary : (-> Res) -> (U (List Nat (U String #f) Any) (List 'raised String))
;; Status, content-type and the body parsed as JSON.
(define (problem-summary thunk)
  (attempt (lambda ()
             (let ((res (thunk)))
               (list (res-status res)
                     (header-of res "content-type")
                     (string->json (utf8->string (res-body->bytevector res))))))))

(test-equal "problem-res: forbidden is a 403 in the format, its members in RFC 9457's order"
  '(403 "application/problem+json"
    (("type" . "about:blank") ("title" . "Forbidden") ("status" . 403)
     ("code" . "forbidden") ("detail" . "A key can only regenerate itself.")))
  (problem-summary (lambda () (problem-res 'forbidden))))

(test-assert "problem-res: every code with a status answers it, its phrase, its code and its message"
  (for-all (lambda (c)
             (let ((s (error-status c)))
               (equal? (problem-summary (lambda () (problem-res c)))
                       (list s "application/problem+json"
                             (list (cons "type" "about:blank") (cons "title" (status-phrase s))
                                   (cons "status" s) (cons "code" (symbol->string c))
                                   (cons "detail" (error-message c)))))))
           fixed))

(test-equal "problem-res: a 401 carries www-authenticate: Bearer; a 403 and a 404 carry none"
  '("Bearer" #f #f)
  (attempt (lambda ()
             (map (lambda (c) (header-of (problem-res c) "www-authenticate"))
                  '(unauthorized forbidden not_found)))))

(test-equal "problem-res: given headers are kept, but content-type and content-length, which it sets"
  '(("content-type" . "application/problem+json") ("retry-after" . "5") ("x-a" . "b"))
  (attempt (lambda ()
             (res-headers (problem-res 'unavailable '(("Content-Type" . "text/plain")
                                                      ("retry-after" . "5")
                                                      ("content-length" . "3")
                                                      ("x-a" . "b")))))))

(test-equal "problem-res: a 401 that has its own www-authenticate keeps it and gets no second"
  '(("content-type" . "application/problem+json") ("www-authenticate" . "Bearer realm=\"x\""))
  (attempt (lambda ()
             (res-headers (problem-res 'unauthorized '(("www-authenticate" . "Bearer realm=\"x\"")))))))

(test-equal "problem-res: `error` has no status, so it raises; so does an unknown code"
  '(assertion assertion)
  (list (raised-kind (lambda () (problem-res 'error)))
        (raised-kind (lambda () (problem-res 'nope)))))

(test-equal "status-problem-res: a bare 418 is `error`, with 418 and its class's phrase"
  '(418 "application/problem+json"
    (("type" . "about:blank") ("title" . "Client Error") ("status" . 418)
     ("code" . "error") ("detail" . "The request could not be completed.")))
  (problem-summary (lambda () (status-problem-res 418))))

(test-equal "status-problem-res: a bare 502 is `error`, Bad Gateway"
  '(502 "Bad Gateway" "error")
  (attempt (lambda ()
             (let ((j (string->json (utf8->string (res-body->bytevector (status-problem-res 502))))))
               (list (res-status (status-problem-res 502))
                     (cdr (assoc "title" j)) (cdr (assoc "code" j)))))))

(test-equal "status-problem-res: each status of D7's table gets status->code's code"
  '("invalid_request" "unauthorized" "forbidden" "not_found" "method_not_allowed"
    "payload_too_large" "unsupported_media_type" "internal" "unavailable" "timeout")
  (attempt (lambda ()
             (map (lambda (s)
                    (let ((j (string->json (utf8->string (res-body->bytevector (status-problem-res s))))))
                      (cdr (assoc "code" j))))
                  d7-statuses))))

(test-equal "status-problem-res: a 405 keeps its allow; a bare 401 gets www-authenticate: Bearer"
  '("GET, HEAD" "Bearer")
  (attempt (lambda ()
             (list (header-of (status-problem-res 405 '(("allow" . "GET, HEAD"))) "allow")
                   (header-of (status-problem-res 401) "www-authenticate")))))

(test-equal "status-problem-res: 200, 399 and 600 raise"
  '(assertion assertion assertion)
  (map (lambda (s) (raised-kind (lambda () (status-problem-res s)))) '(200 399 600)))

(test-end "errors")

(exit (suite-exit-status runner))
