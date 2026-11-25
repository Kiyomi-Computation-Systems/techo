#!r6rs
;;; (techo wiring): how the program builds its parts from the real ones. The
;;; imperative shell's construction, out of techo.sps so a test can reach
;;; it (tests/test-wiring.sps). It reads no settings and starts nothing:
;;; techo.sps reads the settings, makes the doorway and its two runners,
;;; and opens and stops the hasher.
;;;
;;;   duration-clock     the one clock for durations: the limiter, db_ms
;;;   id-source          fresh ids, UUID version 7
;;;   sodium-hasher      the hasher over chez-sodium's verbs
;;;   program-login-kit  POST /v1/login's kit over that hasher
;;;   program-app        the app, with the duration clock and the kit
;;;   program-user-kit   what the `user` commands need
(library (techo wiring)
  (export duration-clock id-source sodium-hasher program-login-kit program-app
          program-user-kit)
  (import (rnrs)
          (only (chezscheme) real-time)
          (only (techo app) make-app)
          (only (techo hasher) make-hasher hasher-verify hasher-doubt hasher-hash)
          (only (techo limiter) make-limiter)
          (only (techo passwords) sodium-hash sodium-verify sodium-needs-rehash?
                memory-short?)
          (only (techo routes) make-login-kit)
          (only (techo users) make-user-kit)
          (only (unique-id) uuid->bytevector)
          (only (unique-id generator) make-uuid-generator generate-v7))

  ;; Runner = ((Tx -> Any) -> Any)

  ;; duration-clock : -> Integer
  ;; Chez's real-time: milliseconds that never go backwards, not the time
  ;; of day. The limiter's windows and a request's db_ms use it (L3).
  (define (duration-clock) (real-time))

  ;; id-source : (-> Natural) (Natural -> Bytevector) -> (-> Bytevector)
  ;; From the wall clock (whole ms since 1970) and random-bytes, a source
  ;; of fresh ids: UUIDs, version 7, as 16 bytes (slice 3's D2). One
  ;; generator, for one thread.
  (define (id-source wall-clock random-bytes)
    (let ((generator (make-uuid-generator wall-clock random-bytes)))
      (lambda () (uuid->bytevector (generate-v7 generator)))))

  ;; sodium-hasher : (Natural -> Bytevector) [(String -> String)] -> Hasher
  ;; The hasher over chez-sodium's verbs at Techo's limits, memory-short?
  ;; telling short memory, and RANDOM-BYTES for the stand-in. HASH is
  ;; sodium-hash; a test may give another, which counts or raises and then
  ;; calls sodium-hash. Started by hasher-open!, which techo.sps runs.
  (define sodium-hasher
    (case-lambda
      ((random-bytes) (sodium-hasher random-bytes sodium-hash))
      ((random-bytes hash) (make-hasher hash sodium-verify memory-short? random-bytes))))

  ;; program-login-kit : Hasher Natural (-> Bytevector) (String -> Void) -> LoginKit
  ;; The kit over HASHER's three calls, sodium-needs-rehash?, a fresh
  ;; limiter at its defaults (5 tries an email, 20 an address, in 15
  ;; minutes), the count of PROXIES in front, IDS for a key's id, and LOG
  ;; for the limiter's "full" line.
  (define (program-login-kit hasher proxies ids log)
    (make-login-kit (lambda (stored password) (hasher-verify hasher stored password))
                    (lambda () (hasher-doubt hasher))
                    (lambda (password) (hasher-hash hasher password))
                    sodium-needs-rehash?
                    (make-limiter)
                    proxies
                    ids
                    log))

  ;; program-app : Runner Runner (-> Natural) (Natural -> Bytevector) LoginKit -> Handler
  ;; make-app's handler for READ and WRITE, the wall clock, random-bytes,
  ;; duration-clock and KIT.
  (define (program-app read write wall-clock random-bytes kit)
    (make-app read write wall-clock random-bytes duration-clock kit))

  ;; program-user-kit : String (Listof Migration) (-> Natural) (Natural -> Bytevector)
  ;;                    -> UserKit
  ;; The `user` commands' kit: the database at PATH and MIGRATIONS,
  ;; sodium-hash, the wall clock, and ids from it and RANDOM-BYTES.
  (define (program-user-kit path migrations wall-clock random-bytes)
    (make-user-kit path migrations sodium-hash wall-clock
                   (id-source wall-clock random-bytes)))
)
