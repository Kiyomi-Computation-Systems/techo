#!r6rs
;;; (techo migrations): the migrations list, the file's classifier, and the
;;; two machines of `techo migrate` and `techo serve`'s check. Pure: nothing
;;; here opens a file or calls SQLite (ADR-0007, ADR-0012). The plan is
;;; .plans/2026-11-23-slice-2-migrations.md; each row below carries its
;;; R-number from the plan's table.
;;;
;;; State data
;;; ----------
;;; The run machine's state is (kind . data) and, but for `ended`, data is a
;;; six-element list (k i committed converted tries pending):
;;;   k          the migration in hand, 0 before any
;;;   i          the statement of k in hand, 1-based
;;;   committed  versions whose COMMIT answered ok, ascending
;;;   converted  #t once this run set WAL
;;;   tries      conversion retries left: a run starts with 3, they never
;;;              reset. A busy answer with tries > 0 pauses and takes one; a
;;;              busy answer at 0 ends the run busy. So 4 attempts, 3 pauses.
;;;   pending    #f, or (kind . detail): the Result's kind and detail, set
;;;              as the run heads for `closing`
;;; `ended`'s data is the Result itself. The check machine's `peek-opening`
;;; and `peeking` carry '(); its `closing` and `ended` carry the Verdict.
;;;
;;; An event is (kind . (status value open? dbstate)): the raw outcome, then
;;; the DbState of the facts when the state is a look and the outcome is ok.
;;;
;;; State kinds, run: peek-opening peeking reopening opening looking
;;;   converting pausing locking relooking applying checking stamping
;;;   committing undoing-to-look undoing-to-fail closing ended.
;;; State kinds, check: peek-opening peeking closing ended.
;;;
;;; Decisions the plan left open
;;; ----------------------------
;;; - `busy` is its own event kind only at converting and locking; `missing`
;;;   only at peek-opening. Anywhere else both are `failed` (with the
;;;   reason), so no shell outcome has no row.
;;; - pausing has a `failed` row (R20b), since every command has one.
;;; - Ok but the transaction ended: at applying R29; at relooking, checking
;;;   and stamping it is `failed-ended` (the transaction is gone, rows R26b
;;;   and R36); at committing, ok with the transaction ended is the normal
;;;   COMMIT, and ok with it still open is an impossible answer, taken as
;;;   `failed`.
;;; - Every command run inside the transaction tells `failed` (it is still
;;;   open: roll it back) from `failed-ended` (it is gone: close). At
;;;   relooking that is R26 and R26b; at applying, checking, stamping and
;;;   committing, R35 and R36. A ROLLBACK that fails closes either way
;;;   (R38, R39).
;;; - A failure inside k's transaction names k; a failure of BEGIN
;;;   IMMEDIATE or outside any migration names #f.
(library (techo migrations)
  (export techo-application-id migrations latest-version check-migrations
          facts-sql classify facts-wal? forbidden-statement?
          state-kind run-rows check-rows run-start check-start
          event-kind check-event-kind make-stepper run-step check-step
          run-cant-happen check-cant-happen
          result->exit-status result->lines result->progress-lines
          result->ending-lines machines-document)
  (import (rnrs)
          (techo machine))

  ;; techo-application-id : Integer
  ;; "tech" as four bytes.
  (define techo-application-id #x74656368)

  ;; id-statement : String
  (define id-statement
    (string-append "PRAGMA application_id = "
                   (number->string techo-application-id)))

  ;; migrations : (Listof Migration)
  ;; Migration is (List Positive-Integer String (Listof String)): version,
  ;; name, statements. A shipped migration is never edited (ADR-0012).
  (define migrations
    (list (list 1 "techo's database" (list id-statement))
          (list 2 "accounts and api keys"
                (list "CREATE TABLE accounts (
  id            BLOB    NOT NULL PRIMARY KEY CHECK (length(id) = 16),
  username      TEXT    NOT NULL UNIQUE CHECK (username GLOB '[a-z0-9]*' AND username NOT GLOB '*[^a-z0-9_-]*' AND length(username) <= 32),
  email         TEXT    NOT NULL UNIQUE CHECK (email NOT GLOB '*[A-Z]*'),
  password_hash TEXT    NOT NULL,
  created       INTEGER NOT NULL
) STRICT"
                      "CREATE TABLE api_keys (
  id        BLOB    NOT NULL PRIMARY KEY CHECK (length(id) = 16),
  account   BLOB    NOT NULL REFERENCES accounts(id),
  name      TEXT    NOT NULL CHECK (length(name) BETWEEN 1 AND 64),
  key_hash  BLOB    NOT NULL UNIQUE CHECK (length(key_hash) = 32),
  created   INTEGER NOT NULL,
  last_used INTEGER,
  revoked   INTEGER
) STRICT"
                      "CREATE INDEX api_keys_account ON api_keys(account, id)"))
          (list 3 "nodes, revisions and changes"
                (list "CREATE TABLE nodes (
  num          INTEGER PRIMARY KEY,
  id           BLOB    NOT NULL UNIQUE CHECK (length(id) = 16),
  owner        BLOB    NOT NULL REFERENCES accounts(id),
  author       BLOB    NOT NULL REFERENCES accounts(id),
  kind         TEXT    NOT NULL CHECK (kind IN ('project','journal','note','task','contact')),
  title        TEXT    NOT NULL CHECK (length(title) <= 1000),
  content_type TEXT    NOT NULL CHECK (length(content_type) BETWEEN 1 AND 255),
  props        TEXT    NOT NULL CHECK (json_valid(props)),
  revision     INTEGER NOT NULL CHECK (revision >= 1),
  created      INTEGER NOT NULL,
  updated      INTEGER NOT NULL
) STRICT"
                      "CREATE INDEX nodes_owner ON nodes(owner, id)"
                      "CREATE TABLE revisions (
  node         BLOB    NOT NULL REFERENCES nodes(id),
  revision     INTEGER NOT NULL CHECK (revision >= 1),
  author       BLOB    NOT NULL REFERENCES accounts(id),
  title        TEXT    NOT NULL,
  content_type TEXT    NOT NULL,
  props        TEXT    NOT NULL CHECK (json_valid(props)),
  created      INTEGER NOT NULL,
  body         TEXT    NOT NULL,
  PRIMARY KEY (node, revision)
) STRICT"
                      "CREATE TABLE changes (
  owner    BLOB    NOT NULL REFERENCES accounts(id),
  seq      INTEGER NOT NULL,
  node     BLOB    NOT NULL,
  revision INTEGER NOT NULL,
  op       TEXT    NOT NULL,
  created  INTEGER NOT NULL,
  PRIMARY KEY (owner, seq)
) STRICT, WITHOUT ROWID"))))

  ;; latest-version : (Listof Migration) -> Natural
  (define (latest-version ms)
    (fold-left (lambda (acc m) (max acc (car m))) 0 ms))

  ;; migration-ref : (Listof Migration) Positive-Integer -> Migration
  (define (migration-ref ms k)
    (cond ((assv k ms) => (lambda (m) m))
          (else (assertion-violation 'migration-ref "no such migration" k))))

  ;;; check-migrations

  ;; blank? : String -> Boolean
  (define (blank? s)
    (let loop ((cs (string->list s)))
      (cond ((null? cs) #t)
            ((char-whitespace? (car cs)) (loop (cdr cs)))
            (else #f))))

  ;; skip-space-and-comments : (Listof Char) -> (Listof Char)
  ;; Drops leading whitespace, `;`, a byte order mark, `-- ...` lines and
  ;; `/* ... */` comments: SQLite skips each of them before a statement.
  (define (skip-space-and-comments cs)
    (cond ((null? cs) cs)
          ((or (char-whitespace? (car cs)) (char=? (car cs) #\;)
               (char=? (car cs) #\xFEFF))
           (skip-space-and-comments (cdr cs)))
          ((and (pair? (cdr cs)) (char=? (car cs) #\-) (char=? (cadr cs) #\-))
           (let loop ((r (cddr cs)))
             (cond ((null? r) r)
                   ((char=? (car r) #\newline) (skip-space-and-comments (cdr r)))
                   (else (loop (cdr r))))))
          ((and (pair? (cdr cs)) (char=? (car cs) #\/) (char=? (cadr cs) #\*))
           (let loop ((r (cddr cs)))
             (cond ((null? r) r)
                   ((and (pair? (cdr r)) (char=? (car r) #\*)
                         (char=? (cadr r) #\/))
                    (skip-space-and-comments (cddr r)))
                   (else (loop (cdr r))))))
          (else cs)))

  ;; first-word : String -> String
  ;; The statement's first word, upper-cased: the letters after leading
  ;; whitespace and comments, "" if none.
  (define (first-word s)
    (let loop ((cs (skip-space-and-comments (string->list s))) (acc '()))
      (if (and (pair? cs) (char-alphabetic? (car cs)))
          (loop (cdr cs) (cons (char-upcase (car cs)) acc))
          (list->string (reverse acc)))))

  (define forbidden-words
    '("BEGIN" "COMMIT" "END" "ROLLBACK" "SAVEPOINT" "RELEASE" "ATTACH"
      "DETACH" "VACUUM" "PRAGMA"
      ;; SQLite applies a flag pragma while it prepares the statement, so an
      ;; EXPLAIN in front does not stop one taking effect (probed).
      "EXPLAIN"))

  ;; forbidden-statement? : String -> Boolean
  ;; True when the statement's first word, read after whitespace and SQL
  ;; comments as `first-word` does, is one of `forbidden-words`.
  (define (forbidden-statement? s)
    (if (member (first-word s) forbidden-words) #t #f))

  ;; well-formed? : Any -> Boolean
  (define (well-formed? m)
    (and (list? m) (= (length m) 3)
         (exact-int? (car m)) (> (car m) 0)
         (string? (cadr m))
         (list? (caddr m)) (for-all string? (caddr m))))

  ;; check-migrations : (Listof Migration) -> (Listof Problem)
  ;; Problem is one of
  ;;   (no-migrations)
  ;;   (malformed-migration index)
  ;;   (bad-version index version)   version is not index + 1
  ;;   (empty-name version)          blank name
  ;;   (empty-statement version i)   blank statement, i from 1
  ;;   (forbidden-statement version i word)
  ;;   (first-migration-not-the-id)  migration 1 is not exactly the
  ;;                                 application_id statement
  ;; In list order. A statement's first word is read after whitespace and
  ;; SQL comments. Migration 1's statement is exempt from the forbidden
  ;; words, and must be exactly the PRAGMA built from techo-application-id.
  (define (check-migrations ms)
    (if (null? ms)
        (list (list 'no-migrations))
        (let loop ((ms ms) (index 0) (acc '()))
          (if (null? ms)
              (reverse acc)
              (let ((m (car ms)))
                (loop (cdr ms) (+ index 1)
                      (append (reverse (migration-problems m index)) acc)))))))

  ;; migration-problems : Any Natural -> (Listof Problem)
  (define (migration-problems m index)
    (if (not (well-formed? m))
        (list (list 'malformed-migration index))
        (let ((v (car m)) (name (cadr m)) (stmts (caddr m)))
          (append
           (if (= v (+ index 1)) '() (list (list 'bad-version index v)))
           (if (blank? name) (list (list 'empty-name v)) '())
           (if (= index 0)
               (if (equal? stmts (list id-statement))
                   '()
                   (list (list 'first-migration-not-the-id)))
               (let loop ((ss stmts) (i 1) (acc '()))
                 (if (null? ss)
                     (reverse acc)
                     (let ((w (first-word (car ss))))
                       (loop (cdr ss) (+ i 1)
                             (cond ((blank? (car ss))
                                    (cons (list 'empty-statement v i) acc))
                                   ((member w forbidden-words)
                                    (cons (list 'forbidden-statement v i w) acc))
                                   (else acc)))))))))))

  ;;; The file's state

  ;; facts-sql : String
  ;; One statement, one row of four columns: application_id, user_version,
  ;; objects in the schema, journal mode (text).
  (define facts-sql
    (string-append
     "SELECT (SELECT application_id FROM pragma_application_id), "
     "(SELECT user_version FROM pragma_user_version), "
     "(SELECT count(*) FROM sqlite_schema), "
     "(SELECT journal_mode FROM pragma_journal_mode)"))

  ;; exact-int? : Any -> Boolean
  (define (exact-int? x) (and (integer? x) (exact? x)))

  ;; check-facts : Symbol Any -> Void
  (define (check-facts who f)
    (unless (and (list? f) (= (length f) 4)
                 (exact-int? (car f)) (exact-int? (cadr f))
                 (exact-int? (caddr f)) (>= (caddr f) 0)
                 (symbol? (cadddr f)))
      (assertion-violation who "not DbFacts" f)))

  ;; classify : DbFacts (Listof Migration) -> DbState
  ;; DbState is (U 'fresh (List 'behind Natural) 'current (List 'ahead Integer)
  ;;                'foreign)
  ;; fresh: id 0, version 0, empty schema. Techo's id: version 1 to latest-1
  ;; is behind, latest is current, above is ahead; version 0 or negative is
  ;; foreign. Everything else is foreign. The journal mode plays no part.
  (define (classify facts ms)
    (check-facts 'classify facts)
    (let ((id (car facts)) (v (cadr facts)) (objects (caddr facts))
          (latest (latest-version ms)))
      (cond ((and (= id 0) (= v 0) (= objects 0)) 'fresh)
            ((not (= id techo-application-id)) 'foreign)
            ((< v 1) 'foreign)
            ((< v latest) (list 'behind v))
            ((= v latest) 'current)
            (else (list 'ahead v)))))

  ;; facts-wal? : DbFacts -> Boolean
  (define (facts-wal? facts)
    (check-facts 'facts-wal? facts)
    (eq? (cadddr facts) 'wal))

  ;;; States, outcomes, commands

  ;; state-kind : State -> Symbol
  (define (state-kind s) (car s))

  ;; check-raw : Symbol Any -> Void
  (define (check-raw who raw)
    (unless (and (list? raw) (= (length raw) 3) (symbol? (car raw))
                 (memq (car raw) '(ok busy missing failed))
                 (boolean? (caddr raw)))
      (assertion-violation who "not a RawOutcome" raw)))

  ;; data accessors, run machine
  (define (d-k d) (list-ref d 0))
  (define (d-i d) (list-ref d 1))
  (define (d-committed d) (list-ref d 2))
  (define (d-converted d) (list-ref d 3))
  (define (d-tries d) (list-ref d 4))
  (define (d-pending d) (list-ref d 5))
  (define (mk k i committed converted tries pending)
    (list k i committed converted tries pending))
  (define initial-data (mk 0 0 '() #f 3 #f))

  ;; event data accessors: (status value open? dbstate)
  (define (e-status e) (list-ref e 0))
  (define (e-value e) (list-ref e 1))
  (define (e-dbstate e) (list-ref e 3))

  ;; with-pending : Data (Pairof Symbol Any) -> Data
  (define (with-pending d p)
    (mk (d-k d) (d-i d) (d-committed d) (d-converted d) (d-tries d) p))

  ;; reason : Event -> String
  ;; SQLite's reason for a failed outcome; an ok outcome that is treated as a
  ;; failure (the transaction ended where it should not have) has none.
  (define (reason e)
    (cond ((eq? (e-status e) 'ok) "the transaction ended early")
          ((string? (e-value e)) (e-value e))
          (else "unknown failure")))

  ;; failed-pending : Data Event Boolean -> (Pair 'failed Detail)
  ;; Detail is (List (U Positive-Integer #f) String Boolean).
  (define (failed-pending k e commit?)
    (cons 'failed (list k (reason e) commit?)))

  ;; statement-sql : (Listof Migration) Positive-Integer Positive-Integer -> String
  (define (statement-sql ms k i)
    (list-ref (caddr (migration-ref ms k)) (- i 1)))

  ;; state-command : (Listof Migration) State -> Command
  ;; The command a state asks the shell for. The payloads come from the list
  ;; and the state's data.
  (define (state-command ms s)
    (let ((d (cdr s)))
      (case (car s)
        ((peek-opening) (list 'open-read-only))
        ((peeking looking relooking) (list 'read-facts))
        ((reopening closing) (list 'close))
        ((opening) (list 'open-read-write))
        ((converting) (list 'set-wal))
        ((pausing) (cons 'pause 100))
        ((locking) (list 'begin-immediate))
        ((applying) (cons 'run-statement (statement-sql ms (d-k d) (d-i d))))
        ((checking) (list 'foreign-key-check))
        ((stamping) (cons 'stamp (d-k d)))
        ((committing) (list 'commit))
        ((undoing-to-look undoing-to-fail) (list 'rollback))
        ((ended) (cons 'end d))
        (else (assertion-violation 'state-command "not a state" s)))))

  ;;; The run machine's rows

  ;; Update helpers: (Data Event -> Data)
  (define (same d e) d)
  (define (to-pending p)               ; heads for closing with a pending
    (lambda (d e) (with-pending d (p d e))))

  ;; cannot-open : Data Event -> Result
  ;; A run that ends before any connection is open: the Result at once.
  (define (cannot-open d e)
    (list 'cannot-open (d-committed d) (d-converted d) (reason e)))

  ;; finish : Data Event -> Result
  (define (finish d e)
    (let ((p (d-pending d)))
      (unless p
        (assertion-violation 'finish "closing with no pending result" d))
      (list (car p) (d-committed d) (d-converted d) (cdr p))))

  ;; run-rows : (Listof Row)
  ;; Row is (List StateKind EventKind StateKind CommandKind Update); the
  ;; command kind is the next state's command.
  (define run-rows
    (list
     ;; R1
     (list 'peek-opening 'opened 'peeking 'read-facts same)
     ;; R2
     (list 'peek-opening 'missing 'opening 'open-read-write same)
     ;; R3
     (list 'peek-opening 'failed 'ended 'end cannot-open)
     ;; R4
     (list 'peeking 'current 'closing 'close
           (to-pending (lambda (d e) (cons 'nothing (cadr (e-value e))))))
     ;; R5
     (list 'peeking 'refused 'closing 'close
           (to-pending (lambda (d e) (cons 'refused (e-dbstate e)))))
     ;; R6
     (list 'peeking 'work 'reopening 'close same)
     ;; R7
     (list 'peeking 'failed 'closing 'close
           (to-pending (lambda (d e) (failed-pending #f e #f))))
     ;; R8
     (list 'reopening 'done 'opening 'open-read-write same)
     (list 'reopening 'failed 'opening 'open-read-write same)
     ;; R9
     (list 'opening 'opened 'looking 'read-facts same)
     ;; R10
     (list 'opening 'failed 'ended 'end cannot-open)
     ;; R11
     (list 'looking 'unconverted 'converting 'set-wal same)
     ;; R12: the file is at k - 1; k is its version plus one
     (list 'looking 'pending 'locking 'begin-immediate
           (lambda (d e)
             (let* ((st (e-dbstate e))
                    (k (if (eq? st 'fresh) 1 (+ (cadr st) 1))))
               (mk k 1 (d-committed d) (d-converted d) (d-tries d) (d-pending d)))))
     ;; R13: applied only if this run committed something
     (list 'looking 'current 'closing 'close
           (to-pending (lambda (d e)
                         (cons (if (null? (d-committed d)) 'nothing 'applied)
                               (cadr (e-value e))))))
     ;; R14
     (list 'looking 'refused 'closing 'close
           (to-pending (lambda (d e) (cons 'refused (e-dbstate e)))))
     ;; R15
     (list 'looking 'failed 'closing 'close
           (to-pending (lambda (d e) (failed-pending #f e #f))))
     ;; R16
     (list 'converting 'converted 'looking 'read-facts
           (lambda (d e)
             (mk (d-k d) (d-i d) (d-committed d) #t (d-tries d) (d-pending d))))
     ;; R17
     (list 'converting 'busy-retry 'pausing 'pause
           (lambda (d e)
             (mk (d-k d) (d-i d) (d-committed d) (d-converted d)
                 (- (d-tries d) 1) (d-pending d))))
     ;; R18
     (list 'converting 'busy-none 'closing 'close
           (to-pending (lambda (d e) (cons 'busy (reason e)))))
     ;; R19
     (list 'converting 'failed 'closing 'close
           (to-pending (lambda (d e) (failed-pending #f e #f))))
     ;; R20
     (list 'pausing 'done 'looking 'read-facts same)
     ;; R20b: every command has a failed row
     (list 'pausing 'failed 'closing 'close
           (to-pending (lambda (d e) (failed-pending #f e #f))))
     ;; R21
     (list 'locking 'locked 'relooking 'read-facts same)
     ;; R22
     (list 'locking 'busy 'closing 'close
           (to-pending (lambda (d e) (cons 'busy (reason e)))))
     ;; R23
     (list 'locking 'failed 'closing 'close
           (to-pending (lambda (d e) (failed-pending #f e #f))))
     ;; R24: the look under the lock is the one acted on
     (list 'relooking 'pending 'applying 'run-statement same)
     ;; R25
     (list 'relooking 'changed 'undoing-to-look 'rollback same)
     ;; R26
     (list 'relooking 'failed 'undoing-to-fail 'rollback
           (to-pending (lambda (d e) (failed-pending (d-k d) e #f))))
     ;; R26b: the failure ended the transaction, so nothing is left to roll
     ;; back (as R36)
     (list 'relooking 'failed-ended 'closing 'close
           (to-pending (lambda (d e) (failed-pending (d-k d) e #f))))
     ;; R27
     (list 'applying 'more 'applying 'run-statement
           (lambda (d e)
             (mk (d-k d) (+ (d-i d) 1) (d-committed d) (d-converted d)
                 (d-tries d) (d-pending d))))
     ;; R28
     (list 'applying 'last 'checking 'foreign-key-check same)
     ;; R29
     (list 'applying 'txn-ended 'closing 'close
           (to-pending (lambda (d e)
                         (cons 'failed
                               (list (d-k d) "a statement ended the transaction"
                                     #f)))))
     ;; R35, R36 for applying
     (list 'applying 'failed 'undoing-to-fail 'rollback
           (to-pending (lambda (d e) (failed-pending (d-k d) e #f))))
     (list 'applying 'failed-ended 'closing 'close
           (to-pending (lambda (d e) (failed-pending (d-k d) e #f))))
     ;; R30
     (list 'checking 'clean 'stamping 'stamp same)
     ;; R31
     (list 'checking 'violations 'undoing-to-fail 'rollback
           (to-pending (lambda (d e)
                         (cons 'failed
                               (list (d-k d) "foreign key check found violations"
                                     #f)))))
     ;; R35, R36 for checking
     (list 'checking 'failed 'undoing-to-fail 'rollback
           (to-pending (lambda (d e) (failed-pending (d-k d) e #f))))
     (list 'checking 'failed-ended 'closing 'close
           (to-pending (lambda (d e) (failed-pending (d-k d) e #f))))
     ;; R32
     (list 'stamping 'stamped 'committing 'commit same)
     ;; R35, R36 for stamping
     (list 'stamping 'failed 'undoing-to-fail 'rollback
           (to-pending (lambda (d e) (failed-pending (d-k d) e #f))))
     (list 'stamping 'failed-ended 'closing 'close
           (to-pending (lambda (d e) (failed-pending (d-k d) e #f))))
     ;; R33: k is recorded as committed, and k + 1 is locked
     (list 'committing 'below 'locking 'begin-immediate
           (lambda (d e)
             (mk (+ (d-k d) 1) 1 (append (d-committed d) (list (d-k d)))
                 (d-converted d) (d-tries d) (d-pending d))))
     ;; R34
     (list 'committing 'latest 'closing 'close
           (lambda (d e)
             (mk (d-k d) (d-i d) (append (d-committed d) (list (d-k d)))
                 (d-converted d) (d-tries d) (cons 'applied (d-k d)))))
     ;; R35, R36 for committing: the failure was at COMMIT
     (list 'committing 'failed 'undoing-to-fail 'rollback
           (to-pending (lambda (d e) (failed-pending (d-k d) e #t))))
     (list 'committing 'failed-ended 'closing 'close
           (to-pending (lambda (d e) (failed-pending (d-k d) e #t))))
     ;; R37
     (list 'undoing-to-look 'done 'looking 'read-facts same)
     ;; R38
     (list 'undoing-to-look 'failed 'closing 'close
           (to-pending (lambda (d e) (failed-pending (d-k d) e #f))))
     ;; R39: done or failed, the pending failure stands
     (list 'undoing-to-fail 'done 'closing 'close same)
     (list 'undoing-to-fail 'failed 'closing 'close same)
     ;; R40: the Result
     (list 'closing 'done 'ended 'end finish)
     (list 'closing 'failed 'ended 'end finish)))

  ;; run-possible : (Listof (Pair StateKind (Listof EventKind)))
  ;; The event kinds event-kind can answer in each state. Not read off the
  ;; rows: a kind listed here with no row is an unlisted gap, and a row for a
  ;; kind not listed here is a listed-but-has-row problem.
  (define run-possible
    '((peek-opening opened missing failed)
      (peeking current refused work failed)
      (reopening done failed)
      (opening opened failed)
      (looking unconverted pending current refused failed)
      (converting converted busy-retry busy-none failed)
      (pausing done failed)
      (locking locked busy failed)
      (relooking pending changed failed failed-ended)
      (applying more last txn-ended failed failed-ended)
      (checking clean violations failed failed-ended)
      (stamping stamped failed failed-ended)
      (committing below latest failed failed-ended)
      (undoing-to-look done failed)
      (undoing-to-fail done failed)
      (closing done failed)))

  (define run-event-kinds
    '(opened missing failed failed-ended done current refused work unconverted
      pending converted busy-retry busy-none locked busy changed more last
      txn-ended clean violations stamped below latest))

  ;; cants-of : (Listof (Pair StateKind (Listof EventKind))) (Listof EventKind)
  ;;            -> (Listof (List StateKind EventKind String))
  (define (cants-of possible universe)
    (apply append
           (map (lambda (entry)
                  (map (lambda (e)
                         (list (car entry) e
                               (string-append "event-kind never answers "
                                              (symbol->string e) " in "
                                              (symbol->string (car entry)))))
                       (filter (lambda (e) (not (memq e (cdr entry)))) universe)))
                possible)))

  ;; run-cant-happen : (Listof (List StateKind EventKind String))
  (define run-cant-happen (cants-of run-possible run-event-kinds))

  ;;; The check machine's rows

  ;; check-verdict : Symbol String -> Verdict
  (define (refuse sym text) (list 'refuse sym text))

  (define (check-ahead-line e)
    (string-append "this binary is older than the database (version "
                   (number->string (cadr (e-dbstate e))) ")"))

  (define (verdict-row event sym text)
    (list 'peeking event 'closing 'close
          (lambda (d e) (refuse sym text))))

  ;; check-rows : (Listof Row)
  (define check-rows
    (list
     (list 'peek-opening 'opened 'peeking 'read-facts same)
     (list 'peek-opening 'missing 'ended 'end
           (lambda (d e)
             (refuse 'missing "the database file is missing: run `techo migrate`")))
     (list 'peek-opening 'failed 'ended 'end
           (lambda (d e)
             (refuse 'cannot-open
                     (string-append "cannot open the database: " (reason e)))))
     (list 'peeking 'serve 'closing 'close (lambda (d e) 'serve))
     (verdict-row 'fresh 'fresh
                  "the database is empty: run `techo migrate`")
     (verdict-row 'behind 'behind
                  "the database is behind this binary: run `techo migrate`")
     (verdict-row 'unconverted 'unconverted
                  "the database is not in WAL mode: run `techo migrate`")
     (list 'peeking 'ahead 'closing 'close
           (lambda (d e) (refuse 'ahead (check-ahead-line e))))
     (verdict-row 'foreign 'foreign "not Techo's database")
     (list 'peeking 'failed 'closing 'close
           (lambda (d e)
             (refuse 'failed
                     (string-append "cannot read the database: " (reason e)))))
     ;; the close's outcome never changes the verdict
     (list 'closing 'done 'ended 'end same)
     (list 'closing 'failed 'ended 'end same)))

  (define check-possible
    '((peek-opening opened missing failed)
      (peeking serve fresh behind unconverted ahead foreign failed)
      (closing done failed)))

  (define check-event-kinds
    '(opened missing failed serve fresh behind unconverted ahead foreign done))

  ;; check-cant-happen : (Listof (List StateKind EventKind String))
  (define check-cant-happen (cants-of check-possible check-event-kinds))

  ;;; Event kinds

  ;; look-state : Symbol (Listof Migration) Any -> (Values DbFacts DbState)
  (define (look who ms v)
    (check-facts who v)
    (values v (classify v ms)))

  ;; failed-kind : RawOutcome -> (U 'failed 'failed-ended)
  (define (failed-kind raw)
    (if (caddr raw) 'failed 'failed-ended))

  ;; event-kind : (Listof Migration) State RawOutcome -> EventKind
  ;; Sorts a raw outcome by the state it answers. Raises on a malformed
  ;; outcome, and on `ended`, which takes no event.
  (define (event-kind ms state raw)
    (check-raw 'event-kind raw)
    (let* ((s (car raw)) (v (cadr raw)) (open? (caddr raw)) (ok? (eq? s 'ok))
           (d (cdr state)))
      (case (car state)
        ((peek-opening)
         (case s ((ok) 'opened) ((missing) 'missing) (else 'failed)))
        ((peeking)
         (if ok?
             (let-values (((f st) (look 'event-kind ms v)))
               (cond ((or (eq? st 'foreign) (and (pair? st) (eq? (car st) 'ahead)))
                      'refused)
                     ((and (eq? st 'current) (facts-wal? f)) 'current)
                     (else 'work)))
             'failed))
        ((looking)
         (if ok?
             (let-values (((f st) (look 'event-kind ms v)))
               (cond ((or (eq? st 'foreign) (and (pair? st) (eq? (car st) 'ahead)))
                      'refused)
                     ((not (facts-wal? f)) 'unconverted)
                     ((eq? st 'current) 'current)
                     (else 'pending)))
             'failed))
        ((relooking)
         (cond ((not ok?) (failed-kind raw))
               ((not open?) 'failed-ended)
               (else
                (let-values (((f st) (look 'event-kind ms v)))
                  (if (and (facts-wal? f)
                           (or (and (eq? st 'fresh) (= (d-k d) 1))
                               (and (pair? st) (eq? (car st) 'behind)
                                    (= (cadr st) (- (d-k d) 1)))))
                      'pending
                      'changed)))))
        ((converting)
         (case s
           ((ok) 'converted)
           ((busy) (if (> (d-tries d) 0) 'busy-retry 'busy-none))
           (else 'failed)))
        ((locking)
         (case s ((ok) 'locked) ((busy) 'busy) (else 'failed)))
        ((applying)
         (cond ((not ok?) (failed-kind raw))
               ((not open?) 'txn-ended)
               ((< (d-i d) (length (caddr (migration-ref ms (d-k d))))) 'more)
               (else 'last)))
        ((checking)
         (cond ((not ok?) (failed-kind raw))
               ((not open?) 'failed-ended)
               ((not (list? v))
                (assertion-violation 'event-kind "violations must be a list" v))
               ((null? v) 'clean)
               (else 'violations)))
        ((stamping)
         (cond ((not ok?) (failed-kind raw))
               ((not open?) 'failed-ended)
               (else 'stamped)))
        ((committing)
         (cond ((not ok?) (failed-kind raw))
               (open? 'failed)
               ((< (d-k d) (latest-version ms)) 'below)
               (else 'latest)))
        ((reopening undoing-to-look undoing-to-fail closing pausing)
         (if ok? 'done 'failed))
        ((opening) (if ok? 'opened 'failed))
        (else (assertion-violation 'event-kind "no event for this state" state)))))

  ;; check-event-kind : (Listof Migration) State RawOutcome -> EventKind
  ;; A file's current and in WAL is `serve`; behind, ahead, fresh and foreign
  ;; keep their names whatever the journal mode; a current file not in WAL is
  ;; `unconverted`.
  (define (check-event-kind ms state raw)
    (check-raw 'check-event-kind raw)
    (let ((s (car raw)) (v (cadr raw)))
      (case (car state)
        ((peek-opening)
         (case s ((ok) 'opened) ((missing) 'missing) (else 'failed)))
        ((peeking)
         (if (eq? s 'ok)
             (let-values (((f st) (look 'check-event-kind ms v)))
               (cond ((eq? st 'foreign) 'foreign)
                     ((eq? st 'fresh) 'fresh)
                     ((pair? st) (if (eq? (car st) 'ahead) 'ahead 'behind))
                     ((facts-wal? f) 'serve)
                     (else 'unconverted)))
             'failed))
        ((closing) (if (eq? s 'ok) 'done 'failed))
        (else (assertion-violation 'check-event-kind
                                   "no event for this state" state)))))

  ;;; The steppers

  (define look-states '(peeking looking relooking))

  ;; make-stepper : (Listof Row) ((Listof Migration) State RawOutcome -> EventKind)
  ;;                -> ((Listof Migration) State RawOutcome -> (values State Command))
  ;; The step function over ROWS, sorting outcomes with EVENT-KIND. The
  ;; command is the next state's, with payloads from the list and the data.
  (define (make-stepper rows kind-of)
    (let ((m (make-machine rows)))
      (lambda (ms state raw)
        (let* ((kind (kind-of ms state raw))
               (dbstate (if (and (memq (car state) look-states)
                                 (eq? (car raw) 'ok))
                            (classify (cadr raw) ms)
                            #f))
               (event (cons kind (list (car raw) (cadr raw) (caddr raw) dbstate))))
          (let-values (((next ignored) (machine-step m state event)))
            (values next (state-command ms next)))))))

  ;; run-start, check-start : -> (values State Command)
  (define (run-start)
    (let ((s (cons 'peek-opening initial-data)))
      (values s (state-command migrations s))))
  (define (check-start)
    (let ((s (cons 'peek-opening '())))
      (values s (state-command migrations s))))

  ;; run-step, check-step :
  ;;   (Listof Migration) State RawOutcome -> (values State Command)
  (define run-step (make-stepper run-rows event-kind))
  (define check-step (make-stepper check-rows check-event-kind))

  ;;; Results

  ;; result->exit-status : Result -> (U 0 1)
  (define (result->exit-status r)
    (case (car r)
      ((applied nothing) 0)
      ((refused failed busy cannot-open) 1)
      (else (assertion-violation 'result->exit-status "not a Result" r))))

  ;; result-parts : Symbol Result -> (values Symbol (Listof Integer) Boolean Any)
  ;; The Result's kind, committed versions, converted flag and detail;
  ;; raises, naming WHO, on anything else.
  (define (result-parts who r)
    (unless (and (list? r) (= (length r) 4)
                 (memq (car r) '(applied nothing refused failed busy cannot-open)))
      (assertion-violation who "not a Result" r))
    (values (car r) (cadr r) (caddr r) (cadddr r)))

  ;; result->progress-lines : Result -> (Listof String)
  ;; What the run did, in order: the conversion if it did it, then a line
  ;; for each version whose COMMIT answered ok.
  (define (result->progress-lines r)
    (let-values (((kind committed converted detail)
                  (result-parts 'result->progress-lines r)))
      (append
       (if converted (list "converted the database to WAL") '())
       (map (lambda (v) (string-append "applied migration " (number->string v)))
            committed))))

  ;; result->ending-lines : Result -> (Listof String)
  ;; How the run ended: the line for its kind, and after a COMMIT that
  ;; failed, that the version is unknown.
  (define (result->ending-lines r)
    (let-values (((kind committed converted detail)
                  (result-parts 'result->ending-lines r)))
      (case kind
        ((applied)
         (list (string-append "the database is at version "
                              (number->string detail))))
        ((nothing)
         (list (string-append "nothing to do: the database is at version "
                              (number->string detail))))
        ((refused)
         (if (eq? detail 'foreign)
             (list "refused: not Techo's database")
             (list (string-append "refused: this binary is older than the "
                                  "database (version "
                                  (number->string (cadr detail)) ")"))))
        ((failed)
         (let ((k (car detail)) (why (cadr detail)) (commit? (caddr detail)))
           (cons (if k
                     (string-append "failed: migration " (number->string k)
                                    ": " why)
                     (string-append "failed: " why))
                 (if commit?
                     (list (string-append "the database's version is unknown:"
                                          " run `techo migrate` again"))
                     '()))))
        ((busy) (list (string-append "busy: " detail)))
        (else
         (list (string-append "cannot open the database: " detail))))))

  ;; result->lines : Result -> (Listof String)
  ;; The progress lines, then the ending lines.
  (define (result->lines r)
    (result-parts 'result->lines r)
    (append (result->progress-lines r) (result->ending-lines r)))

  ;;; The diagrams

  ;; machines-document : -> String
  ;; The text of .plans/machines/migrate.md, rendered from the two tables.
  (define (machines-document)
    (string-append
     "# The migrate machines\n\n"
     "Generated from the tables in `src/techo/migrations.sls`. Do not edit.\n"
     "Regenerate with `scripts/guix-env make machines`; "
     "a test fails when this file differs.\n\n"
     "## `techo migrate`: the run machine\n\n"
     "```mermaid\n"
     (machine->mermaid (make-machine run-rows))
     "```\n\n"
     "## `techo serve`: the check machine\n\n"
     "```mermaid\n"
     (machine->mermaid (make-machine check-rows))
     "```\n"))
)
