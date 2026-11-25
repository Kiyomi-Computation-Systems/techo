#!r6rs
;;; (techo routes): D9's four key routes, and slice 3b's login. The
;;; imperative shell.
;;;
;;;   GET  /v1/account                 who the key belongs to
;;;   GET  /v1/keys                    the account's keys, paged, no secrets
;;;   POST /v1/keys/:id/revoke         D5's revoke
;;;   POST /v1/keys/:id/regenerate     D5's regenerate: the new secret, once
;;;   POST /v1/login                   an email and a password make a key
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
;;;
;;; Login is run by (techo login)'s table (L1). Its handler performs each
;;; command the step names, feeds back what the effect answered, and at
;;; the end does what the table's ending says: the answer, and what happens
;;; to the try's count. It decides neither by a test of its own. Before the
;;; table, and counted as no try: the Content-Type (415), the body through
;;; wrap-json-body (400 invalid_json, 413), and parse-login-body (400).
(library (techo routes)
  (export key-routes login-routes make-login-kit login-kit?)
  (import (rnrs)
          (only (circuit) res-set-header req-header-values req-remote-address)
          (only (circuit json) make-json-res wrap-json-body req-json? req-json)
          (only (circuit router) route GET POST req-path-param)
          (techo errors)
          (only (techo keys) key-step key-secret parse-id parse-limit parse-after id->string)
          (except (techo store) key-hash)
          (only (techo log) note-account!)
          (only (techo address) address-key client-address)
          (only (techo limiter) limiter-try! limiter-forgive! limiter-clear-email!)
          (only (techo login) login-start login-step login-event-kind parse-login-body
                ending-code ending-count ending-retry-after ending-log-full?)
          (techo auth)
          (techo requests))

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

  ;; secret-answer : Natural String -> (Key -> Res)
  ;; STATUS with the key and its new SECRET, once, not to be kept by a
  ;; cache: 200 for a regenerate, 201 for a login.
  (define (secret-answer status secret)
    (lambda (k)
      (res-set-header (make-json-res status (append (key->json k) (list (cons "key" secret))))
                      "cache-control" "no-store")))

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

  ;;; Parameters

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
                                          (secret-answer 200 secret)))))))))

    (list (route "/v1/account" (GET account))
          (route "/v1/keys" (GET keys))
          (route "/v1/keys/:id/revoke" (POST revoke))
          (route "/v1/keys/:id/regenerate" (POST regenerate))))

  ;;; Login (slice 3b: L1, L2, L10)

  ;; Verify = ((U String #f) String -> (U 'matched 'unmatched 'busy))
  ;; Doubt = (-> (U 'hashed 'failed 'busy))
  ;; Hash = (String -> (U String 'failed 'busy))
  ;; NeedsRehash = (String -> Boolean)
  ;; The first three are the hasher's calls, closed over a hasher by the
  ;; program; a test gives fakes.

  ;; LoginKit : what POST /v1/login needs beside the doorway.
  ;; login-kit? : Any -> Boolean
  (define-record-type (login-kit make-kit login-kit?)
    (fields verify doubt hash needs-rehash limiter proxies ids log))

  ;; make-login-kit : Verify Doubt Hash NeedsRehash Limiter Natural (-> Bytevector)
  ;;                  (String -> Void) -> LoginKit
  ;; The hasher's three calls, the rehash test, the limiter (make-limiter's,
  ;; owned by the loop's thread), the count of proxies in front
  ;; (TECHO_BEHIND_PROXY), a source of 16 fresh bytes for a key's id, and
  ;; the log procedure for the limiter's one "full" line. A procedure that
  ;; is none, or a count that is no Natural, is an assertion violation.
  (define (make-login-kit verify doubt hash needs-rehash limiter proxies ids log)
    (for-each (lambda (p)
                (unless (procedure? p)
                  (assertion-violation 'make-login-kit "the hasher's calls, ids and log are procedures" p)))
              (list verify doubt hash needs-rehash ids log))
    (unless (and (integer? proxies) (exact? proxies) (>= proxies 0))
      (assertion-violation 'make-login-kit "the proxy count is a whole number" proxies))
    (make-kit verify doubt hash needs-rehash limiter proxies ids log))

  ;; body-cap : Natural     slice 3's cap for a JSON body, 16 KiB
  (define body-cap 16384)

  ;; retry-headers : (U Natural #f) -> Headers
  (define (retry-headers seconds)
    (if seconds (list (cons "retry-after" (number->string seconds))) '()))

  ;; login-routes : Runner Runner (-> Natural) (Natural -> Bytevector) Clock LoginKit
  ;;                -> (Listof Route)
  ;; POST /v1/login, for make-router. READ and WRITE run a job each;
  ;; WALL-CLOCK gives the new key's time; RANDOM-BYTES its secret; CLOCK,
  ;; the duration clock, the limiter's time and db_ms; KIT the rest. All of
  ;; them are called on the loop's thread only.
  (define (login-routes read write wall-clock random-bytes clock kit)
    (unless (login-kit? kit)
      (assertion-violation 'login-routes "a login kit is make-login-kit's" kit))
    (let ((json-body (wrap-json-body body-cap))
          (limiter (login-kit-limiter kit)))

      ;; run-login : Req String String String -> Res
      ;; L1's table from its start, for EMAIL (normalised), PASSWORD (NFC)
      ;; and NAME. The password and the new secret stay here, on the loop's
      ;; thread: a hash job closes over the password, a write job over the
      ;; secret's hash only.
      (define (run-login req email password name)
        (let ((address (address-key (client-address (login-kit-proxies kit)
                                                    (req-header-values req "x-forwarded-for")
                                                    (req-remote-address req))))
              (secret #f))

          ;; perform : Command -> RawOutcome     one command's effect
          (define (perform command)
            (case (car command)
              ((count) (limiter-try! limiter email address (clock)))
              ((read) (login-read read clock req email))
              ((verify)
               (let* ((stored (cadr command))
                      (verdict ((login-kit-verify kit) stored password)))
                 ;; after a match, whether the stored hash is at today's limits
                 (list verdict (if (and (eq? verdict 'matched) stored)
                                   (and ((login-kit-needs-rehash kit) stored) #t)
                                   #f))))
              ((doubt) ((login-kit-doubt kit)))
              ((rehash)
               (note-account! req (cadr command))
               ((login-kit-hash kit) password))
              ((write)
               (note-account! req (cadr command))
               (let* ((id ((login-kit-ids kit)))
                      (s (key-secret (random-bytes 32)))
                      (now (wall-clock)))
                 (set! secret s)
                 (login-write write clock req (cadr command) (caddr command) (cadddr command)
                              (list id name (key-hash s) now))))
              (else (assertion-violation 'login "the table named a command with no action here"
                                         (car command)))))

          ;; finish : Command -> Res     (answer Ending Key Try)
          (define (finish command)
            (let ((ending (cadr command)) (key (caddr command)) (try (cadddr command)))
              (case (ending-count ending)
                ((keep) #f)
                ((forgive) (limiter-forgive! limiter try))
                ((clear) (limiter-clear-email! limiter email))
                (else (assertion-violation 'login "no such count rule" (ending-count ending))))
              (when (ending-log-full? ending)
                ((login-kit-log kit) "limiter full=1"))
              (case (ending-code ending)
                ((created) ((secret-answer 201 secret) key))
                (else (problem-res (ending-code ending)
                                   (retry-headers (ending-retry-after ending)))))))

          (let-values (((state command) (login-start)))
            (let loop ((state state) (command command))
              (if (eq? (car command) 'answer)
                  (finish command)
                  (let ((raw (perform command)))
                    (let-values (((next next-command)
                                  (login-step state (cons (login-event-kind command raw) raw))))
                      (loop next next-command))))))))

      ;; parsed : Req -> Res     the body read; refusals counted as no try
      (define (parsed req)
        (let ((body (and (req-json? req) (parse-login-body (req-json req)))))
          (if (or (not body) (symbol? body))
              (bad-request)
              (run-login req (car body) (cadr body) (caddr body)))))

      ;; login : Req -> Res
      ;; The Content-Type, then the body under the cap: wrap-json-body's
      ;; plain 400 for a body that does not parse, answered before the
      ;; handler ran, is invalid_json here; past the cap is its 413.
      (define (login req)
        (if (not (json-type? req))
            (problem-res 'unsupported_media_type)
            (let* ((ran? #f)
                   (res ((json-body (lambda (r) (set! ran? #t) (parsed r))) req)))
              (if ran? res (problem-res 'invalid_json)))))

      (list (route "/v1/login" (POST login)))))
)
