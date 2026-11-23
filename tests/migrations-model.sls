#!r6rs
;;; (migrations-model): a pure model of a database file, its write lock and
;;; the connections on it. Layer 3 of the slice 2 plan explores the real
;;; `techo migrate` step function against it, and layer 4 replays its
;;; traces on real SQLite.
;;;
;;; Test-only: it lives in tests/, which make test puts on Chez's library
;;; path. Pure: no clock, no file, no SQLite. The one side effect is the
;;; observer a caller may pass to model-next.
;;;
;;; The shapes
;;; ----------
;;; File   #(exists? id version mode log extra hash)
;;;          log: the effects committed, oldest first. An effect is the
;;;          symbol of the SQL that made it. The id statement's effect sets
;;;          the id and makes no schema object; any other statement makes
;;;          one. extra: schema objects no migration made (another
;;;          program's tables). hash: a cache of the rest.
;;; Actor  #(state command conn txn? unc-log unc-id unc-version commits
;;;          rollback-failed? hash)
;;;          a run (actors 0 and 1) or serve's check (actor 2): its machine
;;;          state; the command it has asked for and not yet had answered;
;;;          its connection, none, ro or rw; whether it has a transaction
;;;          open, and in it the effects, id and stamp only it sees.
;;;          Ghosts: commits, the versions whose COMMIT answered it ok
;;;          (M11); rollback-failed?, a ROLLBACK answered failed and left
;;;          the transaction open (M10).
;;;          An actor that has ended stays for the one world in which it
;;;          ended, where the invariant reads its Result, and is swept out
;;;          at the next step; a run that dies is gone at once. Either way
;;;          it holds nothing and can do nothing, so worlds that differ only
;;;          in it are one world, and a cycle among merged worlds is a cycle
;;;          among the worlds they stand for.
;;; World  #(hash file lock a0 a1 a2 g5 g7 g12 max-version)
;;;          a1 is #f with one run, a2 #f without serve or once it is gone.
;;;          lock: the index of the actor holding the write lock, or #f.
;;;          Ghosts, each set only when something goes wrong, or with the
;;;          file: g5, an ahead or foreign file was opened read-write or
;;;          written (M5); g7, a death changed the file (M7); g12, serve's
;;;          check opened read-write, created or wrote the file (M12);
;;;          max-version, the highest version the file has had (M4).
;;;
;;; Worlds are compared with equal?. Chez's equal-hash looks only at the
;;; first few dozen nodes of a structure, so each file, actor and world
;;; carries a hash of all of itself.
;;;
;;; What each command does (the plan's clauses)
;;; -------------------------------------------
;;; A choice is how the call went. ok and missing are the nominal ones; the
;;; rest are failures (ML2's "no failure"):
;;;   ok           as asked
;;;   missing      a read-only open of a file that is not there
;;;   fail         fails and changes nothing: a transaction stays open
;;;   fail-ended   fails, and the open transaction is rolled back (cl. 5)
;;;   ok-ended     a statement answers ok but its transaction is gone,
;;;                rolled back (R29). A migration holds no COMMIT, so a
;;;                statement never ends one by committing.
;;;   busy         at BEGIN IMMEDIATE only while another actor holds the
;;;                lock (cl. 3); at the conversion only while another holds
;;;                the lock or is itself converting (cl. 8); at a write
;;;                outside a transaction only while another holds the lock
;;;   violations   PRAGMA foreign_key_check names a dangling row (cl. 10)
;;;   took-effect  a COMMIT that answered failed but committed
;;;   die          (a step's choice only, from model-die) the run's process
;;;                dies
;;; Every command is defined in every situation, outside a transaction and
;;; on a read-only connection too:
;;; - opens: read-only never creates (cl. 9); read-write creates a missing
;;;   file, fresh and not in WAL (cl. 7). An open while a connection is
;;;   held first closes it, as close does.
;;; - read-facts: what the connection sees: the committed file, and its own
;;;   transaction's effects, id and stamp on top (cl. 4).
;;; - close: rolls back a transaction, frees the lock. A read-write close
;;;   counts as writing the main file: it may checkpoint a leftover -wal.
;;; - set-wal: a no-op on a file in WAL. Otherwise it fails on a read-only
;;;   connection and inside a transaction, and converts the file.
;;; - begin-immediate: fails on a read-only connection and inside a
;;;   transaction; else takes the lock.
;;; - run-statement, stamp: inside a transaction they change only what the
;;;   run sees. Outside one they commit at once (autocommit), busy while
;;;   another holds the lock; read-only, they fail.
;;; - commit, rollback: with no transaction they fail. A failed ROLLBACK may
;;;   leave the transaction open or end it.
;;; - a death drops the connection: its transaction and lock are gone, and
;;;   no checkpoint runs (cl. 6).
;;; Statements are tokens: the model knows only the id statement, which
;;; sets the application id.
;;;
;;; Two reductions of the explorer's graph, both sound for M1 to ML3:
;;; - A read-only open of a file that exists, a pause, and a close by an
;;;   actor holding no lock and no transaction change nothing any other
;;;   actor or property reads, and depend on nothing they change. While an
;;;   actor has asked for one, its steps are the only next steps (an ample
;;;   set of one actor, as in partial-order reduction), so every look and
;;;   every write still lands at every point. A read-write open, a missing
;;;   file, and a read-write close of an ahead or foreign file, or by serve,
;;;   are not reduced.
;;; - ML2 is checked on its own graph, the nominal one: every call goes its
;;;   nominal way and no run dies. A run that can only be told busy waits;
;;;   a call that can only fail fails, as the machine asked for it.
(library (migrations-model)
  (export
   ;; configurations
   make-config config-name config-migrations config-latest config-start-file
   config-start-class config-runs config-serve? config-model-mutant
   config-with-model-mutant config-with-unchecked config-with-cap
   start-file start-names model-id-statement effect-statement
   ;; files
   model-file-exists? model-file-id model-file-version model-file-mode
   model-file-log model-file-extra model-file-objects model-file-facts
   ;; machines
   make-model-machine real-machine machine-name
   ;; worlds and actors
   model-start world-file world-lock world-actor
   actor-state actor-command actor-conn actor-txn? actor-commits
   ;; semantics
   model-choices model-perform model-die model-apply
   ;; exploration
   model-next model-invariant model-final model-lone-run model-explore
   ;; traces
   model-walk model-traces
   step-who step-choice step-command step-raw step-row step-state step-file)
  (import (rnrs)
          (techo migrations)
          (explore))

  (define T techo-application-id)

  ;; model-id-statement : String
  ;; Migration 1's statement, as (techo migrations) builds it.
  (define model-id-statement
    (string-append "PRAGMA application_id = " (number->string T)))
  (define id-token (string->symbol model-id-statement))

  ;; effect-statement : Positive-Integer Positive-Integer -> String
  ;; The model's statement i of migration k: a token that makes one object.
  (define (effect-statement k i)
    (string-append "effect " (number->string k) "." (number->string i)))

  ;;; Hashing

  (define (mix h x) (mod (+ (* h 31) x) 536870909))
  (define (atom-code x)
    (cond ((eq? x #t) 1) ((eq? x #f) 2) ((null? x) 3)
          ((symbol? x) (mod (symbol-hash x) 16777213))
          ((string? x) (mod (string-hash x) 16777213))
          ((and (integer? x) (exact? x)) (mod x 16777213))
          (else (mod (equal-hash x) 16777213))))
  ;; deep-hash : Any Integer -> Integer
  ;; Over the whole structure, with no budget.
  (define (deep-hash x h)
    (cond ((pair? x) (deep-hash (cdr x) (deep-hash (car x) (mix h 5))))
          ((vector? x)
           (let loop ((i 0) (h (mix h 7)))
             (if (= i (vector-length x)) h (loop (+ i 1) (deep-hash (vector-ref x i) h)))))
          (else (mix h (atom-code x)))))

  ;;; Files

  ;; Files and actors are interned: an equal one made again is the one made
  ;; first, so equal? on worlds, which tries eq? first at each node, mostly
  ;; stops at once. A cache only: model-explore and model-traces empty it.
  (define file-table (make-hashtable (lambda (f) (vector-ref f 6)) equal?))
  (define actor-table (make-hashtable (lambda (a) (vector-ref a 9)) equal?))
  (define (intern table x)
    (or (hashtable-ref table x #f)
        (begin (hashtable-set! table x x) x)))
  (define (forget!)
    (hashtable-clear! file-table)
    (hashtable-clear! actor-table))

  (define (make-file exists id ver mode log extra)
    (intern file-table
            (vector exists id ver mode log extra
                    (deep-hash extra (deep-hash log (deep-hash mode (deep-hash ver
                      (deep-hash id (deep-hash exists 11)))))))))
  (define missing-file (make-file #f 0 0 'delete '() 0))
  (define fresh-file (make-file #t 0 0 'delete '() 0))
  (define (file-hash f) (vector-ref f 6))

  ;; model-file-exists? : File -> Boolean
  ;; model-file-id : File -> Integer
  ;; model-file-version : File -> Integer
  ;; model-file-mode : File -> (U 'wal 'delete)
  ;; model-file-log : File -> (Listof Symbol)    the effects, oldest first
  ;; model-file-extra : File -> Natural          objects no migration made
  (define (model-file-exists? f) (vector-ref f 0))
  (define (model-file-id f) (vector-ref f 1))
  (define (model-file-version f) (vector-ref f 2))
  (define (model-file-mode f) (vector-ref f 3))
  (define (model-file-log f) (vector-ref f 4))
  (define (model-file-extra f) (vector-ref f 5))

  ;; count-objects : (Listof Symbol) -> Natural
  (define (count-objects log)
    (fold-left (lambda (n t) (if (eq? t id-token) n (+ n 1))) 0 log))

  ;; model-file-objects : File -> Natural
  ;; The schema's object count, as the facts read it.
  (define (model-file-objects f)
    (+ (model-file-extra f) (count-objects (model-file-log f))))

  ;; model-file-facts : File -> (U DbFacts #f)
  ;; The facts a connection outside a transaction reads: (id version objects
  ;; mode), or #f for a file that is not there.
  (define (model-file-facts f)
    (and (model-file-exists? f)
         (list (model-file-id f) (model-file-version f) (model-file-objects f)
               (model-file-mode f))))

  (define (file-with-mode f m)
    (make-file #t (model-file-id f) (model-file-version f) m (model-file-log f)
               (model-file-extra f)))
  (define (file-with-version f v)
    (make-file #t (model-file-id f) v (model-file-mode f) (model-file-log f)
               (model-file-extra f)))
  ;; file-add : File (Listof Symbol) (U Integer #f) (U Integer #f) Boolean -> File
  ;; The effects appended (prepended when FIRST?), and the id and version
  ;; set when given.
  (define (file-add f toks id ver first?)
    (if (and (null? toks) (not id) (not ver))
        f
        (make-file #t (or id (model-file-id f)) (or ver (model-file-version f))
                   (model-file-mode f)
                   (if first?
                       (append toks (model-file-log f))
                       (append (model-file-log f) toks))
                   (model-file-extra f))))

  ;;; Configurations

  ;; Config is #(name ms latest start-file start-class runs serve? mutant
  ;;             tokens unchecked cap)
  ;; tokens: ((Symbol . k) ...), each statement's effect and its migration.
  ;; mutant: #f, or a model mutant for the suite's own checks:
  ;;   death-commits    a death commits the run's open transaction
  ;;   commit-prepends  a COMMIT puts its effects before the file's
  ;; unchecked: the numbers of properties not to check, 1 to 12, and 101 to
  ;; 103 for ML1 to ML3: to see which others a mutant breaks. () by default.
  ;; cap: #f, or the most worlds model-next may expand before it raises,
  ;; so that a mutant whose graph is infinite fails instead of hanging.

  ;; make-config : Any (Listof Migration) File (U 1 2) Boolean -> Config
  (define (make-config name ms start runs serve?)
    (unless (memv runs '(1 2))
      (assertion-violation 'make-config "one run or two" runs))
    (vector name ms (latest-version ms) start (file-class start ms) runs
            serve? #f
            (apply append
                   (map (lambda (m)
                          (map (lambda (sql) (cons (string->symbol sql) (car m)))
                               (caddr m)))
                        ms))
            '() #f))

  ;; config-name : Config -> Any
  ;; config-migrations : Config -> (Listof Migration)
  ;; config-latest : Config -> Natural
  ;; config-start-file : Config -> File
  ;; config-start-class : Config -> (U 'missing 'fresh 'behind 'current
  ;;                                   'ahead 'foreign)
  ;; config-runs : Config -> (U 1 2)
  ;; config-serve? : Config -> Boolean
  ;; config-model-mutant : Config -> (U #f Symbol)
  (define (config-name c) (vector-ref c 0))
  (define (config-migrations c) (vector-ref c 1))
  (define (config-latest c) (vector-ref c 2))
  (define (config-start-file c) (vector-ref c 3))
  (define (config-start-class c) (vector-ref c 4))
  (define (config-runs c) (vector-ref c 5))
  (define (config-serve? c) (vector-ref c 6))
  (define (config-model-mutant c) (vector-ref c 7))
  (define (config-tokens c) (vector-ref c 8))
  (define (config-unchecked c) (vector-ref c 9))
  (define (config-cap c) (vector-ref c 10))

  ;; config-set : Config Natural Any -> Config
  (define (config-set c i x)
    (let ((v (vector-map (lambda (y) y) c)))
      (vector-set! v i x)
      v))
  ;; config-with-model-mutant : Config Symbol -> Config
  (define (config-with-model-mutant c mutant) (config-set c 7 mutant))
  ;; config-with-unchecked : Config (Listof Natural) -> Config
  (define (config-with-unchecked c ns) (config-set c 9 ns))
  ;; config-with-cap : Config (U #f Natural) -> Config
  (define (config-with-cap c n) (config-set c 10 n))

  ;; file-class : File (Listof Migration) -> Symbol
  (define (file-class f ms)
    (if (not (model-file-exists? f))
        'missing
        (let ((st (classify (model-file-facts f) ms)))
          (if (pair? st) (car st) st))))
  (define (refused-class? k) (and (memq k '(ahead foreign)) #t))
  (define (refused-file? c f)
    (and (model-file-exists? f)
         (refused-class? (file-class f (config-migrations c)))))
  (define (current-wal? c f)
    (and (model-file-exists? f)
         (eq? (file-class f (config-migrations c)) 'current)
         (eq? (model-file-mode f) 'wal)))

  ;; expected-log : (Listof Migration) Natural -> (Listof Symbol)
  ;; The effects of migrations 1 to v, in order.
  (define (expected-log ms v)
    (apply append
           (map (lambda (m) (map string->symbol (caddr m)))
                (filter (lambda (m) (<= (car m) v)) ms))))

  ;; start-names : (Listof Migration) -> (Listof StartName)
  ;; StartName is 'missing or (List Kind Mode), Mode 'wal or 'delete, Kind
  ;; fresh, (behind v) for each v from 1 to latest - 1, current, ahead, or
  ;; one of the five foreign shapes: other-id, schema-no-id,
  ;; version-no-id, techo-v0, negative.
  (define (start-names ms)
    (let ((latest (latest-version ms)))
      (cons 'missing
            (apply append
                   (map (lambda (kind) (list (list kind 'wal) (list kind 'delete)))
                        (append
                         (list 'fresh)
                         (let loop ((v (- latest 1)) (acc '()))
                           (if (< v 1) acc (loop (- v 1) (cons (list 'behind v) acc))))
                         (list 'current 'ahead 'other-id 'schema-no-id 'version-no-id
                               'techo-v0 'negative)))))))

  ;; start-file : (Listof Migration) StartName -> File
  ;; An ahead file holds the effects of 1 to latest and one more, of a
  ;; migration this list does not know.
  (define (start-file ms name)
    (if (eq? name 'missing)
        missing-file
        (let ((kind (car name)) (mode (cadr name)) (latest (latest-version ms)))
          (cond
           ((eq? kind 'fresh) (make-file #t 0 0 mode '() 0))
           ((and (pair? kind) (eq? (car kind) 'behind))
            (make-file #t T (cadr kind) mode (expected-log ms (cadr kind)) 0))
           ((eq? kind 'current) (make-file #t T latest mode (expected-log ms latest) 0))
           ((eq? kind 'ahead)
            (make-file #t T (+ latest 1) mode
                       (append (expected-log ms latest)
                               (list (string->symbol (effect-statement (+ latest 1) 1))))
                       0))
           ((eq? kind 'other-id) (make-file #t 7 0 mode '() 1))
           ((eq? kind 'schema-no-id) (make-file #t 0 0 mode '() 1))
           ((eq? kind 'version-no-id) (make-file #t 0 2 mode '() 0))
           ((eq? kind 'techo-v0) (make-file #t T 0 mode '() 0))
           ((eq? kind 'negative) (make-file #t T -1 mode '() 0))
           (else (assertion-violation 'start-file "not a start" name))))))

  ;;; Machines

  ;; Machine is #(name run-start run-step run-kind check-start check-step
  ;;              check-kind)
  ;;   run-start, check-start : -> (values State Command)
  ;;   run-step, check-step : (Listof Migration) State RawOutcome
  ;;                          -> (values State Command)
  ;;   run-kind, check-kind : (Listof Migration) State RawOutcome -> EventKind
  ;; The kinds are what the steppers sort outcomes with: the explorer reads
  ;; them only to name the row each step fires.

  ;; make-model-machine : Any (-> (values State Command)) Stepper Classifier
  ;;                      (-> (values State Command)) Stepper Classifier
  ;;                      -> Machine
  (define (make-model-machine name rs rstep rkind cs cstep ckind)
    (vector name rs rstep rkind cs cstep ckind))
  ;; machine-name : Machine -> Any
  (define (machine-name m) (vector-ref m 0))
  (define (machine-run-start m) (vector-ref m 1))
  (define (machine-run-step m) (vector-ref m 2))
  (define (machine-run-kind m) (vector-ref m 3))
  (define (machine-check-start m) (vector-ref m 4))
  (define (machine-check-step m) (vector-ref m 5))
  (define (machine-check-kind m) (vector-ref m 6))

  ;; real-machine : Machine
  ;; (techo migrations)'s own, unmutated.
  (define real-machine
    (make-model-machine 'real run-start run-step event-kind
                        check-start check-step check-event-kind))

  ;;; Actors

  (define (make-actor state command conn txn unc-log unc-id unc-ver commits
                      rbfail)
    (intern actor-table
            (vector state command conn txn unc-log unc-id unc-ver commits rbfail
                    (deep-hash rbfail (deep-hash commits (deep-hash unc-ver
                      (deep-hash unc-id (deep-hash unc-log (deep-hash txn (deep-hash conn
                        (deep-hash command (deep-hash state 13))))))))))))
  (define (actor-hash a) (if a (vector-ref a 9) 0))

  ;; actor-state : Actor -> State
  ;; actor-command : Actor -> Command        asked for, not yet answered
  ;; actor-conn : Actor -> (U 'none 'ro 'rw)
  ;; actor-txn? : Actor -> Boolean
  ;; actor-commits : Actor -> (Listof Integer)  versions whose COMMIT
  ;;                                            answered ok, in order
  (define (actor-state a) (vector-ref a 0))
  (define (actor-command a) (vector-ref a 1))
  (define (actor-conn a) (vector-ref a 2))
  (define (actor-txn? a) (vector-ref a 3))
  (define (a-unc-log a) (vector-ref a 4))
  (define (a-unc-id a) (vector-ref a 5))
  (define (a-unc-ver a) (vector-ref a 6))
  (define (actor-commits a) (vector-ref a 7))
  (define (a-rbfail a) (vector-ref a 8))

  (define (new-actor state command)
    (make-actor state command 'none #f '() #f #f '() #f))
  (define (actor-with-state a s cmd)
    (make-actor s cmd (actor-conn a) (actor-txn? a) (a-unc-log a) (a-unc-id a)
                (a-unc-ver a) (actor-commits a) (a-rbfail a)))
  ;; a connection opened or closed: no transaction on it
  (define (actor-with-conn a conn)
    (make-actor (actor-state a) (actor-command a) conn #f '() #f #f
                (actor-commits a) (a-rbfail a)))
  ;; the transaction gone: its effects, id and stamp with it
  (define (actor-end-txn a)
    (make-actor (actor-state a) (actor-command a) (actor-conn a) #f '() #f #f
                (actor-commits a) (a-rbfail a)))
  (define (actor-closed a) (actor-with-conn a 'none))
  (define (actor-begin a)
    (make-actor (actor-state a) (actor-command a) (actor-conn a) #t '() #f #f
                (actor-commits a) (a-rbfail a)))
  (define (actor-add-effect a tok id?)
    (make-actor (actor-state a) (actor-command a) (actor-conn a) #t
                (append (a-unc-log a) (list tok)) (if id? T (a-unc-id a))
                (a-unc-ver a) (actor-commits a) (a-rbfail a)))
  (define (actor-stamp a k)
    (make-actor (actor-state a) (actor-command a) (actor-conn a) #t (a-unc-log a)
                (a-unc-id a) k (actor-commits a) (a-rbfail a)))
  (define (actor-add-commit a v)
    (make-actor (actor-state a) (actor-command a) (actor-conn a) (actor-txn? a)
                (a-unc-log a) (a-unc-id a) (a-unc-ver a)
                (append (actor-commits a) (list v)) (a-rbfail a)))
  (define (actor-rollback-failed a)
    (make-actor (actor-state a) (actor-command a) (actor-conn a) (actor-txn? a)
                (a-unc-log a) (a-unc-id a) (a-unc-ver a) (actor-commits a) #t))
  (define (finished? a) (eq? (car (actor-command a)) 'end))

  ;;; Worlds

  (define (make-world f lock a0 a1 a2 g5 g7 g12 mv)
    (vector (mix (mix (mix (mix (mix (mix (mix (mix (mix 19 (file-hash f))
                                                     (atom-code lock))
                                                (actor-hash a0))
                                           (actor-hash a1))
                                      (actor-hash a2))
                                 (atom-code g5))
                            (atom-code g7))
                       (atom-code g12))
                  (atom-code mv))
            f lock a0 a1 a2 g5 g7 g12 mv))

  ;; world-file : World -> File
  ;; world-lock : World -> (U #f 0 1 2)
  ;; world-actor : World (U 0 1 2) -> (U Actor #f)   2 is serve's check
  (define (world-file w) (vector-ref w 1))
  (define (world-lock w) (vector-ref w 2))
  (define (world-actor w i) (vector-ref w (+ 3 i)))
  (define (world-g5 w) (vector-ref w 6))
  (define (world-g7 w) (vector-ref w 7))
  (define (world-g12 w) (vector-ref w 8))
  (define (world-maxver w) (vector-ref w 9))

  ;; world-replace : World File Lock Index (U Actor #f) Boolean Boolean
  ;;                 Boolean Integer -> World
  (define (world-replace w f lock i a g5 g7 g12 mv)
    (make-world f lock
                (if (= i 0) a (world-actor w 0))
                (if (= i 1) a (world-actor w 1))
                (if (= i 2) a (world-actor w 2))
                g5 g7 g12 mv))

  ;; model-start : Config Machine -> World
  (define (model-start c m)
    (let-values (((rs rc) ((machine-run-start m)))
                 ((cs cc) ((machine-check-start m))))
      (let ((f (config-start-file c)))
        (make-world f #f
                    (new-actor rs rc)
                    (and (= (config-runs c) 2) (new-actor rs rc))
                    (and (config-serve? c) (new-actor cs cc))
                    #f #f #f
                    (if (model-file-exists? f) (model-file-version f) 0)))))

  (define (release lock i) (if (eqv? lock i) #f lock))
  (define (other-holds? w i)
    (let ((l (world-lock w))) (and l (not (= l i)))))
  ;; other-converting? : World Index -> Boolean
  ;; Another actor is in the middle of setting WAL on a read-write
  ;; connection outside a transaction: its set-wal is asked for and not yet
  ;; answered.
  (define (other-converting? w i)
    (exists (lambda (j)
              (and (not (= j i))
                   (let ((b (world-actor w j)))
                     (and b
                          (eq? (car (actor-command b)) 'set-wal)
                          (eq? (actor-conn b) 'rw)
                          (not (actor-txn? b))))))
            '(0 1 2)))

  ;; view-facts : File Actor -> DbFacts
  ;; What the actor's connection reads: its own transaction on top.
  (define (view-facts f a)
    (if (actor-txn? a)
        (list (or (a-unc-id a) (model-file-id f))
              (or (a-unc-ver a) (model-file-version f))
              (+ (model-file-objects f) (count-objects (a-unc-log a)))
              (model-file-mode f))
        (model-file-facts f)))

  ;; commit-file : Config File Actor -> File
  (define (commit-file c f a)
    (file-add f (a-unc-log a) (a-unc-id a) (a-unc-ver a)
              (eq? (config-model-mutant c) 'commit-prepends)))

  ;;; The commands

  ;; model-choices : Config World (U 0 1 2) Command -> (Listof Choice)
  ;; The ways the command can go for actor I in W, nominal first. (end . R)
  ;; is not a shell call and has none. Raises on a command that is not one.
  (define (model-choices c w i cmd)
    (let* ((a (world-actor w i)) (f (world-file w)) (conn (actor-conn a))
           (txn (actor-txn? a)) (other-lock (other-holds? w i)))
      (define fails (if txn '(fail fail-ended) '(fail)))
      (case (car cmd)
        ((open-read-only) (if (model-file-exists? f) '(ok fail) '(missing fail)))
        ((open-read-write) '(ok fail))
        ((read-facts) (if (eq? conn 'none) '(fail) (cons 'ok fails)))
        ((close) (if (eq? conn 'none) '(ok) '(ok fail)))
        ((set-wal)
         (cond ((eq? conn 'none) '(fail))
               ((eq? (model-file-mode f) 'wal) (cons 'ok fails))
               ((or (eq? conn 'ro) txn) fails)
               (other-lock '(busy fail))
               ((other-converting? w i) '(ok busy fail))
               (else '(ok fail))))
        ((pause) '(ok fail))
        ((begin-immediate)
         (cond ((or (memq conn '(none ro)) txn) fails)
               (other-lock '(busy fail))
               (else '(ok fail))))
        ((run-statement)
         (cond ((memq conn '(none ro)) fails)
               (txn '(ok ok-ended fail fail-ended))
               (other-lock '(busy fail))
               (else '(ok fail))))
        ((foreign-key-check)
         (if (eq? conn 'none) '(fail) (cons 'ok (cons 'violations fails))))
        ((stamp)
         (cond ((memq conn '(none ro)) fails)
               (txn '(ok fail fail-ended))
               (other-lock '(busy fail))
               (else '(ok fail))))
        ((commit) (if txn '(ok fail fail-ended took-effect) '(fail)))
        ((rollback) (if txn '(ok fail fail-ended) '(fail)))
        ((end) '())
        (else (assertion-violation 'model-choices "not a command" cmd)))))

  (define (nominal? choice) (and (memq choice '(ok missing)) #t))

  (define raw-opened '(ok #t #f))
  (define raw-closed '(ok #t #f))
  (define raw-missing '(missing "unable to open database file: no such file" #f))
  (define raw-busy '(busy "database is locked" #f))
  (define violation-rows '(("child" 1 "parent" 0)))

  ;; why : Actor File Command -> String
  ;; The reason a failure gives: SQLite's, where the call cannot succeed.
  (define (why a f cmd)
    (let ((conn (actor-conn a)) (txn (actor-txn? a)))
      (case (car cmd)
        ((open-read-only open-read-write) "unable to open database file")
        ((close) "unable to close due to unfinalized statements")
        ((pause) "interrupted")
        (else
         (cond ((eq? conn 'none) "no connection")
               ((and (eq? conn 'ro)
                     (memq (car cmd) '(begin-immediate run-statement stamp))
                     (not txn))
                "attempt to write a readonly database")
               ((and (eq? (car cmd) 'set-wal) (not (eq? (model-file-mode f) 'wal)))
                (cond ((eq? conn 'ro) "attempt to write a readonly database")
                      (txn "cannot change into wal mode from within a transaction")
                      (else "disk I/O error")))
               ((and (eq? (car cmd) 'begin-immediate) txn)
                "cannot start a transaction within a transaction")
               ((and (eq? (car cmd) 'commit) (not txn))
                "cannot commit - no transaction is active")
               ((and (eq? (car cmd) 'rollback) (not txn))
                "cannot rollback - no transaction is active")
               (else "disk I/O error"))))))

  ;; perform* : Config World Index Command Choice
  ;;            -> (values File Lock Actor RawOutcome Boolean)
  ;; The file, the lock and actor I after the call, the outcome, and whether
  ;; the call wrote the main file or opened it read-write beyond what the
  ;; file shows (an open, a checkpoint). Nothing else in the world changes.
  ;; The choice must be one model-choices gives.
  (define (perform* c w i cmd choice)
    (let* ((a (world-actor w i)) (f (world-file w)) (lock (world-lock w))
           (txn (actor-txn? a)))
      (define (bad-choice)
        (assertion-violation 'model-perform "not a choice here" cmd choice))
      (define (keep raw) (values f lock a raw #f))
      (define (rolled-back raw)
        (values f (release lock i) (actor-end-txn a) raw #f))
      (define (failure)
        (case choice
          ((fail) (keep (list 'failed (why a f cmd) txn)))
          ((fail-ended) (if txn
                            (rolled-back (list 'failed (why a f cmd) #f))
                            (bad-choice)))
          ((busy) (keep raw-busy))
          (else (bad-choice))))
      ;; drop : -> (values File Lock Actor Boolean)  the connection closed
      (define (drop)
        (if (eq? (actor-conn a) 'none)
            (values f lock a #f)
            (values f (release lock i) (actor-closed a) (eq? (actor-conn a) 'rw))))
      (case (car cmd)
        ((open-read-only open-read-write)
         (let-values (((f lock a touched) (drop)))
           (let ((rw? (eq? (car cmd) 'open-read-write)))
             (case choice
               ((ok) (values (if (and rw? (not (model-file-exists? f))) fresh-file f)
                             lock (actor-with-conn a (if rw? 'rw 'ro)) raw-opened
                             (or touched rw?)))
               ((missing) (values f lock a raw-missing touched))
               ((fail) (values f lock a (list 'failed (why a f cmd) #f) touched))
               (else (bad-choice))))))
        ((read-facts)
         (if (and (eq? choice 'ok) (not (eq? (actor-conn a) 'none)))
             (keep (list 'ok (view-facts f a) txn))
             (failure)))
        ((close)
         (let-values (((f lock a touched) (drop)))
           (case choice
             ((ok) (values f lock a raw-closed touched))
             ((fail) (values f lock a (list 'failed (why a f cmd) #f) touched))
             (else (bad-choice)))))
        ((set-wal)
         (if (eq? choice 'ok)
             (if (eq? (model-file-mode f) 'wal)
                 (keep (list 'ok 'wal txn))
                 (values (file-with-mode f 'wal) lock a '(ok wal #f) #f))
             (failure)))
        ((pause)
         (case choice
           ((ok) (keep (list 'ok #t txn)))
           ((fail) (keep (list 'failed (why a f cmd) txn)))
           (else (bad-choice))))
        ((begin-immediate)
         (if (eq? choice 'ok)
             (values f i (actor-begin a) '(ok #t #t) #f)
             (failure)))
        ((run-statement)
         (let* ((sql (cdr cmd)) (tok (string->symbol sql))
                (id? (string=? sql model-id-statement)))
           (case choice
             ((ok) (if txn
                       (values f lock (actor-add-effect a tok id?) '(ok #t #t) #f)
                       (values (file-add f (list tok) (and id? T) #f #f) lock a
                               '(ok #t #f) #f)))
             ((ok-ended) (rolled-back '(ok #t #f)))
             (else (failure)))))
        ((foreign-key-check)
         (case choice
           ((ok) (keep (list 'ok '() txn)))
           ((violations) (keep (list 'ok violation-rows txn)))
           (else (failure))))
        ((stamp)
         (if (eq? choice 'ok)
             (if txn
                 (values f lock (actor-stamp a (cdr cmd)) '(ok #t #t) #f)
                 (values (file-with-version f (cdr cmd)) lock a '(ok #t #f) #f))
             (failure)))
        ((commit)
         (case choice
           ((ok) (let ((f2 (commit-file c f a)))
                   (values f2 (release lock i)
                           (actor-add-commit (actor-end-txn a) (model-file-version f2))
                           '(ok #t #f) #f)))
           ((took-effect)
            (values (commit-file c f a) (release lock i) (actor-end-txn a)
                    '(failed "disk I/O error" #f) #f))
           (else (failure))))
        ((rollback)
         (case choice
           ((ok) (rolled-back '(ok #t #f)))
           ((fail) (if txn
                       (values f lock (actor-rollback-failed a)
                               (list 'failed (why a f cmd) #t) #f)
                       (keep (list 'failed (why a f cmd) #f))))
           (else (failure))))
        (else (assertion-violation 'model-perform "not a shell call" cmd)))))

  ;; settle : Config World Index File Lock (U Actor #f) Boolean -> World
  ;; The world after actor I's call, with the ghosts brought up to date.
  (define (settle c w i f2 lock2 a2 touched)
    (let* ((f (world-file w))
           (wrote (or touched (and (not (eq? f f2)) (not (equal? f f2))))))
      (world-replace w f2 lock2 i a2
                     (or (world-g5 w) (and wrote (refused-file? c f)))
                     (world-g7 w)
                     (or (world-g12 w) (and wrote (= i 2)))
                     (if (model-file-exists? f2)
                         (max (world-maxver w) (model-file-version f2))
                         (world-maxver w)))))

  ;; model-perform : Config World (U 0 1 2) Command Choice
  ;;                 -> (values World RawOutcome)
  ;; Carries out actor I's command the way CHOICE says. The actor's state
  ;; and command are left as they were: the caller steps the machine. Raises
  ;; unless CHOICE is one of (model-choices c w i cmd).
  (define (model-perform c w i cmd choice)
    (unless (memq choice (model-choices c w i cmd))
      (assertion-violation 'model-perform "not a choice here" cmd choice))
    (let-values (((f2 lock2 a2 raw touched) (perform* c w i cmd choice)))
      (values (settle c w i f2 lock2 a2 touched) raw)))

  ;; model-die : Config World (U 0 1) -> World
  ;; Run I's process dies: its connection, transaction and lock are gone,
  ;; and nothing it had not committed is in the file. The run is gone.
  (define (model-die c w i)
    (let* ((a (world-actor w i)) (f (world-file w))
           (f2 (if (and (actor-txn? a) (eq? (config-model-mutant c) 'death-commits))
                   (commit-file c f a)
                   f)))
      (world-replace w f2 (release (world-lock w) i) i #f
                     (world-g5 w)
                     (or (world-g7 w) (not (equal? f f2)))
                     (world-g12 w)
                     (if (model-file-exists? f2)
                         (max (world-maxver w) (model-file-version f2))
                         (world-maxver w)))))

  ;;; Steps: the labels on the explorer's edges

  ;; Step is (List Who Choice Command RawOutcome Row State File)
  ;;   who      0 or 1, a run; 2, serve's check
  ;;   choice   how the call went, or 'die
  ;;   command  the command carried out (at a death: the one asked for)
  ;;   raw      the outcome fed to the step function; #f at a death
  ;;   row      (state-kind . event-kind) the step fired; #f at a death
  ;;   state    the actor's machine state after (at a death: before)
  ;;   file     the file after: model-file-facts and model-file-log read it
  ;; step-who : Step -> (U 0 1 2)
  ;; step-choice : Step -> Symbol
  ;; step-command : Step -> Command
  ;; step-raw : Step -> (U RawOutcome #f)
  ;; step-row : Step -> (U (Pairof Symbol Symbol) #f)
  ;; step-state : Step -> State
  ;; step-file : Step -> File
  (define (make-step who choice cmd raw row state file)
    (list who choice cmd raw row state file))
  (define (step-who s) (list-ref s 0))
  (define (step-choice s) (list-ref s 1))
  (define (step-command s) (list-ref s 2))
  (define (step-raw s) (list-ref s 3))
  (define (step-row s) (list-ref s 4))
  (define (step-state s) (list-ref s 5))
  (define (step-file s) (list-ref s 6))

  ;; move : Config Machine (U #f Observer) World Index Choice
  ;;        -> (Pairof Step World)
  ;; Actor I's call carried out the way CHOICE says and its machine
  ;; stepped, or, for 'die, run I's death.
  (define (move c m observe w i choice)
    (let* ((a (world-actor w i)) (cmd (actor-command a)) (state (actor-state a)))
      (if (eq? choice 'die)
          (let ((w2 (model-die c w i)))
            (cons (make-step i 'die cmd #f #f state (world-file w2)) w2))
          (let* ((run? (< i 2)) (ms (config-migrations c))
                 (step (if run? (machine-run-step m) (machine-check-step m)))
                 (kind-of (if run? (machine-run-kind m) (machine-check-kind m))))
            (let-values (((f2 lock2 a2 raw touched) (perform* c w i cmd choice)))
              (let ((row (cons (car state) (kind-of ms state raw))))
                (when observe (observe run? row))
                (let-values (((s2 cmd2) (step ms state raw)))
                  (let ((w2 (settle c w i f2 lock2 (actor-with-state a2 s2 cmd2) touched)))
                    (cons (make-step i choice cmd raw row s2 (world-file w2)) w2)))))))))

  ;; nominal-choices : (Listof Choice) -> (Listof Choice)
  ;; The ways a call goes in the nominal graph: its nominal ones; with none,
  ;; none if it can be told busy (it waits for the other actor); else its
  ;; first, a failure the call cannot escape, which is no injected failure
  ;; but the machine's own doing.
  (define (nominal-choices choices)
    (let ((ns (filter nominal? choices)))
      (cond ((pair? ns) ns)
            ((memq 'busy choices) '())
            (else (list (car choices))))))

  ;; actor-successors : Config Machine Observer Boolean World Index
  ;;                    -> (Listof (Pairof Step World))
  ;; Actor I's next steps: its call, every way it can go (nominal-choices
  ;; when NOMINAL), and for a run, unless NOMINAL, its death.
  (define (actor-successors c m observe nominal w i)
    (let ((a (world-actor w i)))
      (if (or (not a) (finished? a))
          '()
          (let ((choices (model-choices c w i (actor-command a))))
            (map (lambda (choice) (move c m observe w i choice))
                 (append (if nominal (nominal-choices choices) choices)
                         (if (and (< i 2) (not nominal)) '(die) '())))))))

  ;; model-apply : Config Machine World (U 0 1 2) Choice -> (Pairof Step World)
  ;; One step, as model-next takes it: actor I's call carried out the way
  ;; CHOICE says (one of model-choices, or 'die for a run) and its machine
  ;; stepped, after any actor that had ended has been swept out. Replaying
  ;; a trace is applying each step's who and choice in turn; each answer's
  ;; Step is then equal? to the trace's. Raises on a choice that is not one.
  (define (model-apply c m w i choice)
    (let* ((w (sweep w)) (a (world-actor w i)))
      (unless (and a (not (finished? a))
                   (if (eq? choice 'die)
                       (< i 2)
                       (memq choice (model-choices c w i (actor-command a)))))
        (assertion-violation 'model-apply "not a step here" i choice))
      (move c m #f w i choice)))

  ;; alone? : Config World Index -> Boolean
  ;; Actor I has asked for a call that commutes with every other actor's
  ;; steps, and that no property sees but in I itself: a read-only open of
  ;; a file that exists, a pause, or a close while it holds neither the lock
  ;; nor a transaction, read-only, or, for a run, read-write on a file that
  ;; is not ahead or foreign (M5 would see that close's checkpoint; a file
  ;; becomes ahead or foreign only by breaking M1 or M6 in the same step).
  ;; Its death, holding nothing, commutes too.
  (define (alone? c w i)
    (let ((a (world-actor w i)))
      (and a
           (not (finished? a))
           (not (actor-txn? a))
           (not (eqv? (world-lock w) i))
           (let ((k (car (actor-command a))) (conn (actor-conn a)))
             (case k
               ((open-read-only)
                (and (eq? conn 'none) (model-file-exists? (world-file w))))
               ((pause) #t)
               ((close)
                (or (eq? conn 'ro)
                    (and (< i 2) (eq? conn 'rw)
                         (not (refused-file? c (world-file w))))))
               (else #f))))))

  ;; model-next : Config Machine (U #f Observer) Boolean
  ;;              -> (World -> (Listof (Pairof Step World)))
  ;; Observer is (Boolean (Pairof Symbol Symbol) -> Any).
  ;; The explorer's next worlds: each live actor's call, every way it can
  ;; go, and each run's death; with NOMINAL, only the nominal ways and no
  ;; death. OBSERVE, when given, is told of each row a step fires: #t and
  ;; the row for a run, #f and the row for serve's check.
  ;; When an actor's call is alone? (the lowest such index), its steps are
  ;; the only next steps.
  (define (model-next c m observe nominal)
    (define expanded 0)
    (lambda (w)
      (when (config-cap c)
        (set! expanded (+ expanded 1))
        (when (> expanded (config-cap c))
          (assertion-violation 'model-next "more worlds than the cap" (config-cap c))))
      (let ((w (sweep w)))
        (cond ((alone? c w 0) (actor-successors c m observe nominal w 0))
              ((alone? c w 1) (actor-successors c m observe nominal w 1))
              ((alone? c w 2) (actor-successors c m observe nominal w 2))
              (else
               (append (actor-successors c m observe nominal w 0)
                       (actor-successors c m observe nominal w 1)
                       (actor-successors c m observe nominal w 2)))))))

  ;; sweep : World -> World
  ;; W with each ended actor gone, and its lock freed if it still held it:
  ;; its process has exited. W itself when there is none.
  (define (sweep w)
    (let loop ((i 0) (w w))
      (if (= i 3)
          w
          (let ((a (world-actor w i)))
            (loop (+ i 1)
                  (if (and a (finished? a))
                      (world-replace w (world-file w) (release (world-lock w) i) i #f
                                     (world-g5 w) (world-g7 w) (world-g12 w)
                                     (world-maxver w))
                      w))))))

  ;;; The properties

  (define (show x)
    (call-with-string-output-port (lambda (p) (write x p))))
  (define (show-log log) (show (map symbol->string log)))
  (define (join strs sep)
    (if (null? strs)
        ""
        (fold-left (lambda (acc s) (string-append acc sep s)) (car strs) (cdr strs))))

  (define hold-states
    '(relooking applying checking stamping committing undoing-to-look
      undoing-to-fail))
  (define six-results '(applied nothing refused failed busy cannot-open))

  ;; result? : Any -> Boolean
  (define (result? r)
    (and (list? r) (= (length r) 4) (memq (car r) six-results)
         (list? (cadr r)) (boolean? (caddr r)) #t))

  ;; pending-kind : State -> (U Symbol #f)
  ;; The result kind a run in closing or ended has settled on.
  (define (pending-kind s)
    (let ((d (cdr s)))
      (case (car s)
        ((closing) (and (list? d) (= (length d) 6) (pair? (list-ref d 5))
                        (car (list-ref d 5))))
        ((ended) (and (pair? d) (car d)))
        (else #f))))

  ;; file-problems : Config File -> (Listof (Pairof Natural String))
  ;; M1, M2, M3, M5's file half and M6: what the file alone shows.
  (define (file-problems c f)
    (let* ((ms (config-migrations c)) (start (config-start-class c))
           (ours (memq start '(missing fresh behind current)))
           (log (model-file-log f)) (v (model-file-version f))
           (tokens (config-tokens c))
           (k-of (lambda (t) (let ((e (assq t tokens))) (and e (cdr e)))))
           (out '()))
      (define (bad! n msg) (set! out (cons (cons n msg) out)))
      (when (and ours (model-file-exists? f))
        ;; M1
        (let ((stray (filter (lambda (t) (not (k-of t))) log)))
          (cond
           ((or (< v 0) (> v (config-latest c)))
            (bad! 1 (string-append "M1: version " (show v) " but no such migration")))
           ((pair? stray)
            (bad! 1 (string-append "M1: effects of no migration: " (show-log stray))))
           (else
            (for-each
             (lambda (m)
               (let* ((k (car m)) (toks (map string->symbol (caddr m)))
                      (here (filter (lambda (t) (memq t log)) toks)))
                 (cond ((and (<= k v) (< (length here) (length toks)))
                        (bad! 1 (string-append "M1: at version " (show v) " migration "
                                               (show k) " is not whole: " (show-log log))))
                       ((and (> k v) (pair? here))
                        (bad! 1 (string-append "M1: at version " (show v) " migration "
                                               (show k) " has taken effect: " (show-log log)))))))
             ms))))
        ;; M3: migration numbers in the log start at 1 and step by 0 or 1
        (let loop ((ks (map k-of log)) (last 0))
          (cond ((null? ks) #f)
                ((not (car ks)) (loop (cdr ks) last))
                ((or (< (car ks) last) (> (car ks) (+ last 1)))
                 (bad! 3 (string-append "M3: out of order or with a gap: " (show-log log))))
                (else (loop (cdr ks) (car ks)))))
        ;; M6
        (unless (eq? (= (model-file-id f) T) (>= v 1))
          (bad! 6 (string-append "M6: id " (show (model-file-id f)) " at version "
                                 (show v)))))
      ;; M2
      (let loop ((l log))
        (cond ((null? l) #f)
              ((memq (car l) (cdr l))
               (bad! 2 (string-append "M2: an effect took effect twice: "
                                      (symbol->string (car l)))))
              (else (loop (cdr l)))))
      ;; M5: a refused file never changes
      (when (and (refused-class? start) (not (equal? f (config-start-file c))))
        (bad! 5 (string-append "M5: the " (symbol->string start) " file changed: "
                               (show (model-file-facts f)) " " (show-log log))))
      out))

  ;; world-problems : Config World -> (Listof (Pairof Natural String))
  ;; M4, M5's ghost, M7 to M12, and ML1's Result.
  (define (world-problems c w)
    (let* ((f (world-file w)) (out '()))
      (define (bad! n msg) (set! out (cons (cons n msg) out)))
      (when (and (model-file-exists? f) (< (model-file-version f) (world-maxver w)))
        (bad! 4 (string-append "M4: version " (show (model-file-version f))
                               " after " (show (world-maxver w)))))
      (when (world-g5 w)
        (bad! 5 "M5: an ahead or foreign file was opened read-write or written"))
      (when (world-g7 w)
        (bad! 7 "M7: a run's death changed the file"))
      (when (world-g12 w)
        (bad! 12 "M12: serve's check opened read-write, created or wrote the file"))
      (let ((s (world-actor w 2)))
        (when (and s (memq (car (actor-state s)) '(closing ended))
                   (eq? (cdr (actor-state s)) 'serve)
                   (not (current-wal? c f)))
          (bad! 9 (string-append "M9: serve starts on " (show (model-file-facts f))))))
      (for-each
       (lambda (i)
         (let ((a (world-actor w i)))
           (when a
             (let* ((s (actor-state a)) (k (car s)) (txn (actor-txn? a))
                    (held (eqv? (world-lock w) i)) (who (show i)))
               ;; M8
               (when (and (memq (pending-kind s) '(applied nothing))
                          (not (current-wal? c f)))
                 (bad! 8 (string-append "M8: run " who " says " (show (pending-kind s))
                                        " in " (show k) " on "
                                        (show (model-file-facts f)))))
               ;; M10
               (cond ((not (eq? txn held))
                      (bad! 10 (string-append
                                "M10: run " who " in " (show k)
                                (if txn
                                    " has a transaction without the lock"
                                    " holds the lock without a transaction"))))
                     ((memq k hold-states)
                      (unless txn
                        (bad! 10 (string-append "M10: run " who " in " (show k)
                                                " without the lock and a transaction"))))
                     ((eq? k 'closing)
                      (when (and txn (not (a-rbfail a)))
                        (bad! 10 (string-append "M10: run " who
                                                " in closing holds the lock,"
                                                " and no rollback failed"))))
                     (txn
                      (bad! 10 (string-append "M10: run " who " in " (show k)
                                              " holds the lock and a transaction"))))
               ;; ML1, held here: an ended run leaves the world at the next
               ;; step, so its Result is read in the world where it ended
               (when (and (or (eq? k 'ended) (finished? a))
                          (not (and (eq? k 'ended) (finished? a) (result? (cdr s)))))
                 (bad! 101 (string-append "ML1: run " who " ended in " (show k) " with "
                                          (show (cdr (actor-command a))))))
               ;; M11
               (when (and (eq? k 'ended) (result? (cdr s)))
                 (let ((r (cdr s)) (commits (actor-commits a)))
                   (cond ((not (equal? (cadr r) commits))
                          (bad! 11 (string-append "M11: run " who " lists " (show (cadr r))
                                                  " but COMMIT answered ok for "
                                                  (show commits))))
                         ((and (eq? (car r) 'applied) (null? commits))
                          (bad! 11 (string-append
                                    "M11: run " who
                                    " says applied, and no COMMIT answered ok")))
                         ((and (eq? (car r) 'nothing) (pair? commits))
                          (bad! 11 (string-append "M11: run " who " says nothing, after "
                                                  (show commits)))))))))))
       '(0 1))
      out))

  ;; by-number : Config (Listof (Pairof Natural String)) -> (U #f String)
  ;; The problems not unchecked, in order of their number.
  (define (by-number c problems)
    (let ((ps (filter (lambda (p) (not (memv (car p) (config-unchecked c)))) problems)))
      (if (null? ps)
          #f
          (join (map cdr (list-sort (lambda (a b) (< (car a) (car b))) ps)) " | "))))

  ;; model-invariant : Config -> (World -> (U #f String))
  ;; M1 to M12 in one world, and ML1's Result: #f, or every broken one, in
  ;; order, each named ("M2: ..."), joined by " | ". M1, M3 and M6 are held
  ;; only of a file that began missing, fresh or as Techo's within this
  ;; list; M5's "never changes" only of one that began ahead or foreign, and
  ;; its ghost of any file that was ahead or foreign when it was opened
  ;; read-write or written. M8 asks current and in WAL.
  (define (model-invariant c)
    (let ((cache (make-eq-hashtable)))
      (lambda (w)
        (let* ((f (world-file w))
               (fp (or (hashtable-ref cache f #f)
                       (let ((p (file-problems c f))) (hashtable-set! cache f p) p))))
          (by-number c (append fp (world-problems c w)))))))

  ;; model-lone-run : Config Machine File -> (values (U Result #f) File)
  ;; A new run alone on F, every call going its nominal way (its first way
  ;; when it has no nominal one): its Result and the file after, or #f if it
  ;; has not ended within 1000 calls.
  (define (model-lone-run c m f)
    (let-values (((s cmd) ((machine-run-start m))))
      (let loop ((w (make-world f #f (new-actor s cmd) #f #f #f #f #f 0)) (n 0))
        (let ((a (world-actor w 0)))
          (cond
           ((finished? a) (values (cdr (actor-command a)) (world-file w)))
           ((>= n 1000) (values #f (world-file w)))
           (else
            (let* ((cmd (actor-command a)) (choices (model-choices c w 0 cmd))
                   (choice (cond ((memq 'ok choices) 'ok)
                                 ((memq 'missing choices) 'missing)
                                 (else (car choices)))))
              (let-values (((f2 lock2 a2 raw touched) (perform* c w 0 cmd choice)))
                (let-values (((s2 cmd2) ((machine-run-step m) (config-migrations c)
                                         (actor-state a) raw)))
                  (loop (make-world f2 lock2 (actor-with-state a2 s2 cmd2) #f #f
                                    #f #f #f 0)
                        (+ n 1)))))))))))

  ;; lone-run-problem : Config Machine File -> (U String 'ok)
  (define (lone-run-problem c m f)
    (cond
     ((refused-file? c f)
      (if (refused-class? (config-start-class c))
          'ok
          (string-append "ML3: the file became ahead or foreign: "
                         (show (model-file-facts f)))))
     (else
      (let-values (((r f2) (model-lone-run c m f)))
        (if (and (result? r) (memq (car r) '(applied nothing)) (current-wal? c f2))
            'ok
            (string-append "ML3: from " (show (model-file-facts f))
                           ", a new run ends " (show r) " leaving "
                           (show (model-file-facts f2))))))))

  ;; model-final : Config Machine Boolean -> (World -> (U #f String))
  ;; At a world with nothing left to run, named as the invariant names its
  ;; own:
  ;;   ML1  no run is left neither ended nor dead
  ;;   ML2  with NOMINAL (the nominal graph: no injected failure, no death,
  ;;        no busy),
  ;;        the file is current and in WAL, unless it began ahead or foreign
  ;;   ML3  the file is ahead or foreign only if it began so; otherwise a
  ;;        lone run (model-lone-run) ends applied or nothing, leaving it
  ;;        current and in WAL
  (define (model-final c m nominal)
    (let ((memo (make-hashtable file-hash equal?)))
      (lambda (w)
        (let* ((f (world-file w)) (out '()))
          (define (bad! n msg) (set! out (cons (cons n msg) out)))
          (for-each
           (lambda (i)
             (let ((a (world-actor w i)))
               (when (and a (not (finished? a)))
                 (bad! 101 (string-append "ML1: actor " (show i) " is stuck in "
                                          (show (car (actor-state a))) " asking "
                                          (show (actor-command a)))))))
           '(0 1 2))
          (when (and nominal
                     (not (refused-class? (config-start-class c)))
                     (not (current-wal? c f)))
            (bad! 102 (string-append "ML2: no failure, and the file ends "
                                     (show (model-file-facts f)))))
          (let ((ml3 (or (hashtable-ref memo f #f)
                         (let ((v (lone-run-problem c m f)))
                           (hashtable-set! memo f v)
                           v))))
            (when (string? ml3) (bad! 103 ml3)))
          (by-number c out)))))

  ;; world-hash : World -> Integer
  (define (world-hash w) (vector-ref w 0))

  ;; model-explore : Config Machine (U #f Observer)
  ;;                 -> (U (List 'ok Natural) (List 'violated String Trace)
  ;;                       (List 'cycle Trace))
  ;; (explore)'s answer for this configuration, explored twice: first the
  ;; nominal graph, for ML2, then, if that answers ok, the whole graph. The
  ;; whole graph's answer, or the nominal one's when it is not ok.
  (define (model-explore c m observe)
    (forget!)
    (let ((r (explore (model-start c m) (model-next c m observe #t)
                      (model-invariant c) (model-final c m #t) world-hash)))
      (if (eq? (car r) 'ok)
          (explore (model-start c m) (model-next c m observe #f)
                   (model-invariant c) (model-final c m #f) world-hash)
          r)))

  ;;; Traces for the replay

  ;; Trace is (Listof Step), from the start world.

  ;; next-seed : Natural -> Natural
  (define (next-seed s) (mod (+ (* s 1103515245) 12345) 2147483648))

  ;; model-walk : Config Machine Natural Natural -> Trace
  ;; A seeded random walk of at most N steps from the start, each step one
  ;; of the world's next steps (model-next, not nominal), all equally
  ;; likely, stopping early at a world with none. The same seed gives the
  ;; same trace.
  (define (model-walk c m seed n)
    (let ((next (model-next c m #f #f)))
      (let loop ((w (model-start c m)) (s (next-seed seed)) (k 0) (acc '()))
        (let ((moves (if (= k n) '() (next w))))
          (if (null? moves)
              (reverse acc)
              (let ((move (list-ref moves (mod (div s 65536) (length moves)))))
                (loop (cdr move) (next-seed s) (+ k 1) (cons (car move) acc))))))))

  ;; model-traces : Config Machine
  ;;                -> (Listof (Pairof (Pairof Boolean (Pairof Symbol Symbol)) Trace))
  ;; For each row the configuration fires, keyed (run? state-kind .
  ;; event-kind), a shortest trace to a step that fires it, carried on to a
  ;; world with nothing left to run by always taking the first next step (an
  ;; actor's nominal call, before its failures and its death). Breadth-first
  ;; over the whole graph, so for small configurations.
  (define (model-traces c m)
    (forget!)
    (let ((next (model-next c m #f #f))
          (seen (make-hashtable (lambda (w) (vector-ref w 0)) equal?))
          (firsts '()))
      (define (path w)
        (let loop ((w w) (acc '()))
          (let ((link (hashtable-ref seen w #f)))
            (if link (loop (car link) (cons (cdr link) acc)) acc))))
      (define (tail w)
        (let loop ((w w) (acc '()))
          (let ((moves (next w)))
            (if (null? moves)
                (reverse acc)
                (loop (cdar moves) (cons (caar moves) acc))))))
      (let ((start (model-start c m)))
        (hashtable-set! seen start #f)
        (let loop ((front (list start)) (back '()))
          (cond
           ((and (null? front) (null? back)) #f)
           ((null? front) (loop (reverse back) '()))
           (else
            (let add ((moves (next (car front))) (back back))
              (if (null? moves)
                  (loop (cdr front) back)
                  (let* ((step (caar moves)) (w2 (cdar moves))
                         (row (step-row step))
                         (key (and row (cons (< (step-who step) 2) row))))
                    (when (and key (not (assoc key firsts)))
                      (set! firsts (cons (list key (car front) step w2) firsts)))
                    (if (hashtable-contains? seen w2)
                        (add (cdr moves) back)
                        (begin (hashtable-set! seen w2 (cons (car front) step))
                               (add (cdr moves) (cons w2 back))))))))))
        ;; an entry is (key from step to)
        (map (lambda (entry)
               (cons (car entry)
                     (append (path (cadr entry)) (list (caddr entry))
                             (tail (cadddr entry)))))
             (reverse firsts)))))
)
