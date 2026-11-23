#!r6rs
;;; (explore): a breadth-first explorer of a finite world graph, for tests.
;;;
;;; Test-only: it lives in tests/, which make test puts on Chez's library
;;; path, not in src/. Slice 2's migration model and slice 2b's shutdown
;;; machine use it.
(library (explore)
  (export explore)
  (import (rnrs))

  ;; explore : World (World -> (Listof (Pairof Label World)))
  ;;           (World -> (U #f String)) (World -> (U #f String))
  ;;           [(World -> Integer)]
  ;;           -> (U (List 'ok Natural) (List 'violated String (Listof Label))
  ;;                 (List 'cycle (Listof Label)))
  ;; Arguments: the start world; the next worlds, each with the label of the
  ;; step that makes it; the invariant, checked in every world, the start
  ;; included, answering a string that names the broken property; the final
  ;; check, called only at a world with no next worlds.
  ;; Breadth-first, so a violation's trace, the labels from the start, is a
  ;; shortest one. 'ok carries the number of distinct worlds, compared with
  ;; equal?. A raise from any of the three procedures is reported as
  ;; (violated "raised: <message>" trace). With no violation, a second pass
  ;; looks for a cycle in the reachable graph and answers the labels of a
  ;; path from the start that closes one. A violation wins over a cycle.
  ;; The optional last argument hashes worlds for the explorer's tables, in
  ;; place of equal-hash, which looks only at a structure's first few dozen
  ;; nodes: it must give equal? worlds the same number.
  (define explore
    (case-lambda
      ((start next-worlds invariant final-check)
       (explore start next-worlds invariant final-check equal-hash))
      ((start next-worlds invariant final-check hash)
       (let ((result (breadth-first start next-worlds invariant final-check hash)))
         (if (and (pair? result) (eq? (car result) 'ok))
             (or (find-cycle start next-worlds hash) result)
             result)))))

  ;; safely : (-> A) (String -> B) -> (U A B)
  ;; The thunk's value, or on a raise FAIL applied to "raised: <message>".
  (define (safely thunk fail)
    (guard (e (#t (fail (string-append "raised: " (condition-text e)))))
      (thunk)))

  ;; condition-text : Any -> String
  (define (condition-text e)
    (call-with-string-output-port
     (lambda (p)
       (cond ((message-condition? e)
              (display (condition-message e) p)
              (when (irritants-condition? e)
                (for-each (lambda (i) (display " " p) (write i p))
                          (condition-irritants e))))
             (else (write e p))))))

  ;; trace : Hashtable World -> (Listof Label)
  ;; The labels from the start to W. SEEN maps a world to #f for the start,
  ;; else (parent . label).
  (define (trace seen w)
    (let loop ((w w) (acc '()))
      (let ((link (hashtable-ref seen w #f)))
        (if link
            (loop (car link) (cons (cdr link) acc))
            acc))))

  ;; raised : String -> Raised
  ;; A next-worlds answer that is a raise: a pair whose car is the symbol
  ;; raised, which no list of (label . world) pairs has.
  (define (raised msg) (cons 'raised msg))
  (define (raised? x) (and (pair? x) (eq? (car x) 'raised)))

  ;; breadth-first : World Next Invariant Final (World -> Integer)
  ;;                 -> (U (List 'ok Natural) (List 'violated String (Listof Label)))
  ;; SEEN is also the parent table the trace is read from. The queue is a
  ;; front list and a reversed back list, so each world is handled once.
  (define (breadth-first start next-worlds invariant final-check hash)
    (call/cc
     (lambda (return)
       (let ((seen (make-hashtable hash equal?)))
         (define (violate msg w)
           (return (list 'violated msg (trace seen w))))
         (define (check-invariant w)
           (let ((bad (safely (lambda () (invariant w)) (lambda (msg) msg))))
             (when bad (violate bad w))))
         (hashtable-set! seen start #f)
         (check-invariant start)
         (let loop ((front (list start)) (back '()))
           (cond
            ((and (null? front) (null? back))
             (list 'ok (hashtable-size seen)))
            ((null? front) (loop (reverse back) '()))
            (else
             (let* ((w (car front))
                    (nexts (safely (lambda () (next-worlds w)) raised)))
               (when (raised? nexts) (violate (cdr nexts) w))
               (when (null? nexts)
                 (let ((bad (safely (lambda () (final-check w)) (lambda (msg) msg))))
                   (when bad (violate bad w))))
               (let add ((rest nexts) (back back))
                 (if (null? rest)
                     (loop (cdr front) back)
                     (let ((label (caar rest)) (w2 (cdar rest)))
                       (if (hashtable-contains? seen w2)
                           (add (cdr rest) back)
                           (begin
                             (hashtable-set! seen w2 (cons w label))
                             (check-invariant w2)
                             (add (cdr rest) (cons w2 back)))))))))))))))

  ;; find-cycle : World (World -> (Listof (Pairof Label World))) (World -> Integer)
  ;;              -> (U #f (List 'cycle (Listof Label)) (List 'violated String (Listof Label)))
  ;; Iterative depth-first search with colours: a world is grey while on the
  ;; stack and black when done. An edge to a grey world closes a cycle. A
  ;; frame is (world remaining-edges label-into-world), the stack deepest
  ;; first; its labels, shallowest first, are the path from the start.
  (define (find-cycle start next-worlds hash)
    (call/cc
     (lambda (return)
       (let ((colour (make-hashtable hash equal?)))
         ;; path : Stack Label -> (Listof Label)
         (define (path stack last)
           (let loop ((s stack) (acc (list last)))
             (cond ((null? s) acc)
                   ((caddr (car s)) (loop (cdr s) (cons (caddr (car s)) acc)))
                   (else (loop (cdr s) acc)))))
         (define (edges w stack label)
           (let ((es (safely (lambda () (next-worlds w)) raised)))
             (when (raised? es)
               (return (list 'violated (cdr es) (if label (path stack label) '()))))
             es))
         (hashtable-set! colour start 'grey)
         (let loop ((stack (list (list start (edges start '() #f) #f))))
           (if (null? stack)
               #f
               (let* ((frame (car stack)) (w (car frame)) (rest (cadr frame)))
                 (if (null? rest)
                     (begin (hashtable-set! colour w 'black)
                            (loop (cdr stack)))
                     (let* ((label (caar rest)) (w2 (cdar rest))
                            (c (hashtable-ref colour w2 #f))
                            (stack (cons (list w (cdr rest) (caddr frame))
                                         (cdr stack))))
                       (cond
                        ((eq? c 'grey) (return (list 'cycle (path stack label))))
                        ((eq? c 'black) (loop stack))
                        (else
                         (hashtable-set! colour w2 'grey)
                         (loop (cons (list w2 (edges w2 stack label) label)
                                     stack)))))))))))))
)
