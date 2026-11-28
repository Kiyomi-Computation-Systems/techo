#!r6rs
;;; The chars suite: slice 7a's shared character rules, (techo chars). All
;;; pure.
;;;
;;;   the lists        each written rule written out here as ranges, and every
;;;                    scalar value, U+0000 to U+10FFFF but the surrogates,
;;;                    checked against it: a written rule cannot move with
;;;                    Chez's tables, and a Contact's two are as slice 6
;;;                    shipped them
;;;   the tables       the two rules taken from Chez's tables, unassigned-char?
;;;                    and mark-char?, each counted over every scalar value
;;;                    and pinned: a count that changes means Chez's Unicode
;;;                    tables moved
;;;   the boundaries   each range's ends and the code points just outside,
;;;                    named, so that a failure says where
;;;   the names        no export is a name (rnrs) or (chezscheme) exports
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (only (chezscheme) library-exports)
        (techo-testing)
        (techo chars))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define (hex n) (string-append "U+" (number->string n 16)))

;; Range = (U Natural (Pair Natural Natural))     one code point, or FROM to TO

;; in-ranges? : Natural (Listof Range) -> Boolean
(define (in-ranges? n ranges)
  (exists (lambda (r) (if (pair? r) (<= (car r) n (cdr r)) (= r n))) ranges))

;; mismatches : (Char -> Boolean) (Listof Range) -> (Listof String)
;; Every scalar value where PRED disagrees with RANGES, the first ten, and
;; how many in all; () when it agrees on all 1,112,064.
(define (mismatches pred ranges)
  (let loop ((n 0) (found '()) (count 0))
    (cond ((> n #x10FFFF)
           (if (= count 0)
               '()
               (append (reverse found) (list (string-append (number->string count) " in all")))))
          ((= n #xD800) (loop #xE000 found count))
          (else
           (let ((agree? (eq? (and (pred (integer->char n)) #t) (in-ranges? n ranges))))
             (if agree?
                 (loop (+ n 1) found count)
                 (loop (+ n 1) (if (< count 10) (cons (hex n) found) found) (+ count 1))))))))

;; The last two code points of each of the 17 planes: noncharacters.
(define plane-ends
  (let loop ((p 16) (acc '()))
    (if (< p 0)
        acc
        (loop (- p 1) (cons (cons (+ (* p #x10000) #xFFFE) (+ (* p #x10000) #xFFFF)) acc)))))

;; What allowed-char? refuses, as slice 6 shipped it (P3): U+0000 to U+001F
;; (with lines?, all but U+000A), U+007F to U+009F, U+2028 and U+2029,
;; U+FDD0 to U+FDEF, and each plane's last two.
(define refused-ranges
  (append '((#x0 . #x1F) (#x7F . #x9F) (#x2028 . #x2029) (#xFDD0 . #xFDEF)) plane-ends))
(define refused-with-lines
  (append '((#x0 . #x9) (#xB . #x1F) (#x7F . #x9F) (#x2028 . #x2029) (#xFDD0 . #xFDEF))
          plane-ends))

;; blank-char?, as slice 6 shipped it: White_Space less the controls but
;; U+000A, and U+200B to U+200D, U+2060, U+FEFF.
(define blank-ranges
  '(#x20 #xA #xA0 #x1680 (#x2000 . #x200D) (#x2028 . #x2029) #x202F #x205F #x2060 #x3000
    #xFEFF))

;; space-char?, the owner's H2.
(define space-ranges
  '(#x20 #xA0 #x1680 (#x2000 . #x200A) #x202F #x205F #x3000))

;; invisible-char?, the owner's H3 and F2, F3: Unicode 17's
;; Default_Ignorable_Code_Point (4,174), then 19 format characters (U+FFF9
;; to U+FFFB, U+13430 to U+1343F) and 3 that look blank (U+2800, U+16FE4,
;; U+1D159). U+FFF0 to U+FFF8 and U+FFF9 to U+FFFB meet, so are one range here.
(define invisible-ranges
  '(#xAD #x34F #x61C (#x115F . #x1160) (#x17B4 . #x17B5) (#x180B . #x180F) (#x200B . #x200F)
    (#x202A . #x202E) (#x2060 . #x206F) #x3164 (#xFE00 . #xFE0F) #xFEFF #xFFA0
    (#xFFF0 . #xFFFB) (#x1BCA0 . #x1BCA3) (#x1D173 . #x1D17A) (#xE0000 . #xE0FFF)
    (#x13430 . #x1343F) #x2800 #x16FE4 #x1D159))

;; private-use-char?, the owner's F6: the three Private Use areas.
(define private-use-ranges
  '((#xE000 . #xF8FF) (#xF0000 . #xFFFFD) (#x100000 . #x10FFFD)))

;; dash-char?, the owner's F5: U+2010 to U+2015, and U+2212.
(define dash-ranges
  '((#x2010 . #x2015) #x2212))

(test-begin "chars")

;;; The lists, against every scalar value

(test-equal "allowed-char?, without lines: false exactly on the refused ranges, of every scalar value"
  '()
  (attempt (lambda () (mismatches (lambda (c) (not (allowed-char? c #f))) refused-ranges))))

(test-equal "allowed-char?, with lines: false exactly on the refused ranges but U+000A"
  '()
  (attempt (lambda () (mismatches (lambda (c) (not (allowed-char? c #t))) refused-with-lines))))

(test-equal "blank-char?: true exactly on its list, of every scalar value"
  '()
  (attempt (lambda () (mismatches blank-char? blank-ranges))))

(test-equal "space-char?: true exactly on its list, of every scalar value"
  '()
  (attempt (lambda () (mismatches space-char? space-ranges))))

(test-equal "invisible-char?: true exactly on its list, of every scalar value"
  '()
  (attempt (lambda () (mismatches invisible-char? invisible-ranges))))

(test-equal "private-use-char?: true exactly on its list, of every scalar value"
  '()
  (attempt (lambda () (mismatches private-use-char? private-use-ranges))))

(test-equal "dash-char?: true exactly on its list, of every scalar value"
  '()
  (attempt (lambda () (mismatches dash-char? dash-ranges))))

;; The sweeps above hold nothing if a predicate's answers were all taken
;; for the expected ones: count what each list covers.
(test-equal "the lists cover what they say: refused 32 + 33 + 2 + 32 + 34, 132 with lines, blank 25, space 17, invisible 4,174 + 19 + 3, private use 6,400 + 65,534 + 65,534, dash 7"
  '(133 132 25 17 4196 137468 7)
  (attempt
   (lambda ()
     (map (lambda (ranges)
            (fold-left (lambda (acc r) (+ acc (if (pair? r) (+ 1 (- (cdr r) (car r))) 1))) 0 ranges))
          (list refused-ranges refused-with-lines blank-ranges space-ranges invisible-ranges
                private-use-ranges dash-ranges)))))

;;; The tables: the two rules that move with Chez's tables, pinned

;; count-of : (Char -> Boolean) -> Natural     how many scalar values PRED takes
(define (count-of pred)
  (let loop ((n 0) (k 0))
    (cond ((> n #x10FFFF) k)
          ((= n #xD800) (loop #xE000 k))
          (else (loop (+ n 1) (if (pred (integer->char n)) (+ k 1) k))))))

;; If either count changes, Chez's Unicode tables moved (these are
;; Unicode 17's, Chez 10.4.1): read the records on tags again
;; (.plans/global-constraints.md, "Tags", and the decisions it names)
;; before pinning the new number. An upgrade may only assign code points:
;; the unassigned count may only fall.
(test-equal "unassigned-char?: 814,730 scalar values, Unicode 17's Cn (the 66 noncharacters among them); private use is not one"
  814730
  (attempt (lambda () (count-of unassigned-char?))))

(test-equal "mark-char?: 2,543 scalar values, Unicode 17's Mn (2,059), Mc (471) and Me (13)"
  2543
  (attempt (lambda () (count-of mark-char?))))

(test-equal "private-use-char? and invisible-char? are true of 137,468 and 4,196 scalar values"
  '(137468 4196)
  (attempt (lambda () (list (count-of private-use-char?) (count-of invisible-char?)))))

;;; The boundaries, named

;; answers : (Char -> Boolean) (Listof Natural) -> (Listof Boolean)
(define (answers pred points)
  (attempt (lambda () (map (lambda (n) (and (pred (integer->char n)) #t)) points))))

(test-equal "allowed-char?: U+0000, U+001F, U+007F, U+009F, U+2028, U+2029, U+FDD0, U+FDEF, U+FFFE, U+FFFF, U+1FFFE, U+10FFFF refused"
  '(#f #f #f #f #f #f #f #f #f #f #f #f)
  (answers (lambda (c) (allowed-char? c #f))
           '(#x0 #x1F #x7F #x9F #x2028 #x2029 #xFDD0 #xFDEF #xFFFE #xFFFF #x1FFFE #x10FFFF)))

(test-equal "allowed-char?: U+0020, U+007E, U+00A0, U+2027, U+202A, U+FDCF, U+FDF0, U+FFFD, U+10000, U+1FFFD, U+20000, U+10FFFD taken"
  '(#t #t #t #t #t #t #t #t #t #t #t #t)
  (answers (lambda (c) (allowed-char? c #f))
           '(#x20 #x7E #xA0 #x2027 #x202A #xFDCF #xFDF0 #xFFFD #x10000 #x1FFFD #x20000 #x10FFFD)))

(test-equal "allowed-char?: a line feed only with lines; a tab, a CR and U+0085 never"
  '((#f #t) (#f #f) (#f #f) (#f #f))
  (attempt (lambda ()
             (map (lambda (n) (list (allowed-char? (integer->char n) #f) (allowed-char? (integer->char n) #t)))
                  '(#xA #x9 #xD #x85)))))

(test-equal "blank-char?: each of its points"
  '(#t #t #t #t #t #t #t #t #t #t #t #t #t #t #t)
  (answers blank-char? '(#x20 #xA #xA0 #x1680 #x2000 #x200A #x200B #x200D #x2028 #x2029 #x202F
                         #x205F #x2060 #x3000 #xFEFF)))

(test-equal "blank-char?: never widened: a tab, U+0085, U+180E, U+200E, U+2061, U+00AD and U+FE0F are no blank"
  '(#f #f #f #f #f #f #f)
  (answers blank-char? '(#x9 #x85 #x180E #x200E #x2061 #xAD #xFE0F)))

(test-equal "space-char?: each of its points"
  '(#t #t #t #t #t #t #t #t)
  (answers space-char? '(#x20 #xA0 #x1680 #x2000 #x200A #x202F #x205F #x3000)))

(test-equal "space-char?: no tab, line break or zero-width: U+0009, U+000A, U+000D, U+0085, U+200B, U+2028, U+2029, U+FEFF, U+1FFF, U+167F, U+1681"
  '(#f #f #f #f #f #f #f #f #f #f #f)
  (answers space-char? '(#x9 #xA #xD #x85 #x200B #x2028 #x2029 #xFEFF #x1FFF #x167F #x1681)))

;; Each range of each written list, its two ends, then the scalar values
;; just outside it: before U+E000, that is U+D7FF, past the surrogates.
(for-each
 (lambda (named)
   (for-each
    (lambda (r)
      (let* ((from (if (pair? r) (car r) r)) (to (if (pair? r) (cdr r) r))
             (before (if (= from #xE000) #xD7FF (- from 1))))
        (test-equal (string-append (car named) ": " (hex from) " and " (hex to) " are, "
                                   (hex before) " and " (hex (+ to 1)) " are not")
          '(#t #t #f #f)
          (answers (cadr named) (list from to before (+ to 1))))))
    (caddr named)))
 (list (list "invisible-char?" invisible-char? invisible-ranges)
       (list "private-use-char?" private-use-char? private-use-ranges)
       (list "dash-char?" dash-char? dash-ranges)))

(test-equal "dash-char?: no other dash: U+002D, U+00AD, U+2043, U+2E3A, U+2E3B, U+301C, U+30FC, U+FE58, U+FE63, U+FF0D are none"
  '(#f #f #f #f #f #f #f #f #f #f)
  (answers dash-char? '(#x2D #xAD #x2043 #x2E3A #x2E3B #x301C #x30FC #xFE58 #xFE63 #xFF0D)))

;; The table's rules, at the edges of a few of Unicode's blocks.
(test-equal "unassigned-char?: U+0378, U+0379, U+20C2, U+FFEF, U+16FE5, U+1BCA4, U+50000, U+E1000 and the noncharacters U+FDD0, U+FFFE, U+10FFFF are"
  '(#t #t #t #t #t #t #t #t #t #t #t)
  (answers unassigned-char? '(#x378 #x379 #x20C2 #xFFEF #x16FE5 #x1BCA4 #x50000 #xE1000 #xFDD0 #xFFFE #x10FFFF)))

(test-equal "unassigned-char?: U+0377, U+037A, U+20C1 and U+A7CE (Unicode 17), U+323B0, U+30000, a control, U+E000, U+10FFFD, U+E0001 are not"
  '(#f #f #f #f #f #f #f #f #f #f)
  (answers unassigned-char? '(#x377 #x37A #x20C1 #xA7CE #x323B0 #x30000 #x0 #xE000 #x10FFFD #xE0001)))

(test-equal "mark-char?: U+0300, U+036F, U+0345, U+0903 (Mc), U+20DD (Me), U+3099, U+16FE4, U+13440 are"
  '(#t #t #t #t #t #t #t #t)
  (answers mark-char? '(#x300 #x36F #x345 #x903 #x20DD #x3099 #x16FE4 #x13440)))

(test-equal "mark-char?: U+02FF, U+0370, U+00B4, U+00A8, U+309B (spacing accents), U+0378 (unassigned), a, U+002D are not"
  '(#f #f #f #f #f #f #f #f)
  (answers mark-char? '(#x2FF #x370 #xB4 #xA8 #x309B #x378 #x61 #x2D)))

;;; The names (traps.md: a name (rnrs) exports cannot be defined)

(test-equal "names: no export is a name (rnrs) or (chezscheme) exports"
  '()
  (attempt (lambda ()
             (let ((taken (append (library-exports '(rnrs)) (library-exports '(chezscheme)))))
               (filter (lambda (name) (memq name taken)) (library-exports '(techo chars)))))))

(test-equal "names: the eight rules, and nothing else"
  '(allowed-char? blank-char? dash-char? invisible-char? mark-char? private-use-char? space-char?
    unassigned-char?)
  (attempt (lambda ()
             (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
                        (library-exports '(techo chars))))))

(test-end "chars")

(exit (suite-exit-status runner))
