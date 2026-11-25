#!r6rs
;;; (techo login): POST /v1/login as a table (slice 3b's L1), and the
;;; body's parser (L2). Pure: no database, no clock, no hashing, no
;;; limiter of its own (ADR-0007). (techo routes) is the shell: it performs
;;; each command the step names and feeds back what the effect answered.
;;;
;;; States: limiting reading verifying doubting rehashing writing ended.
;;; A state is (kind . Data). Data is an association list of what the login
;;; has learnt so far, newest first: (try . Try) (account . Bytevector)
;;; (stored . String) (new-hash . String) (key . Key) (log-full . Boolean)
;;; (ending . Ending). `ended` keeps it all.
;;;
;;; A command is the next state's, made from its data:
;;;   (count)                      count the try: limiter-try!
;;;   (read)                       read the account by email: login-read
;;;   (verify Stored)              verify against the stored hash, or the
;;;                                stand-in for #f
;;;   (doubt)                      hash a throwaway
;;;   (rehash Account)             hash the password again
;;;   (write Account Stored New)   make the key: login-write
;;;   (answer Ending Key Try)      answer, and do to the count what the
;;;                                ending says
;;; Only a match leads to rehash or write, and each names the account: the
;;; shell writes it into the request's note before it runs (L7).
;;;
;;; An event is (kind . raw), raw what the effect answered, its kind given
;;; by login-event-kind from the command and the raw outcome.
(library (techo login)
  (export login-rows login-cant-happen login-endings login-start login-step
          login-event-kind login-document
          ending? ending-code ending-count ending-retry-after ending-log-full?
          parse-login-body)
  (import (rnrs)
          (techo machine)
          (only (techo errors) error-status)
          (only (techo limiter) try?)
          (only (techo accounts) normalise-email)
          (only (techo keys) key-name-problem)
          (only (techo passwords) prepare-login-password))

  ;;; Data

  ;; known : Data Symbol -> Any     what was learnt under NAME, else #f
  (define (known d name)
    (let ((hit (assq name d)))
      (and hit (cdr hit))))

  ;; learn : Data Symbol Any -> Data
  (define (learn d name value) (cons (cons name value) d))

  ;;; Endings

  ;; Ending : how a login ends, all of it the table's say:
  ;;   code         created, or the error code answered: invalid_credentials
  ;;                too_many_keys rate_limited unavailable
  ;;   count        what happens to the try's count: keep forgive clear
  ;;   retry-after  seconds for Retry-After, or #f
  ;;   log-full?    whether the limiter's one "full" line is logged
  ;; ending? : Any -> Boolean
  ;; ending-code ending-count : Ending -> Symbol
  ;; ending-retry-after : Ending -> (U Natural #f)
  ;; ending-log-full? : Ending -> Boolean
  (define-record-type ending
    (fields code count retry-after log-full?))

  ;;; The table

  (define (same d raw) d)

  ;; Updates of the going rows
  (define (learn-try d raw) (learn d 'try raw))
  (define (learn-account d raw)
    (learn (learn d 'account (car raw)) 'stored (cdr raw)))
  (define (learn-new-hash d raw) (learn d 'new-hash raw))

  ;; go : StateKind EventKind StateKind CommandKind Update -> Entry
  ;; Entry is (state event next command update code count); code and count
  ;; are #f for a row that does not end.
  (define (go state event next command update)
    (list state event next command update #f #f))

  ;; end : StateKind EventKind Symbol Symbol RetryFrom [Update] -> Entry
  ;; A row to `ended` that answers CODE and does COUNT to the try's count.
  ;; RETRY is #f, a number of seconds, or 'event: the seconds the limiter
  ;; gave, the raw outcome's second element. FIRST, if given, learns from
  ;; the raw outcome before the ending is made.
  (define end
    (case-lambda
      ((state event code count retry) (end state event code count retry same))
      ((state event code count retry first)
       (list state event 'ended 'answer
             (lambda (d raw)
               (let ((d (first d raw)))
                 (learn d 'ending
                        (make-ending code count
                                     (if (eq? retry 'event) (cadr raw) retry)
                                     (and (known d 'log-full) #t)))))
             code count))))

  (define (learn-log-full d raw) (learn d 'log-full (caddr raw)))
  (define (learn-key d raw) (learn d 'key raw))

  ;; table : (Listof Entry)
  ;; L1's table and its six steps, in their order.
  (define table
    (list
     ;; 1. The try is counted before anything is read or hashed.
     (go 'limiting 'allowed 'reading 'read learn-try)
     (end 'limiting 'limited 'rate_limited 'keep 'event)
     (end 'limiting 'full 'rate_limited 'keep 'event learn-log-full)
     ;; 2. A missing account is verified against the stand-in: the same cost.
     (go 'reading 'found 'verifying 'verify learn-account)
     (go 'reading 'missing 'verifying 'verify same)
     ;; 3. A full queue checked nothing: forgiven. A match on the stand-in
     ;; cannot happen, and counts as no match.
     (go 'verifying 'matched 'writing 'write same)
     (go 'verifying 'matched-outdated 'rehashing 'rehash same)
     (go 'verifying 'matched-stand-in 'doubting 'doubt same)
     (go 'verifying 'unmatched 'doubting 'doubt same)
     (end 'verifying 'busy 'unavailable 'forgive 5)
     ;; 4. The throwaway tells a wrong password from short memory. A full
     ;; queue here stays counted: the verify did run.
     (end 'doubting 'hashed 'invalid_credentials 'keep #f)
     (end 'doubting 'failed 'unavailable 'forgive 5)
     (end 'doubting 'busy 'invalid_credentials 'keep #f)
     ;; 5. A failed rehash never fails a login.
     (go 'rehashing 'rehashed 'writing 'write learn-new-hash)
     (go 'rehashing 'failed 'writing 'write same)
     (go 'rehashing 'busy 'writing 'write same)
     ;; 6. One write job: the key, if the hash is still the one verified.
     (end 'writing 'made 'created 'clear #f learn-key)
     (end 'writing 'stale 'invalid_credentials 'keep #f)
     (end 'writing 'full 'too_many_keys 'clear #f)))

  ;; login-rows : (Listof Row)
  ;; Row is (state event next command update), as (techo machine) takes it.
  ;; The row's command kind is the next state's command.
  (define login-rows
    (map (lambda (e) (list (car e) (cadr e) (caddr e) (cadddr e) (list-ref e 4))) table))

  ;; login-endings : (Listof (List StateKind EventKind Symbol Symbol))
  ;; Each row that ends: its state and event, the code it answers (created
  ;; for the 201) and what it does to the count: keep, forgive or clear.
  (define login-endings
    (map (lambda (e) (list (car e) (cadr e) (list-ref e 5) (list-ref e 6)))
         (filter (lambda (e) (eq? (caddr e) 'ended)) table)))

  ;; possible : the event kinds login-event-kind can answer in each state
  (define possible
    '((limiting allowed limited full)
      (reading found missing)
      (verifying matched matched-outdated matched-stand-in unmatched busy)
      (doubting hashed failed busy)
      (rehashing rehashed failed busy)
      (writing made stale full)))

  (define event-kinds
    (fold-left (lambda (acc p)
                 (fold-left (lambda (acc e) (if (memq e acc) acc (append acc (list e))))
                            acc (cdr p)))
               '() possible))

  ;; login-cant-happen : (Listof (List StateKind EventKind String))
  ;; Every pair of a state that goes on and an event kind with no row: the
  ;; command of that state never answers it.
  (define login-cant-happen
    (apply append
           (map (lambda (p)
                  (map (lambda (e)
                         (list (car p) e
                               (string-append "the command of " (symbol->string (car p))
                                              " never answers " (symbol->string e))))
                       (filter (lambda (e) (not (memq e (cdr p)))) event-kinds)))
                possible)))

  (define login-machine (make-machine login-rows))

  ;; login-command : State -> Command
  (define (login-command s)
    (let ((d (cdr s)))
      (case (car s)
        ((limiting) (list 'count))
        ((reading) (list 'read))
        ((verifying) (list 'verify (known d 'stored)))
        ((doubting) (list 'doubt))
        ((rehashing) (list 'rehash (known d 'account)))
        ((writing) (list 'write (known d 'account) (known d 'stored) (known d 'new-hash)))
        ((ended) (list 'answer (known d 'ending) (known d 'key) (known d 'try)))
        (else (assertion-violation 'login-command "not a login state" (car s))))))

  ;; login-start : -> (values State Command)
  ;; `limiting`, knowing nothing, and its command, (count).
  (define (login-start)
    (let ((s (cons 'limiting '())))
      (values s (login-command s))))

  ;; login-step : State Event -> (values State Command)
  ;; Event is (cons EventKind RawOutcome). The next state and its command.
  ;; An assertion violation, who 'machine-step, for a pair with no row.
  (define (login-step state event)
    (let-values (((next row-command) (machine-step login-machine state event)))
      (let ((command (login-command next)))
        (unless (eq? (car command) (car row-command))
          (assertion-violation 'login-step "the row's command kind is not the next state's"
                               (car state) (car event) (car row-command) (car command)))
        (values next command))))

  ;; login-event-kind : Command RawOutcome -> EventKind
  ;; Sorts what the effect answered by the command it answers:
  ;;   (count)          a Try: allowed; (limited s): limited;
  ;;                    (full s first?): full
  ;;   (read)           (id . hash): found; #f: missing
  ;;   (verify Stored)  (verdict outdated?), verdict matched, unmatched or
  ;;                    busy, outdated? whether the stored hash is not at
  ;;                    today's limits (the shell asks only after a match).
  ;;                    matched with #f stored: matched-stand-in; with
  ;;                    outdated?: matched-outdated
  ;;   (doubt)          hashed failed busy
  ;;   (rehash _)       a String: rehashed; failed; busy
  ;;   (write _ _ _)    stale; full; a key's row (no symbol, not #f): made
  ;; Anything else, and (answer ...), is an assertion violation.
  (define (login-event-kind command raw)
    (define (bad)
      (assertion-violation 'login-event-kind "this command cannot have this outcome"
                           (and (pair? command) (car command))))
    (unless (pair? command)
      (assertion-violation 'login-event-kind "not a command" command))
    (case (car command)
      ((count)
       (cond ((try? raw) 'allowed)
             ((and (list? raw) (= (length raw) 2) (eq? (car raw) 'limited)) 'limited)
             ((and (list? raw) (= (length raw) 3) (eq? (car raw) 'full)) 'full)
             (else (bad))))
      ((read)
       (cond ((not raw) 'missing)
             ((and (pair? raw) (bytevector? (car raw)) (string? (cdr raw))) 'found)
             (else (bad))))
      ((verify)
       (unless (and (list? raw) (= (length raw) 2) (boolean? (cadr raw))) (bad))
       (case (car raw)
         ((matched) (cond ((not (cadr command)) 'matched-stand-in)
                          ((cadr raw) 'matched-outdated)
                          (else 'matched)))
         ((unmatched) 'unmatched)
         ((busy) 'busy)
         (else (bad))))
      ((doubt)
       (if (memq raw '(hashed failed busy)) raw (bad)))
      ((rehash)
       (cond ((string? raw) 'rehashed)
             ((memq raw '(failed busy)) raw)
             (else (bad))))
      ((write)
       (cond ((memq raw '(stale full)) raw)
             ((or (not raw) (symbol? raw)) (bad))
             (else 'made)))
      (else
       (assertion-violation 'login-event-kind "no outcome for this command" (car command)))))

  ;;; The diagram

  ;; count-word : Symbol -> String
  (define (count-word count)
    (case count ((keep) "kept") ((forgive) "forgiven") ((clear) "cleared") (else "?")))

  ;; answer-text : Symbol -> String     "201 created", "401 invalid_credentials"
  (define (answer-text code)
    (string-append (number->string (if (eq? code 'created) 201 (error-status code)))
                   " " (symbol->string code)))

  ;; login-document : -> String
  ;; The text of .plans/machines/login.md, rendered from the table.
  (define (login-document)
    (string-append
     "# The login machine\n\n"
     "Generated from the table in `src/techo/login.sls`. Do not edit.\n"
     "Regenerate with `scripts/guix-env make machines`; "
     "a test fails when this file differs.\n\n"
     "It starts in `limiting` and ends in `ended`.\n\n"
     "```mermaid\n"
     (machine->mermaid login-machine)
     "```\n\n"
     "## How each ending answers, and what it does to the try's count\n\n"
     "| From | On | Answer | The count |\n"
     "|---|---|---|---|\n"
     (apply string-append
            (map (lambda (e)
                   (string-append "| " (symbol->string (car e))
                                  " | " (symbol->string (cadr e))
                                  " | " (answer-text (caddr e))
                                  " | " (count-word (cadddr e)) " |\n"))
                 login-endings))))

  ;;; The body (L2)

  (define members '("email" "password" "name"))

  ;; object? : Any -> Boolean     an alist of string names, as jsonparse makes one
  (define (object? x)
    (and (list? x)
         (for-all (lambda (m) (and (pair? m) (string? (car m)))) x)))

  ;; repeated? : (Listof String) -> Boolean
  (define (repeated? names)
    (and (pair? names)
         (or (member (car names) (cdr names))
             (repeated? (cdr names)))
         #t))

  ;; value-of : Alist String -> Any
  (define (value-of x name) (cdr (assoc name x)))

  ;; parse-login-body : Any -> (U (List String String String) Symbol)
  ;; From req-json's value to (email password name): the email by
  ;; normalise-email, the password by prepare-login-password (NFC), the name
  ;; as it is. Else a refusal, checked in this order: not-an-object,
  ;; repeated-member, unknown-member, missing-member, not-a-string,
  ;; bad-email, bad-name, password-too-long. Never raises.
  (define (parse-login-body x)
    (cond
      ((not (object? x)) 'not-an-object)
      ((repeated? (map car x)) 'repeated-member)
      ((exists (lambda (m) (not (member (car m) members))) x) 'unknown-member)
      ((exists (lambda (name) (not (assoc name x))) members) 'missing-member)
      ((exists (lambda (name) (not (string? (value-of x name)))) members) 'not-a-string)
      (else
       (let ((email (normalise-email (value-of x "email")))
             (name (value-of x "name")))
         (cond ((not email) 'bad-email)
               ((key-name-problem name) 'bad-name)
               (else
                (let ((password (prepare-login-password (value-of x "password"))))
                  (if (string? password)
                      (list email password name)
                      'password-too-long))))))))
)
