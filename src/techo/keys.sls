#!r6rs
;;; (techo keys): a key's lifecycle (D5), its secret's shape and the header
;;; that carries it (D3), ids and paging (D9), and a key's name. Pure: no
;;; database, no clock, no hashing (ADR-0007).
;;;
;;; The table is over state kinds none, active and revoked ("none" is what an
;;; unknown key, or another account's key, looks like). A state here has no
;;; data, so key-step takes and answers kinds.
(library (techo keys)
  (export key-rows key-cant-happen key-step key-document
          key-secret key-secret? read-bearer
          parse-id parse-limit parse-after id->string
          key-name-problem)
  (import (rnrs)
          (techo machine)
          (only (unique-id) string->uuid uuid->bytevector bytevector->uuid uuid->string))

  ;;; D5's table

  (define (same d e) d)

  ;; key-rows : (Listof Row)
  ;; D5's eleven rows, in its order. Row is (state event next command update).
  (define key-rows
    (list
     (list 'none 'create 'active 'insert same)
     (list 'none 'check 'none 'refuse-401 same)
     (list 'none 'revoke 'none 'refuse-404 same)
     (list 'none 'regenerate-other 'none 'refuse-404 same)
     (list 'active 'check 'active 'admit same)
     (list 'active 'regenerate-self 'active 'replace-hash same)
     (list 'active 'regenerate-other 'active 'refuse-403 same)
     (list 'active 'revoke 'revoked 'set-revoked same)
     (list 'revoked 'check 'revoked 'refuse-401 same)
     (list 'revoked 'revoke 'revoked 'nothing same)
     (list 'revoked 'regenerate-other 'revoked 'refuse-403 same)))

  ;; key-cant-happen : (Listof (List StateKind EventKind String))
  (define key-cant-happen
    '((active create "a create makes a new key, so no existing key is created again")
      (revoked create "a create makes a new key, so no existing key is created again")
      (none regenerate-self "the asking key passed its check, so it is active")
      (revoked regenerate-self "the asking key passed its check, so it is active")))

  (define key-machine (make-machine key-rows))

  ;; key-step : StateKind EventKind -> (values StateKind CommandKind)
  ;; Commands: insert admit replace-hash set-revoked nothing refuse-401
  ;; refuse-403 refuse-404. An assertion violation, who 'machine-step, for a
  ;; pair with no row.
  (define (key-step state event)
    (let-values (((next command) (machine-step key-machine (cons state #f) (cons event #f))))
      (values (car next) (car command))))

  ;; key-document : -> String
  ;; The text of .plans/machines/key.md, rendered from the table.
  (define (key-document)
    (string-append
     "# The key machine\n\n"
     "Generated from the table in `src/techo/keys.sls`. Do not edit.\n"
     "Regenerate with `scripts/guix-env make machines`; "
     "a test fails when this file differs.\n\n"
     "No state is an end, on purpose.\n\n"
     "```mermaid\n"
     (machine->mermaid key-machine)
     "```\n"))

  ;;; The secret

  (define hex-digits "0123456789abcdef")

  ;; key-secret : Bytevector -> String
  ;; "techo_" and 64 lowercase hex digits for exactly 32 bytes. An assertion
  ;; violation for anything else.
  (define (key-secret bytes)
    (unless (and (bytevector? bytes) (= (bytevector-length bytes) 32))
      (assertion-violation 'key-secret "a key is exactly 32 bytes"))
    (list->string
     (append (string->list "techo_")
             (apply append
                    (map (lambda (b)
                           (list (string-ref hex-digits (div b 16))
                                 (string-ref hex-digits (mod b 16))))
                         (bytevector->u8-list bytes))))))

  ;; lower-hex? : Char -> Boolean
  (define (lower-hex? c)
    (or (and (char>=? c #\0) (char<=? c #\9))
        (and (char>=? c #\a) (char<=? c #\f))))

  ;; key-secret? : Any -> Boolean
  ;; #t only for a string of "techo_" and 64 lowercase hex digits.
  (define (key-secret? x)
    (and (string? x)
         (= (string-length x) 70)
         (string=? (substring x 0 6) "techo_")
         (let loop ((i 6))
           (or (= i 70)
               (and (lower-hex? (string-ref x i)) (loop (+ i 1)))))))

  ;; ascii-lower : Char -> Char
  (define (ascii-lower c)
    (if (and (char>=? c #\A) (char<=? c #\Z))
        (integer->char (+ (char->integer c) 32))
        c))

  ;; read-bearer : (Listof String) -> (U String #f)
  ;; The secret when there is exactly one Authorization value, its scheme is
  ;; "bearer" in any letter case, exactly one space follows, and the rest is
  ;; key-secret?. #f otherwise. Never raises.
  (define (read-bearer values)
    (guard (e (#t #f))
      (and (list? values)
           (= (length values) 1)
           (let ((v (car values)))
             (and (string? v)
                  (= (string-length v) 77)
                  (string=? (list->string (map ascii-lower (string->list (substring v 0 6))))
                            "bearer")
                  (char=? (string-ref v 6) #\space)
                  (let ((secret (substring v 7 77)))
                    (and (key-secret? secret) secret)))))))

  ;;; Ids and paging

  ;; parse-id : Any -> (U Bytevector 'invalid)
  ;; A fresh 16-byte bytevector for a UUID string in either case.
  (define (parse-id x)
    (or (and (string? x)
             (guard (e (#t #f))
               (let ((u (string->uuid x)))
                 (and u (uuid->bytevector u)))))
        'invalid))

  ;; id->string : Bytevector -> String
  ;; Lowercase canonical UUID text of 16 bytes.
  (define (id->string bytes)
    (uuid->string (bytevector->uuid bytes)))

  ;; parse-limit : (U String #f) -> (U Natural 'invalid)
  ;; #f is 50. A string of decimal digits worth 1 or more is that number,
  ;; capped at 100 (however many digits). Anything else is 'invalid.
  (define (parse-limit x)
    (cond ((not x) 50)
          ((not (string? x)) 'invalid)
          ((not (and (> (string-length x) 0)
                     (for-all (lambda (c) (and (char>=? c #\0) (char<=? c #\9)))
                              (string->list x))))
           'invalid)
          (else
           (let* ((n (string-length x))
                  (first (let loop ((i 0))
                           (if (and (< i n) (char=? (string-ref x i) #\0)) (loop (+ i 1)) i)))
                  (digits (substring x first n)))
             (cond ((= (string-length digits) 0) 'invalid)
                   ((> (string-length digits) 3) 100)
                   (else (min 100 (string->number digits))))))))

  ;; parse-after : (U String #f) -> (U Bytevector #f 'invalid)
  (define (parse-after x)
    (if x (parse-id x) #f))

  ;;; A key's name

  ;; key-name-problem : Any -> (U #f Symbol)
  ;; #f for a string of 1 to 64 characters with no control character (below
  ;; U+0020, or U+007F). Otherwise not-a-string, empty, too-long or
  ;; control-character.
  (define (key-name-problem x)
    (cond ((not (string? x)) 'not-a-string)
          ((= (string-length x) 0) 'empty)
          ((> (string-length x) 64) 'too-long)
          ((exists (lambda (c) (let ((n (char->integer c))) (or (< n 32) (= n 127))))
                   (string->list x))
           'control-character)
          (else #f)))
)
