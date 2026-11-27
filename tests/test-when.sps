#!r6rs
;;; The when suite: slice 6's When, (techo when). All pure.
;;;
;;;   the three forms   a date, a local time and a moment, each answered as
;;;                     itself, at its edges
;;;   their shape       every other length, every punctuation and digit
;;;                     position wrong, case, offsets, fractions, signs
;;;   the calendar      years, months, days, hours, minutes and seconds at
;;;                     their limits; the Gregorian leap rule; a sweep of
;;;                     real and unreal dates against a table written here
;;;   real-date?        the calendar alone, as (techo contact) asks it
;;;   what is no string refused, and nothing raised
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (techo when))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define (written x) (call-with-string-output-port (lambda (p) (write x p))))

;; with-char : String Natural Char -> String     S with its Ith character C
(define (with-char s i c)
  (string-append (substring s 0 i) (string c) (substring s (+ i 1) (string-length s))))

;; two : Natural -> String     N as two ASCII digits, written out by hand
(define (two n)
  (if (< n 10) (string-append "0" (number->string n)) (number->string n)))

;; four : Natural -> String     N as four ASCII digits
(define (four n)
  (let ((s (number->string n)))
    (string-append (make-string (- 4 (string-length s)) #\0) s)))

(define date "2026-12-01")
(define local "2026-12-01T15:00")
(define moment "2026-12-01T20:00:00Z")

;; Arabic-Indic digit one, and full-width digits zero and one: char-numeric?
;; is true of each, and none is a digit here.
(define arabic-one (integer->char #x661))
(define wide-zero (integer->char #xff10))
(define wide-one (integer->char #xff11))

(test-begin "when")

;;; The three forms, each answered as itself

(test-equal "forms: a date, a local time and a moment, each as itself"
  (list date local moment)
  (attempt (lambda () (map parse-when (list date local moment)))))

(test-equal "forms: the earliest and the latest of each"
  '("0001-01-01" "9999-12-31" "0001-01-01T00:00" "9999-12-31T23:59"
    "0001-01-01T00:00:00Z" "9999-12-31T23:59:59Z")
  (attempt (lambda ()
             (map parse-when
                  '("0001-01-01" "9999-12-31" "0001-01-01T00:00" "9999-12-31T23:59"
                    "0001-01-01T00:00:00Z" "9999-12-31T23:59:59Z")))))

(test-equal "forms: the answer is the string given, not a copy"
  '(#t #t #t)
  (attempt (lambda () (map (lambda (s) (eq? (parse-when s) s)) (list date local moment)))))

;;; Their shape: every other length

(for-each
 (lambda (c)
   (test-equal (string-append "length: refused, " (car c))
     'invalid
     (attempt (lambda () (parse-when (cdr c))))))
 (list (cons "0 characters" "")
       (cons "9, a date short a digit" "2026-12-0")
       (cons "11, a date and a digit" "2026-12-011")
       (cons "11, a date and a T" "2026-12-01T")
       (cons "15, a local time short a digit" "2026-12-01T15:0")
       (cons "17, a local time and a digit" "2026-12-01T15:001")
       (cons "17, a local time and a colon" "2026-12-01T15:00:")
       (cons "17, a local time and a Z" "2026-12-01T15:00Z")
       (cons "19, a moment without its Z" "2026-12-01T20:00:00")
       (cons "21, a moment and a digit" "2026-12-01T20:00:00Z0")
       (cons "21, a moment and a second Z" "2026-12-01T20:00:00ZZ")
       (cons "12, a five-digit year" "20260-12-01")
       (cons "8, no hyphens" "20261201")
       (cons "15, the basic format" "20261201T150000")
       (cons "16, a local time without its T, padded" "2026-12-01 15:00")))

;;; Every punctuation position wrong, in each form

;; punctuation : (Listof (List String (Listof Natural)))
;; Each form's sample, and where its punctuation is, written out here.
(define punctuation
  (list (list date '(4 7))
        (list local '(4 7 10 13))
        (list moment '(4 7 10 13 16 19))))

;; Every punctuation character in its wrong place, a digit, a space, a
;; slash and a dot: what each position must refuse.
(define wrong-punctuation (list #\- #\: #\T #\Z #\0 #\space #\/ #\. #\t #\z))

;; punctuation-cases : -> (Listof String)
;; Each position's punctuation replaced by every other character of
;; wrong-punctuation, in each form.
(define (punctuation-cases)
  (apply append
         (map (lambda (form)
                (let ((s (car form)))
                  (apply append
                         (map (lambda (i)
                                (map (lambda (c) (with-char s i c))
                                     (filter (lambda (c) (not (char=? c (string-ref s i))))
                                             wrong-punctuation)))
                              (cadr form)))))
              punctuation)))

;; How many were judged, and each one taken: a sweep that judged none
;; cannot pass.
(test-equal "punctuation: each position, with every other character, refused (108 strings)"
  '(108 ())
  (attempt (lambda ()
             (let ((cases (punctuation-cases)))
               (list (length cases)
                     (filter (lambda (x) (not (eq? (parse-when x) 'invalid))) cases))))))

(for-each
 (lambda (c)
   (test-equal (string-append "case and offsets: refused, " (car c))
     'invalid
     (attempt (lambda () (parse-when (cdr c))))))
 (list (cons "a lower-case t, local" "2026-12-01t15:00")
       (cons "a lower-case t, moment" "2026-12-01t20:00:00Z")
       (cons "a lower-case z" "2026-12-01T20:00:00z")
       (cons "both lower case" "2026-12-01t20:00:00z")
       (cons "a space for T, local" "2026-12-01 15:00")
       (cons "a space for T, moment" "2026-12-01 20:00:00Z")
       (cons "an offset +00:00" "2026-12-01T20:00:00+00:00")
       (cons "an offset -05:00" "2026-12-01T15:00:00-05:00")
       (cons "an offset +0000" "2026-12-01T20:00:00+0000")
       (cons "a local time with an offset" "2026-12-01T15:00+01")
       (cons "a fraction of a second" "2026-12-01T20:00:00.5Z")
       (cons "a fraction of zero" "2026-12-01T20:00:00.000Z")
       (cons "a local time with seconds" "2026-12-01T15:00:00")
       (cons "a moment without seconds" "2026-12-01T20:00Z")
       (cons "a leading space" " 2026-12-01")
       (cons "a trailing space" "2026-12-01 ")
       (cons "a trailing newline" "2026-12-01\n")
       (cons "a week date" "2026-W48-1T")
       (cons "an ordinal date" "2026-335-01")))

;;; Every digit position, with what is no ASCII digit

;; digit-positions : (Listof (Pair String (Listof Natural)))
;; Each form's sample and where its digits are, written out here.
(define digit-positions
  (list (cons date '(0 1 2 3 5 6 8 9))
        (cons local '(0 1 2 3 5 6 8 9 11 12 14 15))
        (cons moment '(0 1 2 3 5 6 8 9 11 12 14 15 17 18))))

;; Just below and just above the ASCII digits, a letter, a space, and three
;; that char-numeric? takes.
(define not-digits (list #\/ #\: #\a #\O #\space arabic-one wide-zero wide-one))

;; digit-cases : -> (Listof String)
;; Each digit position, in each form, with each of not-digits.
(define (digit-cases)
  (apply append
         (map (lambda (form)
                (apply append
                       (map (lambda (i) (map (lambda (c) (with-char (car form) i c)) not-digits))
                            (cdr form))))
              digit-positions)))

(test-equal "digits: each position, with each of / : a O space U+0661 U+FF10 U+FF11, refused (272 strings)"
  '(272 ())
  (attempt (lambda ()
             (let ((cases (digit-cases)))
               (list (length cases)
                     (filter (lambda (x) (not (eq? (parse-when x) 'invalid))) cases))))))

(for-each
 (lambda (c)
   (test-equal (string-append "digits: refused, " (car c))
     'invalid
     (attempt (lambda () (parse-when (cdr c))))))
 (list (cons "U+0661 as a year's last digit (202 then Arabic-Indic one)"
             (string-append "202" (string arabic-one) "-12-01"))
       (cons "U+0661 as a day's last digit" (string-append "2026-12-0" (string arabic-one)))
       (cons "a full-width year" (string wide-one wide-zero wide-zero wide-zero #\- #\1 #\2 #\- #\0 #\1))
       (cons "a full-width year's last digit"
             (string-append "202" (string wide-one) "-12-01"))
       (cons "a sign: +026-12-01" "+026-12-01")
       (cons "a sign: -026-12-01" "-026-12-01")
       (cons "a sign in the month: 2026-+1-01" "2026-+1-01")
       (cons "a sign in the day: 2026-12-+1" "2026-12-+1")
       (cons "a sign in the hour: 2026-12-01T+1:00" "2026-12-01T+1:00")
       (cons "an exponent: 1e03-12-01" "1e03-12-01")
       (cons "hex: #x1F as a year's" "#x1F-12-01")
       (cons "a decimal point in the year: 202.-12-01" "202.-12-01")
       (cons "a space in the year: 202 -12-01" "202 -12-01")
       (cons "one-digit month and day, padded right" "2026-1 -1 ")))

;;; The calendar's limits

(for-each
 (lambda (c)
   (test-equal (string-append "calendar: refused, " (car c))
     'invalid
     (attempt (lambda () (parse-when (cdr c))))))
 (list (cons "year 0000" "0000-01-01")
       (cons "year 0000, local" "0000-01-01T00:00")
       (cons "year 0000, moment" "0000-01-01T00:00:00Z")
       (cons "month 00" "2026-00-01")
       (cons "month 13" "2026-13-01")
       (cons "month 99" "2026-99-01")
       (cons "day 00" "2026-12-00")
       (cons "day 32" "2026-12-32")
       (cons "day 99" "2026-01-99")
       (cons "31 April" "2026-04-31")
       (cons "31 June" "2026-06-31")
       (cons "31 September" "2026-09-31")
       (cons "31 November" "2026-11-31")
       (cons "30 February" "2024-02-30")
       (cons "29 February 1900" "1900-02-29")
       (cons "29 February 2100" "2100-02-29")
       (cons "29 February 2023" "2023-02-29")
       (cons "29 February 2023, local" "2023-02-29T12:00")
       (cons "29 February 2023, moment" "2023-02-29T12:00:00Z")
       (cons "hour 24, local: 24:00" "2026-12-01T24:00")
       (cons "hour 24, moment" "2026-12-01T24:00:00Z")
       (cons "hour 99" "2026-12-01T99:00")
       (cons "minute 60, local" "2026-12-01T23:60")
       (cons "minute 60, moment" "2026-12-01T23:60:00Z")
       (cons "a leap second, :60" "2016-12-31T23:59:60Z")
       (cons "second 99" "2026-12-01T20:00:99Z")))

(test-equal "calendar: 29 February in 1600, 2000, 2024, 2400 and 9996, taken"
  '("1600-02-29" "2000-02-29" "2024-02-29" "2400-02-29" "9996-02-29")
  (attempt (lambda ()
             (map parse-when '("1600-02-29" "2000-02-29" "2024-02-29" "2400-02-29" "9996-02-29")))))

(test-equal "calendar: 30 April, 28 February 2023, 31 December, taken"
  '("2026-04-30" "2023-02-28" "2026-12-31")
  (attempt (lambda () (map parse-when '("2026-04-30" "2023-02-28" "2026-12-31")))))

;;; The sweep: real and unreal dates, against a table written here

;; Days in each month of a common year, January first, written out by hand.
(define common-days '#(31 28 31 30 31 30 31 31 30 31 30 31))

;; The sweep's years, each marked leap or not by hand: the four-year rule,
;; the century exception and its four-century exception.
(define sweep-years
  '((1 . #f) (4 . #t) (100 . #f) (400 . #t) (1600 . #t) (1700 . #f) (1800 . #f)
    (1900 . #f) (1996 . #t) (1999 . #f) (2000 . #t) (2023 . #f) (2024 . #t)
    (2100 . #f) (2400 . #t) (9996 . #t) (9999 . #f)))

;; table-real? : Natural Natural Natural -> Boolean     by the table above, not the code under test
(define (table-real? year month day)
  (and (<= 1 month 12)
       (<= 1 day (+ (vector-ref common-days (- month 1))
                    (if (and (= month 2) (cdr (assv year sweep-years))) 1 0)))))

;; The three forms of one day, at a time inside the day.
(define (forms-of y m d)
  (let ((day (string-append (four y) "-" (two m) "-" (two d))))
    (list day (string-append day "T12:34") (string-append day "T12:34:56Z"))))

;; sweep : -> (List Natural (Listof String))
;; How many strings were judged, and each one answered against the table.
(define (sweep)
  (let loop-y ((ys sweep-years) (n 0) (bad '()))
    (if (null? ys)
        (list n (reverse bad))
        (let loop-m ((m 0) (n n) (bad bad))
          (if (> m 13)
              (loop-y (cdr ys) n bad)
              (let loop-d ((d 0) (n n) (bad bad))
                (if (> d 32)
                    (loop-m (+ m 1) n bad)
                    (let* ((y (car (car ys)))
                           (want (table-real? y m d))
                           (wrong (filter (lambda (s)
                                            (not (equal? (parse-when s) (if want s 'invalid))))
                                          (forms-of y m d))))
                      (loop-d (+ d 1) (+ n 3) (append wrong bad))))))))))

;; table-days : -> (List Natural Natural)
;; The days the table holds in 2024 and in 2023: a check of the table itself,
;; 366 and 365, so the sweep cannot pass against a wrong one.
(define (table-days)
  (map (lambda (y)
         (let loop ((m 1) (d 1) (n 0))
           (cond ((> m 12) n)
                 ((> d 31) (loop (+ m 1) 1 n))
                 (else (loop m (+ d 1) (if (table-real? y m d) (+ n 1) n))))))
       '(2024 2023)))

(test-equal "sweep: 17 years, months 0 to 13, days 0 to 32, each form, against the table (366 and 365 days)"
  (list (* 17 14 33 3) '() '(366 365))
  (attempt (lambda () (append (sweep) (list (table-days))))))

;; 9999 years hold 2,424 leap years: 2,499 multiples of 4, less 99
;; centuries, plus 24 multiples of 400. A number known, not computed.
(test-equal "sweep: 29 February is taken in exactly 2,424 of the years 0001 to 9999"
  2424
  (attempt (lambda ()
             (let loop ((y 1) (n 0))
               (if (> y 9999)
                   n
                   (loop (+ y 1)
                         (if (string? (parse-when (string-append (four y) "-02-29"))) (+ n 1) n)))))))

(test-equal "sweep: 1 January is taken in every year 0001 to 9999, and not in 0000"
  '(9999 invalid)
  (attempt (lambda ()
             (list (let loop ((y 1) (n 0))
                     (if (> y 9999)
                         n
                         (loop (+ y 1)
                               (if (string? (parse-when (string-append (four y) "-01-01"))) (+ n 1) n))))
                   (parse-when "0000-01-01")))))

;; times : -> (List Natural (Listof String))
;; Every hour 0 to 25 and minute 0 to 61 as a local time, and every second
;; 0 to 61 at 23:59 as a moment, against the limits 23, 59 and 59.
(define (times)
  (let* ((locals (let loop-h ((h 0) (acc '()))
                   (if (> h 25)
                       acc
                       (loop-h (+ h 1)
                               (let loop-m ((m 0) (acc acc))
                                 (if (> m 61)
                                     acc
                                     (loop-m (+ m 1)
                                             (cons (cons (string-append "2026-12-01T" (two h) ":" (two m))
                                                         (and (<= h 23) (<= m 59)))
                                                   acc))))))))
         (moments (let loop-s ((s 0) (acc '()))
                    (if (> s 61)
                        acc
                        (loop-s (+ s 1)
                                (cons (cons (string-append "2026-12-01T23:59:" (two s) "Z") (<= s 59))
                                      acc)))))
         (all (append locals moments)))
    (list (length all)
          (map car (filter (lambda (c) (not (equal? (parse-when (car c)) (if (cdr c) (car c) 'invalid))))
                           all)))))

(test-equal "sweep: hours 00 to 25, minutes 00 to 61, seconds 00 to 61, against 23, 59, 59"
  (list (+ (* 26 62) 62) '())
  (attempt times))

;;; real-date?, the calendar alone

(test-equal "real-date?: 29 February 2024 and 2000; 1 January 1 and 31 December 9999"
  '(#t #t #t #t)
  (attempt (lambda () (list (real-date? 2024 2 29) (real-date? 2000 2 29)
                            (real-date? 1 1 1) (real-date? 9999 12 31)))))

(test-equal "real-date?: 29 February 1900 and 2023; 31 April; year 0 and 10000; month 0 and 13; day 0 and 32"
  '(#f #f #f #f #f #f #f #f #f)
  (attempt (lambda () (list (real-date? 1900 2 29) (real-date? 2023 2 29) (real-date? 2026 4 31)
                            (real-date? 0 1 1) (real-date? 10000 1 1)
                            (real-date? 2026 0 1) (real-date? 2026 13 1)
                            (real-date? 2026 1 0) (real-date? 2026 1 32)))))

(test-equal "real-date?: what is no exact integer is #f, and nothing raised"
  '(#f #f #f #f #f #f)
  (attempt (lambda () (list (real-date? 2024.0 2 29) (real-date? 2024 2.0 29) (real-date? 2024 2 29.0)
                            (real-date? "2024" 2 29) (real-date? 2024 'null 29) (real-date? #f #f #f)))))

;;; What is no string, refused, and nothing raised

(for-each
 (lambda (x)
   (test-equal (string-append "not a string: refused, " (written x))
     'invalid
     (attempt (lambda () (parse-when x)))))
 (list 20261201 2026.12 #f #t 'null '() '#() (vector date) (list date) (cons date date)
       'date #\2 (string->utf8 date) (list (cons "at" date))))

(test-end "when")

(exit (suite-exit-status runner))
