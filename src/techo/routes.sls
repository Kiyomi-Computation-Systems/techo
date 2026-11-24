#!r6rs
;;; (techo routes): D9's four key routes. The imperative shell.
;;;
;;;   GET  /v1/account                 who the key belongs to
;;;   GET  /v1/keys                    the account's keys, paged, no secrets
;;;   POST /v1/keys/:id/revoke         D5's revoke
;;;   POST /v1/keys/:id/regenerate     D5's regenerate: the new secret, once
;;;
;;; Each handler makes one job through (techo auth)'s db-read-as or
;;; db-write-as, which check the key inside it. The order of checks is the
;;; header's shape (401), then the id, `limit` and `after` (400, with no
;;; job), then the job, where the key is checked (401) and the work done.
;;;
;;; Revoke and regenerate find the target with key-of-account, so another
;;; account's key is `none`; take D5's state of it, step the table, and
;;; perform the command it names. No handler decides an answer of its own.
;;;
;;; A new secret is made on the loop's thread before the job; only its hash
;;; enters the job, and the answer carries it once, with Cache-Control:
;;; no-store. A key's hash and an account's password hash are never sent.
;;; A time is whole milliseconds since 1970, UTC (D15); null where empty.
(library (techo routes)
  (export key-routes)
  (import (rnrs)
          (only (circuit) res-set-header)
          (only (circuit json) make-json-res)
          (only (circuit params) req-query-params param-values)
          (only (circuit router) route GET POST req-path-param)
          (techo errors)
          (only (techo keys) key-step key-secret parse-id parse-limit parse-after id->string)
          (except (techo store) key-hash)
          (techo auth))

  ;; Runner = ((Tx -> Any) -> Any)
  ;; Clock = (-> Integer)

  ;;; Answers

  ;; or-null : (U Natural #f) -> (U Natural 'null)
  (define (or-null x) (or x 'null))

  ;; key->json : Key -> Alist
  ;; id, name, created, last_used, revoked. Never the hash.
  (define (key->json k)
    (list (cons "id" (id->string (key-id k)))
          (cons "name" (key-name k))
          (cons "created" (key-created k))
          (cons "last_used" (or-null (key-last-used k)))
          (cons "revoked" (or-null (key-revoked k)))))

  ;; account->json : Account -> Alist
  ;; id, username, email, created. Never the password's hash.
  (define (account->json a)
    (list (cons "id" (id->string (account-id a)))
          (cons "username" (account-username a))
          (cons "email" (account-email a))
          (cons "created" (account-created a))))

  ;; key-answer : Key -> Res
  (define (key-answer k) (make-json-res 200 (key->json k)))

  ;; secret-answer : String -> (Key -> Res)
  ;; The key and its new SECRET, once, not to be kept by a cache.
  (define (secret-answer secret)
    (lambda (k)
      (res-set-header (make-json-res 200 (append (key->json k) (list (cons "key" secret))))
                      "cache-control" "no-store")))

  ;; take : (Listof A) Natural -> (Listof A)     the first N
  (define (take xs n)
    (if (or (= n 0) (null? xs)) '() (cons (car xs) (take (cdr xs) (- n 1)))))

  ;; page-answer : Natural -> ((Listof Key) -> Res)
  ;; KEYS is what the store gave for LIMIT + 1: a key past LIMIT says there
  ;; is a next page, which starts after the last key shown.
  (define (page-answer limit)
    (lambda (keys)
      (let* ((shown (take keys limit))
             (more? (> (length keys) limit)))
        (make-json-res 200
                       (list (cons "items" (list->vector (map key->json shown)))
                             (cons "next" (if more?
                                              (id->string (key-id (car (reverse shown))))
                                              'null)))))))

  (define (bad-request) (problem-res 'invalid_request))

  ;;; Parameters

  ;; query-one : Req String -> (U String #f 'invalid)
  ;; The query's one value for NAME, #f for none, 'invalid for two or more.
  (define (query-one req name)
    (let ((vs (param-values (req-query-params req) name)))
      (cond ((null? vs) #f)
            ((null? (cdr vs)) (car vs))
            (else 'invalid))))

  ;; path-id : Req -> (U Bytevector 'invalid)
  (define (path-id req) (parse-id (req-path-param req "id")))

  ;;; D5's commands

  ;; refusal-codes : (Listof (Pair CommandKind Symbol))
  (define refusal-codes
    '((refuse-401 . unauthorized) (refuse-403 . forbidden) (refuse-404 . not_found)))

  ;; perform! : CommandKind Tx Account (U Key #f) Bytevector Natural (U Bytevector #f) -> Key
  ;; In the job: exactly the command D5's table named for the target ID of
  ;; the account, and the target's row as it then is. A refusal is raised
  ;; as a &refusal carrying the asking account. A command no key route
  ;; performs (insert, admit) is an assertion violation.
  (define (perform! command tx account target id now new-hash)
    (let ((owner (account-id account)))
      (case command
        ((set-revoked) (revoke-key! tx owner id now) (key-of-account tx owner id))
        ((replace-hash) (replace-key-hash! tx owner id new-hash) (key-of-account tx owner id))
        ((nothing) target)
        ((refuse-401 refuse-403 refuse-404)
         (raise (make-refusal (cdr (assq command refusal-codes)) owner)))
        (else (assertion-violation 'perform! "no key route performs this command" command)))))

  ;; revoke-work : Bytevector Natural -> Work
  (define (revoke-work id now)
    (lambda (tx account asking)
      (let ((target (key-of-account tx (account-id account) id)))
        (let-values (((next command) (key-step (key-state target) 'revoke)))
          (perform! command tx account target id now #f)))))

  ;; regenerate-work : Bytevector Bytevector Natural -> Work
  ;; The event is by who asks (D5): the asking key itself, or another.
  (define (regenerate-work id new-hash now)
    (lambda (tx account asking)
      (let ((target (key-of-account tx (account-id account) id))
            (event (if (bytevector=? id (key-id asking)) 'regenerate-self 'regenerate-other)))
        (let-values (((next command) (key-step (key-state target) event)))
          (perform! command tx account target id now new-hash)))))

  ;;; The routes

  ;; key-routes : Runner Runner (-> Natural) (Natural -> Bytevector) Clock -> (Listof Route)
  ;; D9's four routes, for make-router. READ and WRITE run a job each;
  ;; WALL-CLOCK is the time of day in whole milliseconds since 1970, UTC;
  ;; RANDOM-BYTES gives N random bytes; CLOCK reads milliseconds for db_ms.
  ;; The clocks and the bytes are read on the loop's thread only.
  (define (key-routes read write wall-clock random-bytes clock)

    ;; GET /v1/account
    (define (account req)
      (db-read-as read clock req
                  (lambda ()
                    (make-plan (lambda (tx account key) account)
                               (lambda (a) (make-json-res 200 (account->json a)))))))

    ;; GET /v1/keys?limit=&after=
    (define (keys req)
      (db-read-as read clock req
                  (lambda ()
                    (let ((limit (parse-limit (query-one req "limit")))
                          (after (parse-after (query-one req "after"))))
                      (if (or (eq? limit 'invalid) (eq? after 'invalid))
                          (bad-request)
                          (make-plan (lambda (tx account key)
                                       (keys-page tx (account-id account) after (+ limit 1)))
                                     (page-answer limit)))))))

    ;; POST /v1/keys/:id/revoke
    (define (revoke req)
      (let ((now (wall-clock)))
        (db-write-as write clock now req
                     (lambda ()
                       (let ((id (path-id req)))
                         (if (eq? id 'invalid)
                             (bad-request)
                             (make-plan (revoke-work id now) key-answer)))))))

    ;; POST /v1/keys/:id/regenerate
    (define (regenerate req)
      (let ((now (wall-clock)))
        (db-write-as write clock now req
                     (lambda ()
                       (let ((id (path-id req)))
                         (if (eq? id 'invalid)
                             (bad-request)
                             (let* ((secret (key-secret (random-bytes 32)))
                                    (hash (key-hash secret)))
                               (make-plan (regenerate-work id hash now)
                                          (secret-answer secret)))))))))

    (list (route "/v1/account" (GET account))
          (route "/v1/keys" (GET keys))
          (route "/v1/keys/:id/revoke" (POST revoke))
          (route "/v1/keys/:id/regenerate" (POST regenerate))))
)
