#!r6rs
;;; (techo passwords): how a password is prepared, and chez-sodium's password
;;; verbs at the one set of limits Techo uses.
;;;
;;;   prepare-password        a password to SET: NFC, then (techo accounts)'s rules
;;;   prepare-login-password  a password to CHECK: NFC, and only the upper bound
;;;   sodium-hash, sodium-verify, sodium-needs-rehash?
;;;   memory-short?           did the hash fail for want of memory
;;;
;;; The prepare procedures are pure. The three sodium verbs cost about 50 ms
;;; and 64 MiB each. The answers never hold the password.
(library (techo passwords)
  (export prepare-password prepare-login-password
          sodium-hash sodium-verify sodium-needs-rehash? memory-short?)
  (import (rnrs)
          (only (chez-sodium) password-hash password-verify
                password-needs-rehash? sodium-failed?)
          (only (techo accounts) password-problem))

  ;; prepare-password : Any -> (U String Symbol)
  ;; Not a string: 'not-a-string. Otherwise the NFC form if it is 8 characters
  ;; or more and 1,024 bytes or fewer; else 'too-short or 'too-long.
  (define (prepare-password x)
    (if (string? x)
        (let* ((n (string-normalize-nfc x))
               (problem (password-problem n)))
          (or problem n))
        'not-a-string))

  ;; prepare-login-password : Any -> (U String Symbol)
  ;; Not a string: 'not-a-string. Over 1,024 bytes of NFC: 'too-long. Else
  ;; the NFC form. No minimum: a short password is simply wrong.
  (define (prepare-login-password x)
    (if (string? x)
        (let ((n (string-normalize-nfc x)))
          (if (> (bytevector-length (string->utf8 n)) 1024)
              'too-long
              n))
        'not-a-string))

  ;; The limits, named once so hash and needs-rehash can never disagree.
  (define limits 'interactive)

  ;; sodium-hash : String -> String
  (define (sodium-hash password) (password-hash password limits))

  ;; sodium-verify : String String -> Boolean
  ;; The hash first, then the password.
  (define (sodium-verify hash password) (password-verify hash password))

  ;; sodium-needs-rehash? : String -> Boolean
  ;; hash.
  (define (sodium-needs-rehash? hash) (password-needs-rehash? hash limits))

  ;; memory-short? : Any -> Boolean
  (define (memory-short? x) (sodium-failed? x))
)
