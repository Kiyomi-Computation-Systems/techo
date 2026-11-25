#!r6rs
;;; (techo limiter): L3's rate limit. The decisions are pure procedures on a
;;; window (its start in ms and its count); one mutable table, owned by the
;;; loop's thread, sits on top. The clock is one that never goes backwards.
;;;
;;; A try counts against the address and the email, or against neither.
(library (techo limiter)
  (export make-window window-start window-count
          window-retry-seconds window-bump window-forgive
          make-limiter limiter-try! limiter-forgive! limiter-clear-email!
          limiter-size try?)
  (import (rnrs))

  ;;; The pure decisions

  ;; A window: when it opened (ms) and how many tries it holds.
  (define-record-type window
    (fields start count))

  ;; make-window : Natural Natural -> Window
  ;; window-start : Window -> Natural
  ;; window-count : Window -> Natural

  ;; expired? : Window Natural Natural -> Boolean
  (define (expired? w now window-ms)
    (>= now (+ (window-start w) window-ms)))

  ;; live : (U Window #f) Natural Natural -> (U Window #f)
  ;; An expired window counts as absent.
  (define (live w now window-ms)
    (and w (not (expired? w now window-ms)) w))

  ;; window-retry-seconds : (U Window #f) Natural Natural Natural -> (U Natural #f)
  ;; #f when a try fits. At the limit, the seconds left in the window,
  ;; rounded up, at least 1.
  (define (window-retry-seconds w limit now window-ms)
    (let ((w (live w now window-ms)))
      (and w
           (>= (window-count w) limit)
           (let ((left-ms (- (+ (window-start w) window-ms) now)))
             (max 1 (div (+ left-ms 999) 1000))))))

  ;; window-bump : (U Window #f) Natural Natural -> Window
  ;; One more try. An absent or expired window opens at now with 1.
  (define (window-bump w now window-ms)
    (let ((w (live w now window-ms)))
      (if w
          (make-window (window-start w) (+ (window-count w) 1))
          (make-window now 1))))

  ;; window-forgive : (U Window #f) Natural -> (U Window #f)
  ;; Takes one back, only when the window still has the start the try saw.
  ;; Never below zero. A window at zero is gone (#f).
  (define (window-forgive w start)
    (cond ((not w) #f)
          ((not (= (window-start w) start)) w)
          ((<= (window-count w) 1) #f)
          (else (make-window (window-start w) (- (window-count w) 1)))))

  ;;; The table

  ;; A Try: the two keys and each window's start, held so forgive can tell
  ;; whether the window is still the one that was counted.
  ;; try? : Any -> Boolean
  (define-record-type try
    (opaque #t)
    (fields email-key email-start address-key address-start))

  (define-record-type (limiter make-limiter* limiter?)
    (fields email-limit address-limit window-ms max-windows
            emails addresses
            (mutable full-logged?)))

  ;; make-limiter : [Natural Natural Natural Natural] -> Limiter
  ;; email-limit 5, address-limit 20, window-ms 900000, max-windows 10000.
  (define make-limiter
    (case-lambda
      (() (make-limiter 5))
      ((e) (make-limiter e 20))
      ((e a) (make-limiter e a 900000))
      ((e a w) (make-limiter e a w 10000))
      ((e a w m)
       (make-limiter* e a w m (make-hashtable string-hash string=?)
                      (make-hashtable string-hash string=?) #f))))

  ;; limiter-size : Limiter -> Natural
  (define (limiter-size lim)
    (+ (hashtable-size (limiter-emails lim))
       (hashtable-size (limiter-addresses lim))))

  ;; sweep! : Limiter Natural -> Void
  ;; Drops every expired window.
  (define (sweep! lim now)
    (for-each
     (lambda (table)
       (vector-for-each
        (lambda (k)
          (when (expired? (hashtable-ref table k #f) now (limiter-window-ms lim))
            (hashtable-delete! table k)))
        (hashtable-keys table)))
     (list (limiter-emails lim) (limiter-addresses lim))))

  ;; room-note! : Limiter -> Void
  ;; When the table has room, the next full refusal is a first again.
  (define (room-note! lim)
    (when (< (limiter-size lim) (limiter-max-windows lim))
      (limiter-full-logged?-set! lim #f)))

  ;; growth : Limiter String String -> Natural
  ;; The windows this try would add: keys with no entry at all.
  (define (growth lim email-key address-key)
    (+ (if (hashtable-contains? (limiter-emails lim) email-key) 0 1)
       (if (hashtable-contains? (limiter-addresses lim) address-key) 0 1)))

  ;; limiter-try! : Limiter String String Natural
  ;;                -> (U Try (List 'limited Natural) (List 'full Natural Boolean))
  ;; Check and count in one go. The address is checked first, then the
  ;; email. If either refuses, neither count grows and the answer is
  ;; (limited seconds), the larger when both refuse. When a new window would
  ;; pass max-windows, expired ones are swept; if there is still no room,
  ;; nothing is counted and the answer is (full 60 first?).
  (define (limiter-try! lim email-key address-key now)
    (let* ((ms (limiter-window-ms lim))
           (emails (limiter-emails lim))
           (addresses (limiter-addresses lim))
           (ew (hashtable-ref emails email-key #f))
           (aw (hashtable-ref addresses address-key #f))
           (ra (window-retry-seconds aw (limiter-address-limit lim) now ms))
           (re (window-retry-seconds ew (limiter-email-limit lim) now ms)))
      (cond
        ((or ra re)
         (room-note! lim)
         (list 'limited (max (or ra 1) (or re 1))))
        (else
         (when (> (+ (limiter-size lim) (growth lim email-key address-key))
                  (limiter-max-windows lim))
           (sweep! lim now))
         (if (> (+ (limiter-size lim) (growth lim email-key address-key))
                (limiter-max-windows lim))
             (let ((first? (not (limiter-full-logged? lim))))
               (limiter-full-logged?-set! lim #t)
               (list 'full 60 first?))
             (let ((ew (live (hashtable-ref emails email-key #f) now ms))
                   (aw (live (hashtable-ref addresses address-key #f) now ms)))
               (let ((e (window-bump ew now ms))
                     (a (window-bump aw now ms)))
                 (hashtable-set! emails email-key e)
                 (hashtable-set! addresses address-key a)
                 ;; this try found room, so the next full refusal is a first
                 (limiter-full-logged?-set! lim #f)
                 (make-try email-key (window-start e) address-key (window-start a)))))))))

  ;; forgive-in! : Hashtable String Natural -> Void
  (define (forgive-in! table key start)
    (let ((w (hashtable-ref table key #f)))
      (when w
        (let ((w2 (window-forgive w start)))
          (if w2
              (hashtable-set! table key w2)
              (hashtable-delete! table key))))))

  ;; limiter-forgive! : Limiter Try -> Void
  ;; Takes one from each of the try's two counts, where the window is still
  ;; the one the try was counted in.
  (define (limiter-forgive! lim t)
    (forgive-in! (limiter-emails lim) (try-email-key t) (try-email-start t))
    (forgive-in! (limiter-addresses lim) (try-address-key t) (try-address-start t))
    (room-note! lim))

  ;; limiter-clear-email! : Limiter String -> Void
  (define (limiter-clear-email! lim email-key)
    (hashtable-delete! (limiter-emails lim) email-key)
    (room-note! lim))
  )
