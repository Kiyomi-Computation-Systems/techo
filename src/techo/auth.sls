#!r6rs
;;; (techo auth): the key check, inside the request's own job, and for a
;;; write with a body in a read job before the body too (D3, D4, D5, D6,
;;; D10; ADR-0006, amended 2026-11-25). The imperative shell.
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
;;; A write whose request has a body calls db-write-with-body-as, so that
;;; no body is read before its key is known to be good: the body is up to
;;; 2 MiB of JSON, and anyone with a key of the right shape could make the
;;; loop parse it. It runs two jobs. On the loop's thread it:
;;;
;;;   1. and 2. as above;
;;;   3. asks the handler for its Reader: the cheap checks that need
;;;      neither the database nor the body come first, and a response here
;;;      is the answer, with no job;
;;;   4. runs one read job, the pre-check: the key found by its hash and
;;;      `check` stepped as in 4 above, the account read, nothing written
;;;      (a read never writes last_used); a refusal is answered as in 5,
;;;      and the account goes into the cell and the note as in 5;
;;;   5. calls the Reader: the body is read only now, and may wait; a
;;;      response is the answer;
;;;   6. reads the wall clock once, so a slow upload's time is when its
;;;      body had come, and asks for the plan of the Reader's data and
;;;      that time;
;;;   7. runs one write job as db-write-as does, with that time: the key
;;;      checked again (it may have been revoked while the body came),
;;;      last_used set when due, the plan's work; then 5 above, its db_ms
;;;      added to the read job's, and the read job's account kept on the
;;;      note when this job's refusal names none.
;;;
;;; A job closes over plain data only, and one cell (below): the hash, the
;;; time, and the plan's work, which closes over plain data too. Never the
;;; request, never a parameter (ADR-0013). The note is written here, on the
;;; loop's thread, never from inside a job.
;;;
;;; The cell is the one exception (slice 3b's L8): one slot, made for each
;;; request, read and written under its mutex; a write with a body's two
;;; jobs share it. The job puts the account's id in it as soon as the key
;;; check passes. When the runner raises anything but a &refusal (a
;;; deadline, a hung-up client, a 500), the note gets the cell's account:
;;; the key's, once it was checked; #f for a job still queued, or waiting
;;; for the lock, at that moment, unless the pre-check had passed.
;;;
;;; Login has no key, so it reaches the database by two procedures of its
;;; own (L7), and no others: login-read, one read job, and login-write, one
;;; write job. Their db_ms is added to the note's, so a login's is the sum
;;; of its two jobs, and neither touches the note's account: the handler
;;; writes it once the password has matched, before the write.
;;;
;;; The catch is the doorway's own pattern (wrap-db's, circuit's): call/cc
;;; around with-exception-handler, anything but a &refusal passed on by
;;; raise-continuable from where it was raised, before anything unwinds. So
;;; a deadline or a closed client that comes during the wait goes on to
;;; wrap-timeout and wrap-catch as if this were not here.
(library (techo auth)
  (export key-hash key-state touch-due? make-plan plan?
          db-read-as db-write-as db-write-with-body-as
          login-read login-write)
  (import (rnrs)
          (only (chezscheme) make-mutex with-mutex)
          (only (circuit) req-header-values res?)
          (only (chez-sodium) blake2b)
          (techo errors)
          (only (techo keys) key-step read-bearer)
          (except (techo store) key-hash)
          (only (techo log) note-request! note-account! note-add-db-ms!))

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

  ;; Cell : the account a job's key check passed for, or #f, under a mutex
  ;; (L8). The job writes it from its thread; the loop's thread reads it.
  (define-record-type cell
    (fields (immutable mutex cell-mutex) (mutable account cell-account cell-account-set!)))

  ;; new-cell : -> Cell
  (define (new-cell) (make-cell (make-mutex) #f))

  ;; cell-put! : Cell Bytevector -> Void
  (define (cell-put! c account)
    (with-mutex (cell-mutex c) (cell-account-set! c account)))

  ;; cell-take : Cell -> (U Bytevector #f)
  (define (cell-take c)
    (with-mutex (cell-mutex c) (cell-account c)))

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

  ;; read-job : Bytevector Work Cell -> (Tx -> (Pair Bytevector A))
  ;; The account's id, and what the work returned. The id goes into CELL
  ;; as soon as the key has passed its check.
  (define (read-job hash work cell)
    (lambda (tx)
      (let-values (((key account) (checked tx hash)))
        (cell-put! cell (account-id account))
        (cons (account-id account) (work tx account key)))))

  ;; write-job : Bytevector Natural Work Cell -> (Tx -> (Pair Bytevector A))
  ;; As read-job, and first the asking key's last_used set to NOW when it is
  ;; due, in the same transaction: the work sees the row as it now is. A
  ;; refusal rolls it back with the rest.
  (define (write-job hash now work cell)
    (lambda (tx)
      (let-values (((key account) (checked tx hash)))
        (cell-put! cell (account-id account))
        (let ((key (if (touch-due? (key-last-used key) now)
                       (begin (touch-key! tx (key-id key) now)
                              (key-of-account tx (account-id account) (key-id key)))
                       key)))
          (cons (account-id account) (work tx account key))))))

  ;; with-key : Req (Bytevector -> Res) -> Res
  ;; Steps 1 and 2 of the header: REQ's one well-shaped bearer key, hashed
  ;; and handed to THEN; or the 401, with no job. Only the hash goes on.
  (define (with-key req then)
    (let ((secret (read-bearer (req-header-values req "authorization"))))
      (if secret
          (then (key-hash secret))
          (problem-res 'unauthorized))))

  ;; answered : Plan (U Res (Pair Bytevector A)) -> Res
  ;; A job's outcome as the request's answer: a refusal's answer as it is,
  ;; else what the work returned handed to PLAN's answer.
  (define (answered plan outcome)
    (if (res? outcome) outcome ((plan-answer plan) (cdr outcome))))

  ;; run-as : Symbol Runner Clock Req (-> (U Res Plan)) (Bytevector Work Cell -> Job) -> Res
  ;; Steps 1 to 5 of the header, MAKE-JOB building the job of the hash, the
  ;; plan's work and the request's cell.
  (define (run-as who run clock req prepare make-job)
    (with-key req
      (lambda (hash)
        (let ((step (prepare)))
          (cond ((res? step) step)
                ((plan? step)
                 (let ((cell (new-cell)))
                   (answered step (outcome-of run (make-job hash (plan-work step) cell)
                                              clock req cell note-request!))))
                (else (assertion-violation who "a plan is a make-plan or a response" step)))))))

  ;; Noter = (Req (U Bytevector #f) Integer -> Void)
  ;;         how a job's account and db_ms go into the request's note

  ;; note-more! : Noter
  ;; A second job's: its account written when it names one, so a 401 from
  ;; a key revoked since the first job keeps the account that job found;
  ;; and its time added to the first job's db_ms.
  (define (note-more! req account ms)
    (when account (note-account! req account))
    (note-add-db-ms! req ms))

  ;; outcome-of : Runner Job Clock Req Cell Noter -> (U Res (Pair Bytevector A))
  ;; RUN's answer to JOB, or a &refusal's answer in the format. Whichever
  ;; way the runner comes back, a raise too, NOTE! writes into REQ's note
  ;; the job's db_ms, the time from handing the job over to its answer, the
  ;; queue's wait included; and the account when it is known: the job's,
  ;; the refusal's, or, for any other raise, CELL's (L8). Anything but a
  ;; &refusal goes on, raised again from where it was raised.
  (define (outcome-of run job clock req cell note!)
    (let ((start (clock)))
      (call/cc
       (lambda (k)
         (with-exception-handler
          (lambda (e)
            (let ((refused? (refusal? e)))
              (note! req (if refused? (refusal-account e) (cell-take cell)) (- (clock) start))
              (if refused?
                  (k (problem-res (refusal-code e)))
                  (raise-continuable e))))
          (lambda ()
            (let ((r (run job)))
              (note! req (car r) (- (clock) start))
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
            (lambda (hash work cell) (write-job hash now work cell))))

  ;; checked-only : Work     the pre-check's work: none; its job's key check is all
  (define (checked-only tx account key) #t)

  ;; Reader = (-> (U Res A))     reads the request's body; may wait; a Res refuses

  ;; db-write-with-body-as : Runner Runner Clock (-> Natural) Req (-> (U Res Reader))
  ;;                         (A Natural -> Plan) -> Res
  ;; A write whose request has a body, as the header's second list: two
  ;; jobs for REQ, the key checked before the body is read and again in the
  ;; write. READ and WRITE are the runners, CLOCK the duration clock,
  ;; WALL-CLOCK the time of day in whole milliseconds since 1970, UTC.
  ;; PREPARE is asked once the header has passed; its Reader is called once
  ;; the read job has found the key good. WALL-CLOCK is read once, after
  ;; the Reader has returned: NOW, which PLAN-OF is handed with the Reader's
  ;; data, and the write job's last_used. The two jobs share REQ's cell,
  ;; and the note's db_ms is their sum. A raise from the Reader, a deadline
  ;; or the body's 413 among them, goes on as it was raised, the note
  ;; holding the account. What PREPARE answers that is neither a response
  ;; nor a procedure, and what PLAN-OF answers that is no plan, are an
  ;; assertion violation.
  (define (db-write-with-body-as read write clock wall-clock req prepare plan-of)
    (with-key req
      (lambda (hash)
        (let ((reader (prepare)))
          (cond
            ((res? reader) reader)
            ((procedure? reader)
             (let* ((cell (new-cell))
                    (pre (outcome-of read (read-job hash checked-only cell) clock req cell
                                     note-request!)))
               (if (res? pre)
                   pre
                   (let ((data (reader)))
                     (if (res? data)
                         data
                         (let* ((now (wall-clock))
                                (plan (plan-of data now)))
                           (unless (plan? plan)
                             (assertion-violation 'db-write-with-body-as "plan-of answers a make-plan"
                                                  plan))
                           (answered plan (outcome-of write (write-job hash now (plan-work plan) cell)
                                                      clock req cell note-more!))))))))
            (else (assertion-violation 'db-write-with-body-as
                                       "prepare answers a Reader or a response" reader)))))))

  ;;; Login's two jobs (L7)

  ;; timed : Runner Job Clock Req -> A
  ;; RUN's answer to JOB. Whichever way it comes back, a raise too, the
  ;; time it took is added to REQ's note's db_ms, and the note's account is
  ;; left as it is. A raise goes on, raised again from where it was raised.
  (define (timed run job clock req)
    (let ((start (clock)))
      (with-exception-handler
       (lambda (e)
         (note-add-db-ms! req (- (clock) start))
         (raise-continuable e))
       (lambda ()
         (let ((r (run job)))
           (note-add-db-ms! req (- (clock) start))
           r)))))

  ;; login-read-job : String -> (Tx -> (U (Pair Bytevector String) #f))
  (define (login-read-job email)
    (lambda (tx)
      (let ((a (account-by-email tx email)))
        (and a (cons (account-id a) (account-password-hash a))))))

  ;; login-read : Runner Clock Req String -> (U (Pair Bytevector String) #f)
  ;; One read job: the account's id and password hash by EMAIL, normalised
  ;; already, or #f for none. RUN is the read runner. The job closes over
  ;; the email alone.
  (define (login-read run clock req email)
    (unless (string? email)
      (assertion-violation 'login-read "the email must be a string"))
    (timed run (login-read-job email) clock req))

  ;; key-cap : Natural     an account's most active keys (slice 3's plan)
  (define key-cap 100)

  ;; login-write-job : Bytevector String (U String #f) Bytevector String Bytevector Natural
  ;;                   -> (Tx -> (U Key 'stale 'full))
  ;; L1's step 6, in one transaction. 'stale and 'full write nothing.
  (define (login-write-job account verified new-hash id name hash now)
    (lambda (tx)
      (let ((row (account-by-id tx account)))
        (cond
          ((not (and row (string=? (account-password-hash row) verified))) 'stale)
          ((>= (count-active-keys tx account) key-cap) 'full)
          (else
           (when new-hash
             (unless (eq? (set-password-hash! tx account verified new-hash) #t)
               (assertion-violation 'login-write "the new password hash was not stored")))
           (let-values (((next command) (key-step 'none 'create)))
             (case command
               ((insert)
                (insert-key! tx id account name hash now)
                (key-of-account tx account id))
               (else (assertion-violation 'login-write
                                          "D5's create named a command with no action here"
                                          command)))))))))

  ;; login-write : Runner Clock Req Bytevector String (U String #f) Key-fields
  ;;               -> (U Key 'stale 'full)
  ;; Key-fields = (List Bytevector String Bytevector Natural): the new
  ;; key's id (16 bytes), its name, its hash (32 bytes) and the time of day
  ;; in whole milliseconds since 1970, UTC.
  ;; One write job: the account by ACCOUNT's id; 'stale unless its password
  ;; hash is still VERIFIED, the one the password matched; 'full when it has
  ;; 100 active keys; else NEW-HASH stored when there is one, D5's `create`
  ;; stepped from `none` and its `insert` performed, and the new key's row.
  ;; RUN is the write runner. The job closes over plain data: no request,
  ;; no password, no secret. Key-fields of another shape are an assertion
  ;; violation, before any job.
  (define (login-write run clock req account verified new-hash fields)
    (unless (and (list? fields) (= (length fields) 4)
                 (bytevector? (car fields)) (= (bytevector-length (car fields)) 16)
                 (string? (cadr fields))
                 (bytevector? (caddr fields)) (= (bytevector-length (caddr fields)) 32)
                 (let ((now (cadddr fields))) (and (integer? now) (exact? now) (>= now 0))))
      (assertion-violation 'login-write "Key-fields are an id, a name, a hash and a time"))
    (unless (and (bytevector? account) (= (bytevector-length account) 16)
                 (string? verified) (or (not new-hash) (string? new-hash)))
      (assertion-violation 'login-write "an account's id, the verified hash, and a new hash or #f"))
    (timed run
           (login-write-job account verified new-hash
                            (car fields) (cadr fields) (caddr fields) (cadddr fields))
           clock req))
)
