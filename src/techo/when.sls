#!r6rs
;;; (techo when): slice 6's When (P6). A date, a local time or a moment, as
;;; a string, checked to be real and kept as given: the server never
;;; converts or compares one. Pure.
;;;
;;;   date     YYYY-MM-DD             10 characters
;;;   local    YYYY-MM-DDTHH:MM       16
;;;   moment   YYYY-MM-DDTHH:MM:SSZ   20
;;;
;;; A digit is U+0030 to U+0039, by code point: char-numeric? is true of
;;; U+0661, and string->number reads "+12" as 12 and "1e2" as 100.0. Nothing
;;; here raises.
(library (techo when)
  (export parse-when real-date?)
  (import (rnrs))

  ;; leap-year? : Natural -> Boolean     the Gregorian rule, centuries and all
  (define (leap-year? y)
    (and (zero? (mod y 4))
         (or (not (zero? (mod y 100))) (zero? (mod y 400)))))

  ;; days-in : Natural Natural -> Natural     the days of month M, 1 to 12, of year Y
  (define (days-in y m)
    (case m
      ((4 6 9 11) 30)
      ((2) (if (leap-year? y) 29 28))
      (else 31)))

  ;; whole? : Any -> Boolean     an exact integer: 1.0 is none
  (define (whole? x) (and (integer? x) (exact? x)))

  ;; real-date? : Any Any Any -> Boolean
  ;; Whether year Y, month M and day D, each an exact integer, are a real day
  ;; of the Gregorian calendar, in the years 1 to 9999. #f for anything else,
  ;; what is no exact integer too. Never raises.
  (define (real-date? y m d)
    (and (whole? y) (whole? m) (whole? d)
         (<= 1 y 9999)
         (<= 1 m 12)
         (<= 1 d (days-in y m))))

  ;; digits-at : String Natural Natural -> (U Natural #f)
  ;; The number the N characters of S from I spell, when each is an ASCII
  ;; digit; #f otherwise. S holds them: the caller has checked its length.
  (define (digits-at s i n)
    (let loop ((k 0) (acc 0))
      (if (= k n)
          acc
          (let ((c (char->integer (string-ref s (+ i k)))))
            (and (<= #x30 c #x39)
                 (loop (+ k 1) (+ (* acc 10) (- c #x30))))))))

  ;; char-at? : String Natural Char -> Boolean
  (define (char-at? s i c) (char=? (string-ref s i) c))

  ;; date-ok? : String -> Boolean     its first ten characters a real date
  (define (date-ok? s)
    (and (char-at? s 4 #\-)
         (char-at? s 7 #\-)
         (let ((y (digits-at s 0 4)) (m (digits-at s 5 2)) (d (digits-at s 8 2)))
           (and y m d (real-date? y m d)))))

  ;; time-ok? : String -> Boolean     characters 10 to 15: T, then 00:00 to 23:59
  (define (time-ok? s)
    (and (char-at? s 10 #\T)
         (char-at? s 13 #\:)
         (let ((h (digits-at s 11 2)) (m (digits-at s 14 2)))
           (and h m (<= h 23) (<= m 59)))))

  ;; seconds-ok? : String -> Boolean     characters 16 to 19: :00 to :59, then Z
  (define (seconds-ok? s)
    (and (char-at? s 16 #\:)
         (char-at? s 19 #\Z)
         (let ((sec (digits-at s 17 2)))
           (and sec (<= sec 59)))))

  ;; parse-when : Any -> (U String 'invalid)
  ;; X itself when it is a string of exactly one of the three forms, with
  ;; its punctuation exact, T and Z upper case, ASCII digits, and a real day
  ;; and time: years 0001 to 9999, the Gregorian leap rule, hours 00 to 23,
  ;; minutes and seconds 00 to 59. 'invalid for anything else: another
  ;; length, a space, a lower-case letter, an offset, a fraction, a leap
  ;; second, a sign, what is no string. Its length is checked before any
  ;; character is read. Never raises.
  (define (parse-when x)
    (if (and (string? x)
             (case (string-length x)
               ((10) (date-ok? x))
               ((16) (and (date-ok? x) (time-ok? x)))
               ((20) (and (date-ok? x) (time-ok? x) (seconds-ok? x)))
               (else #f)))
        x
        'invalid))
)
