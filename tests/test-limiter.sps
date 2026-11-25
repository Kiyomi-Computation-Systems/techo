#!r6rs
;;; The limiter suite: L3's windows, the two keys, forgive, clear and the
;;; full table. Times are plain numbers in ms, so nothing sleeps.
;;;
;;; Everything that can raise is computed under `attempt`.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (techo limiter))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; try! : Limiter String String Natural -> (U 'try (List ...))
;; The Try itself is opaque, so a test sees 'try.
(define (try! lim email addr now)
  (attempt (lambda ()
             (let ((r (limiter-try! lim email addr now)))
               (if (try? r) 'try r)))))

;; raw-try! : the Try itself, or what was raised
(define (raw-try! lim email addr now)
  (attempt (lambda () (limiter-try! lim email addr now))))

(define (size lim) (attempt (lambda () (limiter-size lim))))

;; tries! : Limiter String String Natural Natural -> (Listof Answer)
(define (tries! lim email addr now n)
  (if (= n 0)
      '()
      (let ((a (try! lim email addr now)))
        (cons a (tries! lim email addr now (- n 1))))))

(test-begin "limiter")

;;; The pure window decisions

(test-equal "window: absent admits"
  #f
  (attempt (lambda () (window-retry-seconds #f 5 0 1000))))

(test-equal "window: under the limit admits"
  #f
  (attempt (lambda () (window-retry-seconds (make-window 0 4) 5 10 1000))))

(test-equal "window: at the limit refuses, seconds left rounded up"
  1
  (attempt (lambda () (window-retry-seconds (make-window 0 5) 5 1 1000))))

(test-equal "window: 1001 ms left is 2 seconds"
  2
  (attempt (lambda () (window-retry-seconds (make-window 0 5) 5 0 1001))))

(test-equal "window: 1000 ms left is exactly 1 second"
  1
  (attempt (lambda () (window-retry-seconds (make-window 0 5) 5 0 1000))))

(test-equal "window: 1 ms left is 1 second"
  1
  (attempt (lambda () (window-retry-seconds (make-window 0 5) 5 999 1000))))

(test-equal "window: at start + window-ms it has expired, so it admits"
  #f
  (attempt (lambda () (window-retry-seconds (make-window 0 5) 5 1000 1000))))

(test-equal "window: bump on an absent window opens one at now with 1"
  '(70 1)
  (attempt (lambda ()
             (let ((w (window-bump #f 70 1000)))
               (list (window-start w) (window-count w))))))

(test-equal "window: bump on a live one grows the count, keeps the start"
  '(0 4)
  (attempt (lambda ()
             (let ((w (window-bump (make-window 0 3) 500 1000)))
               (list (window-start w) (window-count w))))))

(test-equal "window: bump on an expired one reopens at now with 1"
  '(1000 1)
  (attempt (lambda ()
             (let ((w (window-bump (make-window 0 3) 1000 1000)))
               (list (window-start w) (window-count w))))))

;;; The table

(test-equal "try: with the defaults the 5th is allowed and the 6th refused"
  '(try try try try try (limited 900))
  (let ((lim (make-limiter)))
    (tries! lim "a@x" "v4:1.1.1.1" 0 6)))

(test-equal "try: the refusal's seconds are the time left, rounded up"
  '(limited 900)
  (let ((lim (make-limiter)))
    (tries! lim "a@x" "v4:1.1.1.1" 0 5)
    (try! lim "a@x" "v4:1.1.1.1" 1)))

(test-equal "try: 1 ms before the end is one second"
  '(limited 1)
  (let ((lim (make-limiter 2 20 1000 10)))
    (tries! lim "e" "a" 0 2)
    (try! lim "e" "a" 999)))

(test-equal "try: the window's end reopens it"
  '(try try (limited 1) try)
  (let ((lim (make-limiter 2 20 1000 10)))
    (list (try! lim "e" "a" 0) (try! lim "e" "a" 1) (try! lim "e" "a" 999)
          (try! lim "e" "a" 1000))))

(test-equal "try: a reopened window counts from 1 again"
  '(try try (limited 1) (limited 1))
  (let ((lim (make-limiter 2 20 1000 10)))
    (tries! lim "e" "a" 0 2)
    (list (try! lim "e" "a" 1000) (try! lim "e" "a" 1001) (try! lim "e" "a" 1002)
          (try! lim "e" "a" 1003))))

(test-assert "try: the answer is a Try"
  (let ((r (raw-try! (make-limiter) "e" "a" 0)))
    (and (try? r) #t)))

(test-assert "try?: a refusal is not a Try"
  (not (try? '(limited 5))))

(test-assert "try?: other things are not a Try"
  (not (or (try? #f) (try? "x") (try? (vector 1 2)) (try? '()))))

(test-equal "try: another email has its own count"
  '(try try (limited 1) try)
  (let ((lim (make-limiter 2 20 1000 10)))
    (list (try! lim "e1" "a" 0) (try! lim "e1" "a" 0) (try! lim "e1" "a" 0)
          (try! lim "e2" "a" 0))))

(test-equal "try: another address has its own count"
  '(try try (limited 1) try)
  (let ((lim (make-limiter 20 2 1000 10)))
    (list (try! lim "e1" "a1" 0) (try! lim "e2" "a1" 0) (try! lim "e3" "a1" 0)
          (try! lim "e4" "a2" 0))))

(test-equal "try: an address refusal adds nothing to the email"
  ;; address limit 2, email limit 3: e1 tried twice with a1, refused with a1
  ;; (refusal must not count), then two more with a2: the 3rd allowed try
  ;; for e1 is the 3rd counted, so one more is refused
  '(try try (limited 1) try (limited 1))
  (let ((lim (make-limiter 3 2 1000 10)))
    (list (try! lim "e1" "a1" 0) (try! lim "e1" "a1" 0) (try! lim "e1" "a1" 0)
          (try! lim "e1" "a2" 0) (try! lim "e1" "a3" 0))))

(test-equal "try: an email refusal adds nothing to the address"
  ;; email limit 2, address limit 3: e1 twice with a1 (a1 = 2), refused with
  ;; a1 (must not count), then e2 with a1 is a1's 3rd, then a 4th is refused
  '(try try (limited 1) try (limited 1))
  (let ((lim (make-limiter 2 3 1000 10)))
    (list (try! lim "e1" "a1" 0) (try! lim "e1" "a1" 0) (try! lim "e1" "a1" 0)
          (try! lim "e2" "a1" 0) (try! lim "e3" "a1" 0))))

(test-equal "try: a refusal does not open the other key's window"
  '(limited 1 2)
  ;; address a1 is full; the refused try must not open e9's window, so a
  ;; limit of 1 on e9 still lets a try from another address pass
  (let ((lim (make-limiter 1 1 1000 10)))
    (try! lim "e1" "a1" 0)
    (let ((refused (try! lim "e9" "a1" 0)))
      (list (car refused) (cadr refused)
            (size lim)))))

(test-equal "try: both refusing gives the larger seconds"
  '(limited 9)
  ;; e's window starts at 0 (ends 10000), a's at 1000 (ends 11000)
  ;; at 2000: e has 8 s left, a has 9 s left
  (let ((lim (make-limiter 1 1 10000 10)))
    (try! lim "e" "other" 0)
    (try! lim "other" "a" 1000)
    (try! lim "e" "a" 2000)))

(test-equal "try: both refusing, the email's being larger"
  '(limited 9)
  (let ((lim (make-limiter 1 1 10000 10)))
    (try! lim "other" "a" 0)
    (try! lim "e" "other" 1000)
    (try! lim "e" "a" 2000)))

(test-equal "try: only the address refusing gives its seconds"
  '(limited 8)
  (let ((lim (make-limiter 5 1 10000 10)))
    (try! lim "other" "a" 0)
    (try! lim "e" "a" 2000)))

(test-equal "try: only the email refusing gives its seconds"
  '(limited 8)
  (let ((lim (make-limiter 1 5 10000 10)))
    (try! lim "e" "other" 0)
    (try! lim "e" "a" 2000)))

(test-equal "try: an expired window on one key counts as absent while the other refuses"
  '(limited 1)
  (let ((lim (make-limiter 1 1 1000 10)))
    (try! lim "e" "a1" 0)
    (try! lim "e2" "a2" 900)
    ;; at 1000 e's window is over; a2's has 900 ms left
    (try! lim "e2" "a2" 1000)))

(test-equal "try: an email and an address with the same text do not collide"
  '(try try)
  (let ((lim (make-limiter 1 1 1000 10)))
    (list (try! lim "same" "other" 0) (try! lim "other2" "same" 0))))

(test-equal "size: counts windows held, one per key"
  '(0 2 2 3)
  (let ((lim (make-limiter)))
    (let* ((s0 (size lim))
           (a (begin (try! lim "e1" "a1" 0) (size lim)))
           (b (begin (try! lim "e1" "a1" 1) (size lim)))
           (c (begin (try! lim "e2" "a1" 2) (size lim))))
      (list s0 a b c))))

;;; Forgive

(test-equal "forgive: gives back a try from both counts"
  '(try try)
  (let ((lim (make-limiter 1 1 1000 10)))
    (let ((t (raw-try! lim "e" "a" 0)))
      (attempt (lambda () (limiter-forgive! lim t)))
      (list (try! lim "e" "a" 1) (begin (try! lim "x" "y" 2) 'try)))))

(test-equal "forgive: the freed try can be used, then the limit holds"
  '(try (limited 1))
  (let ((lim (make-limiter 1 1 1000 10)))
    (let ((t (raw-try! lim "e" "a" 0)))
      (attempt (lambda () (limiter-forgive! lim t)))
      (list (try! lim "e" "a" 1) (try! lim "e" "a" 999)))))

(test-equal "forgive: takes one from each, not both from one"
  '(try try)
  ;; a1 held 1 try, e1 held 1 try; forgive; both keys admit again
  (let ((lim (make-limiter 1 1 1000 10)))
    (let ((t (raw-try! lim "e1" "a1" 0)))
      (attempt (lambda () (limiter-forgive! lim t)))
      (list (try! lim "e1" "a2" 1) (try! lim "e2" "a1" 1)))))

(test-equal "forgive: never below zero (a double forgive does not bank a free try)"
  '(try (limited 1))
  (let ((lim (make-limiter 1 1 1000 10)))
    (let ((t (raw-try! lim "e" "a" 0)))
      (attempt (lambda () (limiter-forgive! lim t)))
      (attempt (lambda () (limiter-forgive! lim t)))
      (list (try! lim "e" "a" 1) (try! lim "e" "a" 2)))))

(test-equal "forgive: a cleared window is left alone"
  '(try (limited 1))
  ;; try, clear, a new try opens a new window at 5, forgive the old try:
  ;; the new window must keep its count
  (let ((lim (make-limiter 1 20 1000 10)))
    (let ((t (raw-try! lim "e" "a" 0)))
      (attempt (lambda () (limiter-clear-email! lim "e")))
      (let ((first (try! lim "e" "a" 5)))
        (attempt (lambda () (limiter-forgive! lim t)))
        (list first (try! lim "e" "a" 6))))))

(test-equal "forgive: an expired-and-reopened window is left alone"
  '(try (limited 1))
  (let ((lim (make-limiter 1 20 1000 10)))
    (let ((t (raw-try! lim "e" "a" 0)))
      (let ((second (try! lim "e" "a" 1000)))
        (attempt (lambda () (limiter-forgive! lim t)))
        (list second (try! lim "e" "a" 1001))))))

(test-equal "forgive: a swept window is left alone"
  '(try (limited 1))
  ;; max 2: t's windows (e, a) expire. e2/a at 1000 needs a new e2 and a
  ;; reopened a, so the table is full, the sweep drops e and a, and a opens
  ;; again at 1000. Forgiving t must not touch the new a.
  (let ((lim (make-limiter 5 1 1000 2)))
    (let ((t (raw-try! lim "e" "a" 0)))
      (let ((r (try! lim "e2" "a" 1000)))
        (attempt (lambda () (limiter-forgive! lim t)))
        (list r (try! lim "e3" "a" 1001))))))

(test-equal "forgive: after a clear the address is left alone but the email is gone"
  '(try (limited 1))
  ;; the address's window is the same, so it IS forgiven; the email's is gone.
  ;; So a new try from a fresh email passes, then the address is full again.
  (let ((lim (make-limiter 5 1 1000 10)))
    (let ((t (raw-try! lim "e" "a" 0)))
      (attempt (lambda () (limiter-clear-email! lim "e")))
      (attempt (lambda () (limiter-forgive! lim t)))
      (list (try! lim "e2" "a" 1) (try! lim "e3" "a" 2)))))

(test-equal "forgive: a window at zero is removed"
  '(0)
  (let ((lim (make-limiter)))
    (let ((t (raw-try! lim "e" "a" 0)))
      (attempt (lambda () (limiter-forgive! lim t)))
      (list (size lim)))))

(test-assert "forgive: nothing raised on a Try whose windows are gone"
  (let ((lim (make-limiter)))
    (let ((t (raw-try! lim "e" "a" 0)))
      (limiter-clear-email! lim "e")
      (equal? 'ok (attempt (lambda () (limiter-forgive! lim t) (limiter-forgive! lim t) 'ok))))))

;;; Clear

(test-equal "clear: removes the email's window"
  '(try try)
  (let ((lim (make-limiter 1 20 1000 10)))
    (list (try! lim "e" "a" 0)
          (begin (attempt (lambda () (limiter-clear-email! lim "e")))
                 (try! lim "e" "a" 1)))))

(test-equal "clear: leaves the address's window"
  '(try (limited 1))
  (let ((lim (make-limiter 20 1 1000 10)))
    (list (try! lim "e" "a" 0)
          (begin (attempt (lambda () (limiter-clear-email! lim "e")))
                 (try! lim "e" "a" 999)))))

(test-equal "clear: leaves other emails alone"
  '(limited 1)
  (let ((lim (make-limiter 1 20 1000 10)))
    (try! lim "e1" "a" 0)
    (try! lim "e2" "a" 0)
    (attempt (lambda () (limiter-clear-email! lim "e1")))
    (try! lim "e2" "a" 1)))

(test-equal "clear: an email with no window is fine"
  'ok
  (attempt (lambda () (limiter-clear-email! (make-limiter) "nobody") 'ok)))

(test-equal "clear: the size drops by one"
  '(2 1)
  (let ((lim (make-limiter)))
    (try! lim "e" "a" 0)
    (let ((before (size lim)))
      (attempt (lambda () (limiter-clear-email! lim "e")))
      (list before (size lim)))))

;;; The table is full

(test-equal "full: a try that would add a window past the max is refused, 60 s, first"
  '((try try) (full 60 #t) 2)
  (let ((lim (make-limiter 5 5 1000 2)))
    (let* ((a (try! lim "e1" "a1" 0))
           (a2 (try! lim "e1" "a1" 1))
           (b (try! lim "e2" "a2" 2)))
      (list (list a a2) b (size lim)))))

(test-equal "full: the refused try counts nothing, not even the window that fit"
  '(2 (full 60 #t))
  ;; max 3: e1/a1 take two; e2/a2 needs two more, only one fits: refused
  ;; whole, and the size stays 2
  (let ((lim (make-limiter 5 5 1000 3)))
    (try! lim "e1" "a1" 0)
    (let ((r (try! lim "e2" "a2" 1)))
      (list (size lim) r))))

(test-equal "full: a try needing one window fits when one is free"
  '(try 3)
  (let ((lim (make-limiter 5 5 1000 3)))
    (try! lim "e1" "a1" 0)
    (list (try! lim "e2" "a1" 1) (size lim))))

(test-equal "full: a try for existing windows is not refused when full"
  '(try 2)
  (let ((lim (make-limiter 5 5 1000 2)))
    (try! lim "e1" "a1" 0)
    (list (try! lim "e1" "a1" 1) (size lim))))

(test-equal "full: a rate-limit refusal wins over a full table"
  '(limited 1)
  (let ((lim (make-limiter 1 1 1000 2)))
    (try! lim "e1" "a1" 0)
    (try! lim "e1" "a1" 999)))

(test-equal "full: the sweep drops expired windows, so the try is admitted"
  '(try 2)
  (let ((lim (make-limiter 5 5 1000 2)))
    (try! lim "e1" "a1" 0)
    (list (try! lim "e2" "a2" 1000) (size lim))))

(test-equal "full: after a sweep the live window still counts"
  '(try (limited 1))
  ;; max 4: e1/a1 at 0, e2/a2 at 500. At 1000 e3/a3 sweeps e1 and a1; a2
  ;; is live and at its limit of 1.
  (let ((lim (make-limiter 5 1 1000 4)))
    (try! lim "e1" "a1" 0)
    (try! lim "e2" "a2" 500)
    (list (try! lim "e3" "a3" 1000)
          (try! lim "e4" "a2" 1001))))

(test-equal "full: nothing expired, so the sweep frees nothing and the try is refused"
  '((full 60 #t) 4)
  (let ((lim (make-limiter 5 5 1000 4)))
    (try! lim "e1" "a1" 0)
    (try! lim "e2" "a2" 500)
    (let ((r (try! lim "e3" "a3" 700)))
      (list r (size lim)))))

(test-equal "full: first? is #t, #f, then #t again after room returns"
  '((full 60 #t) (full 60 #f) (full 60 #f) try (full 60 #t))
  (let ((lim (make-limiter 5 5 1000 2)))
    (try! lim "e1" "a1" 0)
    (let* ((r1 (try! lim "e2" "a2" 1))
           (r2 (try! lim "e2" "a2" 2))
           (r3 (try! lim "e2" "a2" 3))
           ;; room returns: the first windows expire and are swept
           (ok (try! lim "e2" "a2" 1000))
           (r4 (try! lim "e3" "a3" 1001)))
      (list r1 r2 r3 ok r4))))

(test-equal "full: first? is #t again after a clear gives room"
  '((full 60 #t) (full 60 #f) try (full 60 #t))
  (let ((lim (make-limiter 5 5 1000 2)))
    (try! lim "e1" "a1" 0)
    (let* ((r1 (try! lim "e2" "a2" 1))
           (r2 (try! lim "e2" "a2" 2))
           (ok (begin (attempt (lambda () (limiter-clear-email! lim "e1")))
                      (try! lim "e5" "a1" 3)))
           (r3 (try! lim "e6" "a6" 4)))
      (list r1 r2 ok r3))))

(test-equal "full: the table never holds more than the max"
  #t
  (let ((lim (make-limiter 5 5 1000 4)))
    (let loop ((i 0) (ok #t))
      (if (= i 20)
          ok
          (begin
            (try! lim (string-append "e" (number->string i))
                  (string-append "a" (number->string i)) (* i 10))
            (loop (+ i 1) (and ok (<= (size lim) 4))))))))

(test-end "limiter")

(exit (suite-exit-status runner))
