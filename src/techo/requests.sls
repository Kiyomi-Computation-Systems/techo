#!r6rs
;;; (techo requests): what more than one route library reads from a
;;; request, or answers with, before any job: a query parameter's one
;;; value, the first N of a page, the JSON media type, and the plain 400.
;;; The imperative shell's edge: each reads a request and decides nothing
;;; of a route's own.
(library (techo requests)
  (export query-one take json-type? bad-request)
  (import (rnrs)
          (only (circuit) req-header-values)
          (only (circuit params) req-query-params param-values)
          (only (techo errors) problem-res))

  ;; query-one : Req String -> (U String #f 'invalid)
  ;; The query's one value for NAME, #f for none, 'invalid for two or more.
  (define (query-one req name)
    (let ((vs (param-values (req-query-params req) name)))
      (cond ((null? vs) #f)
            ((null? (cdr vs)) (car vs))
            (else 'invalid))))

  ;; take : (Listof A) Natural -> (Listof A)     the first N
  (define (take xs n)
    (if (or (= n 0) (null? xs)) '() (cons (car xs) (take (cdr xs) (- n 1)))))

  ;; json-type? : Req -> Boolean
  ;; One Content-Type field whose media type is application/json, in any
  ;; case, its parameters ignored.
  (define (json-type? req)
    (let ((fields (req-header-values req "content-type")))
      (and (= (length fields) 1)
           (let* ((v (car fields))
                  (n (string-length v))
                  (end (let loop ((i 0))
                         (if (or (= i n) (char=? (string-ref v i) #\;)) i (loop (+ i 1)))))
                  (end (let trim ((e end))
                         (if (and (> e 0) (memv (string-ref v (- e 1)) '(#\space #\tab)))
                             (trim (- e 1))
                             e))))
             (string=? (ascii-downcase (substring v 0 end)) "application/json")))))

  ;; ascii-downcase : String -> String
  (define (ascii-downcase s)
    (list->string (map (lambda (c) (if (char<=? #\A c #\Z)
                                       (integer->char (+ (char->integer c) 32))
                                       c))
                       (string->list s))))

  ;; bad-request : -> Res     400 invalid_request, in the format
  (define (bad-request) (problem-res 'invalid_request))
)
