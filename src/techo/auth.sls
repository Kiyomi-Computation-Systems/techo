#!r6rs
;;; (techo auth): the key check, inside the request's own job (D3, D4, D5,
;;; D6, D10). The imperative shell.
;;;
;;; A handler calls db-read-as or db-write-as with a job runner, the request
;;; and a thunk that makes its plan. On the loop's thread they:
;;;
;;;   1. read Authorization (every field: two are refused) and, when it is
;;;      not one well-shaped bearer key, answer the 401 with no job (P6);
;;;   2. hash the secret: only its 32 bytes go any further, so the secret
;;;      never enters a job, a condition or a log line (D3);
;;;   3. ask the handler for its plan: a response here (a 400 for a bad
;;;      parameter) is the answer, with no job; so the header is checked
;;;      before the parameters, as D9 orders them;
;;;   4. run one job: find the key by its hash, step D5's table with
;;;      `check` and perform the command (admit, or refuse-401), load the
;;;      account, set the key's last_used when a write is due to (D6), then
;;;      run the plan's work;
;;;   5. catch a &refusal from the job and answer it in the format; write
;;;      the account and db_ms into the request's note (D10); then hand
;;;      what the work returned to the plan's answer.
;;;
;;; A job closes over plain data only: the hash, the time, and the plan's
;;; work, which closes over plain data too. Never the request, never a
;;; parameter (ADR-0013). The note is written here, on the loop's thread,
;;; never from inside a job.
;;;
;;; The catch is the doorway's own pattern (wrap-db's, circuit's): call/cc
;;; around with-exception-handler, anything but a &refusal passed on by
;;; raise-continuable from where it was raised, before anything unwinds. So
;;; a deadline or a closed client that comes during the wait goes on to
;;; wrap-timeout and wrap-catch as if this were not here.
(library (techo auth)
  (export key-hash key-state touch-due? make-plan plan?
          db-read-as db-write-as)
  (import (rnrs)
          (only (circuit) req-header-values res?)
          (only (chez-sodium) blake2b)
          (techo errors)
          (only (techo keys) key-step read-bearer)
          (except (techo store) key-hash)
          (only (techo log) note-request!))

  ;; Runner = ((Tx -> Any) -> Any)      db-read or db-write, given a doorway
  ;; Clock = (-> Integer)               milliseconds, for durations
  ;; Work = (Tx Account Key -> A)       run inside the job, with the account
  ;;                                    and the asking key's row
  ;; Answer = (A -> Res)                run on the loop's thread, after it

  ;; key-hash : String -> Bytevector
  ;; BLAKE2b-256 of the secret's UTF-8 bytes: how a key is stored and found
  ;; (D3, ADR-0006). What is no string raises.
  (define (key-hash secret)
    (blake2b (string->utf8 secret) 32))

  ;; key-state : (U Key #f) -> (U 'none 'active 'revoked)
  ;; A row as D5's state: no row is none, a revoked one revoked.
  (define (key-state key)
    (cond ((not key) 'none)
          ((key-revoked key) 'revoked)
          (else 'active)))

  (define day-ms 86400000)

  ;; touch-due? : (U Natural #f) Natural -> Boolean
  ;; Whether a write at NOW sets a key's last_used (D6): when it is null, or
  ;; more than a day before NOW.
  (define (touch-due? last-used now)
    (or (not last-used) (> (- now last-used) day-ms)))

  ;; Plan : a handler's work and its answer.
  ;; make-plan : Work Answer -> Plan
  ;; plan? : Any -> Boolean
  (define-record-type (plan make-plan plan?)
    (fields (immutable work plan-work) (immutable answer plan-answer)))

  ;; checked : Tx Bytevector -> (values Key Account)
  ;; In the job: the asking key by its hash, D5's `check`, and its account.
  ;; refuse-401 raises a &refusal with no account.
  (define (checked tx hash)
    (let ((key (key-by-hash tx hash)))
      (let-values (((next command) (key-step (key-state key) 'check)))
        (case command
          ((admit) (values key (account-by-id tx (key-account key))))
          ((refuse-401) (raise (make-refusal 'unauthorized #f)))
          (else (assertion-violation 'checked "D5's check named a command with no action here"
                                     command))))))

  ;; read-job : Bytevector Work -> (Tx -> (Pair Bytevector A))
  ;; The account's id, and what the work returned.
  (define (read-job hash work)
    (lambda (tx)
      (let-values (((key account) (checked tx hash)))
        (cons (account-id account) (work tx account key)))))

  ;; write-job : Bytevector Natural Work -> (Tx -> (Pair Bytevector A))
  ;; As read-job, and first the asking key's last_used set to NOW when it is
  ;; due, in the same transaction: the work sees the row as it now is. A
  ;; refusal rolls it back with the rest.
  (define (write-job hash now work)
    (lambda (tx)
      (let-values (((key account) (checked tx hash)))
        (let ((key (if (touch-due? (key-last-used key) now)
                       (begin (touch-key! tx (key-id key) now)
                              (key-of-account tx (account-id account) (key-id key)))
                       key)))
          (cons (account-id account) (work tx account key))))))

  ;; run-as : Symbol Runner Clock Req (-> (U Res Plan)) (Bytevector Work -> Job) -> Res
  ;; Steps 1 to 5 of the header, MAKE-JOB building the job of the hash and
  ;; the plan's work.
  (define (run-as who run clock req prepare make-job)
    (let ((secret (read-bearer (req-header-values req "authorization"))))
      (if (not secret)
          (problem-res 'unauthorized)
          (let* ((hash (key-hash secret))
                 (step (prepare)))
            (cond ((res? step) step)
                  ((plan? step)
                   (let ((outcome (outcome-of run (make-job hash (plan-work step)) clock req)))
                     (if (res? outcome)
                         outcome
                         ((plan-answer step) (cdr outcome)))))
                  (else (assertion-violation who "a plan is a make-plan or a response" step)))))))

  ;; outcome-of : Runner Job Clock Req -> (U Res (Pair Bytevector A))
  ;; RUN's answer to JOB, or a &refusal's answer in the format. Whichever
  ;; way the runner comes back, a raise too, db_ms is written into REQ's
  ;; note: the time from handing the job over to its answer, the queue's
  ;; wait included; and the account when it is known: the job's, or the
  ;; refusal's. Anything but a &refusal goes on, raised again from where it
  ;; was raised.
  (define (outcome-of run job clock req)
    (let ((start (clock)))
      (call/cc
       (lambda (k)
         (with-exception-handler
          (lambda (e)
            (let ((refused? (refusal? e)))
              (note-request! req (and refused? (refusal-account e)) (- (clock) start))
              (if refused?
                  (k (problem-res (refusal-code e)))
                  (raise-continuable e))))
          (lambda ()
            (let ((r (run job)))
              (note-request! req (car r) (- (clock) start))
              r)))))))

  ;; db-read-as : Runner Clock Req (-> (U Res Plan)) -> Res
  ;; One read job for REQ, as the header describes. RUN is the read runner,
  ;; CLOCK the duration clock, PREPARE the handler's plan, asked for once the
  ;; header has passed. A read never writes last_used (D6).
  (define (db-read-as run clock req prepare)
    (run-as 'db-read-as run clock req prepare read-job))

  ;; db-write-as : Runner Clock Natural Req (-> (U Res Plan)) -> Res
  ;; One write job for REQ, as db-read-as, and NOW, the time of day in whole
  ;; milliseconds since 1970, UTC, read on the loop's thread before the job,
  ;; for last_used.
  (define (db-write-as run clock now req prepare)
    (run-as 'db-write-as run clock req prepare
            (lambda (hash work) (write-job hash now work))))
)
