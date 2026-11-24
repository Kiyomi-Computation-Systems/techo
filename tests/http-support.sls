#!r6rs
;;; (http-support): what a suite needs to drive Techo's handlers with raw
;;; HTTP bytes through chez-http-server's test host, on a real SQLite file
;;; behind the test doorway. Test-only: it lives in tests/.
;;;
;;; A handler that waits (a job, a deadline) can run only on the server's
;;; coroutine, so every request here goes through a test host: bytes in,
;;; the responses the client read out. The host has no peer address.
;;;
;;;   the wire       request-bytes, exchange, exchange-bytes, answers
;;;   inputs         bearer, step-clock, byte-sequence, counting
;;;   the database   fresh-dir, open-test-store, store-reader, store-writer,
;;;                  run-write, run-read, close-test-store!, in-host
;;;   evidence       capture-output, reaches?
;;;
;;; Everything here raises as it is: a suite computes what it calls under a
;;; guard of its own.
(library (http-support)
  (export request-bytes exchange exchange-bytes
          answer? answer-status answer-headers answer-header answer-body answer-json
          answer-complete?
          bearer step-clock byte-sequence counting
          fresh-dir open-test-store store-reader store-writer store-path
          run-write run-read close-test-store! in-host
          capture-output reaches? contains?)
  (import (rnrs)
          (only (chezscheme) mkdir directory-list delete-directory file-directory?
                current-time time-second time-nanosecond parameterize inspect/object
                make-eq-hashtable)
          (rename (only (chezscheme) current-output-port) (current-output-port output-port-param))
          (only (circuit) make-res)
          (only (circuit http-server) circuit->handler)
          (http-server testing)
          (only (jsonparse easy) string->json)
          (techo migrations)
          (only (techo db) migrate!)
          (techo doorway))

  ;;; The wire

  ;; Header = (Pair String String)

  ;; request-bytes : Symbol String (Listof Header) [(U String #f)] -> Bytevector
  ;; An HTTP/1.1 request for METHOD and TARGET, with Host: test, HEADERS in
  ;; order (a name given twice is sent twice), and BODY with its
  ;; Content-Length when it is a string.
  (define request-bytes
    (case-lambda
      ((method target headers) (request-bytes method target headers #f))
      ((method target headers body)
       (string->utf8
        (string-append
         (symbol->string method) " " target " HTTP/1.1\r\nHost: test\r\n"
         (apply string-append
                (map (lambda (h) (string-append (car h) ": " (cdr h) "\r\n")) headers))
         (if body
             (string-append "Content-Length: "
                            (number->string (bytevector-length (string->utf8 body))) "\r\n")
             "")
         "\r\n"
         (or body ""))))))

  ;; Answer : what the client read of one response.
  ;; answer? : Any -> Boolean
  ;; answer-status : Answer -> Natural
  ;; answer-headers : Answer -> (Listof Header)   names in lower case, in order
  ;; answer-body : Answer -> String
  ;; answer-json : Answer -> Any   the body parsed as JSON; 'empty for no
  ;;   bytes, 'not-json for bytes that do not parse
  ;; answer-complete? : Answer -> Boolean
  (define-record-type (answer make-answer answer?)
    (fields status headers body json complete?))

  ;; answer-header : Answer String -> (U String #f)
  ;; The first field named NAME, in any case.
  (define (answer-header a name)
    (let ((hit (assoc (string-downcase name) (answer-headers a))))
      (and hit (cdr hit))))

  ;; latin-1 : Bytevector -> String
  (define (latin-1 bv) (list->string (map integer->char (bytevector->u8-list bv))))

  ;; ->answer : TestResponse -> Answer
  (define (->answer r)
    (let ((body (utf8->string (test-response-body r))))
      (make-answer (test-response-status r)
                   (map (lambda (h) (cons (string-downcase (latin-1 (car h))) (latin-1 (cdr h))))
                        (test-response-headers r))
                   body
                   (if (= (string-length body) 0)
                       'empty
                       (guard (e (#t 'not-json)) (string->json body)))
                   (test-response-complete? r))))

  (define (unset name) #f)

  ;; exchange-bytes : Handler Bytevector [Natural] -> (Listof Answer)
  ;; A test host for HANDLER, an app of circuit's (Req -> Res): one client
  ;; sends BYTES; the host's clock is then moved on ADVANCE-MS (0 unless
  ;; given), and the responses the client read come back, in order.
  (define exchange-bytes
    (case-lambda
      ((handler bytes) (exchange-bytes handler bytes 0))
      ((handler bytes advance-ms)
       (let* ((host (make-test-host (circuit->handler handler unset) unset))
              (c (test-host-connect! host)))
         (test-client-send! c bytes)
         (test-host-advance! host advance-ms)
         (map ->answer (test-client-responses c))))))

  ;; exchange : Handler Symbol String (Listof Header) [(U String #f)] -> Answer
  ;; One request, its one response. Any other count of responses is an
  ;; assertion violation.
  (define exchange
    (case-lambda
      ((handler method target headers) (exchange handler method target headers #f))
      ((handler method target headers body)
       (let ((as (exchange-bytes handler (request-bytes method target headers body))))
         (unless (= (length as) 1)
           (assertion-violation 'exchange "not one response" (length as)))
         (car as)))))

  ;;; Inputs

  ;; bearer : String -> Header
  (define (bearer secret) (cons "Authorization" (string-append "Bearer " secret)))

  ;; step-clock : Integer Integer -> (-> Integer)
  ;; START at the first reading, then START + STEP, and so on.
  (define (step-clock start step)
    (let ((t (- start step)))
      (lambda () (set! t (+ t step)) t)))

  ;; byte-sequence : -> (Natural -> Bytevector)
  ;; A stand-in for random-bytes: the Kth call (from 1) answers N bytes
  ;; holding K in its first four, big-endian, and #x5A after. A sequence,
  ;; never one constant, so no two keys share a hash.
  (define (byte-sequence)
    (let ((k 0))
      (lambda (n)
        (set! k (+ k 1))
        (let ((bv (make-bytevector n #x5A)))
          (let loop ((i 0))
            (when (and (< i 4) (< i n))
              (bytevector-u8-set! bv i (bitwise-and (bitwise-arithmetic-shift-right k (* 8 (- 3 i)))
                                                    255))
              (loop (+ i 1))))
          bv))))

  ;; counting : Procedure -> (values Procedure (-> Natural))
  ;; PROC, and a reader of how many times it has been called.
  (define (counting proc)
    (let ((n 0))
      (values (lambda args (set! n (+ n 1)) (apply proc args))
              (lambda () n))))

  ;;; The database

  (define (rm-tree! p)
    (cond ((file-directory? p)
           (for-each (lambda (n) (rm-tree! (string-append p "/" n)))
                     (directory-list p))
           (delete-directory p))
          ((file-exists? p) (delete-file p))))

  (define (make-dir! p) (unless (file-directory? p) (mkdir p #o755)))

  ;; fresh-dir : String -> String
  ;; build/NAME/<seconds>-<nanoseconds>, made empty; build/NAME is removed
  ;; first. Relative to the working directory, which make test sets to the
  ;; repository.
  (define (fresh-dir name)
    (let ((t (current-time)))
      (make-dir! "build")
      (rm-tree! (string-append "build/" name))
      (make-dir! (string-append "build/" name))
      (let ((d (string-append "build/" name "/" (number->string (time-second t)) "-"
                              (number->string (time-nanosecond t)))))
        (make-dir! d)
        d)))

  ;; Store : a file the shipped migrations made, and a test doorway on it.
  (define-record-type (store make-store store?)
    (fields path doorway))

  ;; store-path : Store -> String

  ;; open-test-store : String String -> Store
  ;; DIR/NAME migrated afresh, and a test doorway (one thread each, a busy
  ;; timeout of 100 ms). Stop it with close-test-store!.
  (define (open-test-store dir name)
    (let ((p (string-append dir "/" name)))
      (for-each (lambda (s) (when (file-exists? (string-append p s))
                              (delete-file (string-append p s))))
                '("" "-wal" "-shm"))
      (migrate! p migrations)
      (make-store p (make-test-doorway p migrations 100))))

  ;; store-reader, store-writer : Store -> ((Tx -> Any) -> Any)
  ;; The job runners make-app takes, as techo.sps makes them.
  (define (store-reader s) (lambda (job) (db-read (store-doorway s) job)))
  (define (store-writer s) (lambda (job) (db-write (store-doorway s) job)))

  ;; close-test-store! : Store -> Void
  (define (close-test-store! s)
    (guard (e (#t #f)) (doorway-stop-readers! (store-doorway s)))
    (guard (e (#t #f)) (doorway-stop-writer! (store-doorway s))))

  ;; in-host : (-> A) -> A
  ;; THUNK as the handler of one request in a test host, since a job waits;
  ;; its value, or its raise raised again here.
  (define (in-host thunk)
    (let* ((result (list 'did-not-run))
           (app (lambda (req)
                  (set! result (guard (e (#t (list 'raised e))) (list 'ok (thunk))))
                  (make-res 200 '() "ok")))
           (host (make-test-host (circuit->handler app unset) unset))
           (c (test-host-connect! host)))
      (test-client-send! c (string->utf8 "GET /x HTTP/1.1\r\nHost: x\r\n\r\n"))
      (test-client-responses c)
      (case (car result)
        ((ok) (cadr result))
        ((raised) (raise (cadr result)))
        (else (assertion-violation 'in-host "the handler did not run")))))

  ;; run-write, run-read : Store (Tx -> A) -> A
  ;; One job, as db-write (db-read) runs it, in a test host.
  (define (run-write s job) (in-host (lambda () (db-write (store-doorway s) job))))
  (define (run-read s job) (in-host (lambda () (db-read (store-doorway s) job))))

  ;;; Evidence

  ;; capture-output : (-> A) -> (values A String)
  ;; THUNK's value, and what it wrote on the current output port, as Chez's
  ;; parameter has it: wrap-catch's handler-failed line goes there.
  (define (capture-output thunk)
    (let* ((value #f)
           (text (call-with-string-output-port
                  (lambda (p)
                    (parameterize ((output-port-param p))
                      (set! value (thunk)))))))
      (values value text)))

  ;; contains? : String String -> Boolean
  (define (contains? s part)
    (let ((n (string-length s)) (m (string-length part)))
      (let loop ((i 0))
        (cond ((> (+ i m) n) #f)
              ((string=? (substring s i (+ i m)) part) #t)
              (else (loop (+ i 1)))))))

  ;; reaches? : Any (Any -> Boolean) -> Boolean
  ;; Whether FOUND? holds of ROOT or of anything reachable from it through a
  ;; closure's free variables, a pair, a vector, a box or a record's fields,
  ;; as Chez's inspector sees them (an opaque record's fields too). A walk
  ;; of at most 200,000 objects, each once; past that an assertion
  ;; violation, so a walk that is cut short never passes as a "no".
  (define (reaches? root found?)
    (let ((seen (make-eq-hashtable))
          (budget 200000))
      (define (walk x)
        (cond ((or (null? x) (boolean? x) (char? x) (fixnum? x) (symbol? x)) #f)
              ((hashtable-ref seen x #f) #f)
              (else
               (hashtable-set! seen x #t)
               (set! budget (- budget 1))
               (when (< budget 0)
                 (assertion-violation 'reaches? "the walk is too long to say no"))
               (or (found? x)
                   (let ((p (inspect/object x)))
                     (case (p 'type)
                       ((procedure)
                        (let loop ((i 0))
                          (and (< i (p 'length))
                               (or (walk (((p 'ref i) 'ref) 'value))
                                   (loop (+ i 1))))))
                       ((pair) (or (walk (car x)) (walk (cdr x))))
                       ((vector)
                        (let loop ((i 0))
                          (and (< i (vector-length x))
                               (or (walk (vector-ref x i)) (loop (+ i 1))))))
                       ((box) (walk ((p 'unbox) 'value)))
                       ((record)
                        (let loop ((i 0))
                          (and (< i (p 'length))
                               (or (walk ((p 'ref i) 'value))
                                   (loop (+ i 1))))))
                       (else #f)))))))
      (walk root)))
)
