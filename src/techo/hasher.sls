#!r6rs
;;; (techo hasher): passwords are hashed and verified off the loop's thread,
;;; on a circuit worker of their own: ONE thread, so at most one hash runs
;;; at a time (Q9), and a queue of 8 (the owner's D11). Slice 3b's L5.
;;;
;;; The shell around that worker. It is given its four procedures, so a test
;;; passes fast fakes and this library imports nothing of chez-sodium's:
;;;   hash          password -> hash string
;;;   verify        stored hash, then password -> Boolean
;;;   failed?       the predicate for "memory is short" (sodium-failed?)
;;;   random-bytes  for the stand-in
;;;
;;; THE STAND-IN is the hash of 32 random bytes as 64 lowercase hex
;;; characters, made once when the hasher opens. An unknown email is
;;; verified against it, so it costs what a known one costs.
;;;
;;; Each call runs ONE job and answers a symbol the login table reads. It is
;;; made on the loop's thread, inside a request: worker-call waits with
;;; await-outside. A full queue is 'busy; a raise `failed?` accepts is
;;; 'failed, for a hash. Anything else (a deadline, a closed client, a
;;; stopped worker, an assertion violation) goes on as it was raised, by
;;; the doorway's catch: call/cc around with-exception-handler, raised on by
;;; raise-continuable from where it was raised, before anything unwinds, so
;;; a deadline still reaches the server's own handler.
;;;
;;; A job closes over the password and nothing else of the request. Nothing
;;; here logs, prints or keeps a password, nor a hash but the stand-in.
(library (techo hasher)
  (export make-hasher hasher? hasher-open! hasher-stop!
          hasher-verify hasher-doubt hasher-hash)
  (import (rnrs)
          (only (circuit worker) make-worker worker-call worker-stop! worker-full?))

  ;; The worker's shape (D11).
  (define threads 1)
  (define queue-cap 8)

  ;; What a doubt hashes: no one's password.
  (define throwaway "techo: a throwaway password, to tell short memory from a wrong password")

  ;; Hasher : the four procedures; the worker, #f until it opens; the
  ;; stand-in, #f until it is made.
  (define-record-type (hasher %make-hasher hasher?)
    (fields (immutable hash hash-of)
            (immutable verify verify-of)
            (immutable failed? failed-of)
            (immutable random-bytes random-of)
            (mutable worker)
            (mutable stand-in)))

  ;; hasher? : Any -> Boolean

  ;; make-hasher : (String -> String) (String String -> Boolean) (Any -> Boolean)
  ;;               (Natural -> Bytevector) -> Hasher
  ;; HASH, VERIFY (the stored hash first), FAILED? and RANDOM-BYTES. Starts
  ;; nothing.
  (define (make-hasher hash verify failed? random-bytes)
    (for-each (lambda (p name)
                (unless (procedure? p)
                  (assertion-violation 'make-hasher
                    (string-append name " must be a procedure") p)))
              (list hash verify failed? random-bytes)
              '("hash" "verify" "failed?" "random-bytes"))
    (%make-hasher hash verify failed? random-bytes #f #f))

  ;; hasher-open! : Hasher -> Void
  ;; Starts the worker, then makes the stand-in on this thread. If that
  ;; raises, the worker is stopped again and the raise goes on: a server
  ;; that cannot hash once does not start. Opening twice is an assertion
  ;; violation.
  (define (hasher-open! h)
    (when (hasher-worker h)
      (assertion-violation 'hasher-open! "the hasher is open already"))
    (let ((w (make-worker (lambda () 'hasher) queue-cap threads)))
      (hasher-worker-set! h w)
      (guard (e (#t (guard (e2 (#t #f)) (worker-stop! w))
                    (raise e)))
        (let ((bv ((random-of h) 32)))
          (unless (and (bytevector? bv) (= (bytevector-length bv) 32))
            (assertion-violation 'hasher-open! "random-bytes must answer 32 bytes"))
          (hasher-stand-in-set! h ((hash-of h) (hex bv)))))))

  ;; hex : Bytevector -> String    two lowercase digits a byte
  (define (hex bv)
    (let ((digits "0123456789abcdef"))
      (list->string
       (apply append
              (map (lambda (b) (list (string-ref digits (div b 16))
                                     (string-ref digits (mod b 16))))
                   (bytevector->u8-list bv))))))

  ;; hasher-stop! : Hasher -> Void
  ;; Stops the worker. Fine twice, and fine when it never opened. The
  ;; stopped worker is kept, so a later call raises circuit's &worker-stopped.
  (define (hasher-stop! h)
    (let ((w (hasher-worker h)))
      (when w (worker-stop! w))))

  ;; hasher-verify : Hasher (U String #f) String -> (U 'matched 'unmatched 'busy)
  ;; One job: VERIFY of STORED and PASSWORD. 'matched only when it answers
  ;; #t. With #f for STORED it verifies against the stand-in, and answers
  ;; 'unmatched whatever verify says.
  (define (hasher-verify h stored password)
    (check-text 'hasher-verify password)
    (unless (or (not stored) (string? stored))
      (assertion-violation 'hasher-verify "the stored hash must be a string or #f"))
    (let ((verify (verify-of h)) (w (worker-of 'hasher-verify h)))
      (if stored
          (answer h #f (lambda ()
                         (if (eq? (worker-call w (lambda (state) (verify stored password))) #t)
                             'matched
                             'unmatched)))
          (let ((stand-in (hasher-stand-in h)))
            (answer h #f (lambda ()
                           (worker-call w (lambda (state) (verify stand-in password)))
                           'unmatched))))))

  ;; hasher-doubt : Hasher -> (U 'hashed 'failed 'busy)
  ;; One job: the hash of a throwaway string, to tell short memory from a
  ;; wrong password after a verify said no.
  (define (hasher-doubt h)
    (let ((hash (hash-of h)) (w (worker-of 'hasher-doubt h)))
      (answer h #t (lambda ()
                     (worker-call w (lambda (state) (hash throwaway)))
                     'hashed))))

  ;; hasher-hash : Hasher String -> (U String 'failed 'busy)
  ;; One job: PASSWORD's hash.
  (define (hasher-hash h password)
    (check-text 'hasher-hash password)
    (let ((hash (hash-of h)) (w (worker-of 'hasher-hash h)))
      (answer h #t (lambda ()
                     (worker-call w (lambda (state) (hash password)))))))

  ;; worker-of : Symbol Hasher -> Worker
  (define (worker-of who h)
    (or (hasher-worker h)
        (assertion-violation who "the hasher is not open")))

  ;; check-text : Symbol Any -> Void
  ;; A password must be a string. The refusal never names it.
  (define (check-text who password)
    (unless (string? password)
      (assertion-violation who "the password must be a string")))

  ;; answer : Hasher Boolean (-> A) -> (U A 'busy 'failed)
  ;; THUNK's value; 'busy when the queue is full; 'failed for what FAILED?
  ;; accepts, when LOOK? says a failure is an answer here. Anything else is
  ;; raised on, continuably, from where it was raised.
  (define (answer h look? thunk)
    (let ((failed? (failed-of h)))
      (call/cc
       (lambda (k)
         (with-exception-handler
          (lambda (e)
            (cond ((worker-full? e) (k 'busy))
                  ((and look? (failed? e)) (k 'failed))
                  (else (raise-continuable e))))
          thunk)))))
)
