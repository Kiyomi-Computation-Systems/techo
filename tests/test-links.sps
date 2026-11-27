#!r6rs
;;; The links suite: slice 5b's pure core, (techo links). All pure.
;;;
;;;   the types         K1's three, and a path's type, exactly
;;;   the query         ?type= and ?direction=, as query-one hands them over
;;;   the cursor        a page's next, <type>:<id>: read, written, and its cap
;;;   link-command      every combination of the source's state, the target's,
;;;                     the event and whether the link is there, against a
;;;                     table written out here; and what it raises (Q6, Q19)
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (only (chezscheme) real-time bytes-allocated bytes-deallocated)
        (techo-testing)
        (techo links))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; raised-kind : (-> Any) -> (U 'no-raise 'assertion 'other)
(define (raised-kind thunk)
  (guard (e ((assertion-violation? e) 'assertion)
            (#t 'other))
    (thunk)
    'no-raise))

;; raised-as : (-> Any) -> (U (List Symbol String (Listof Any)) 'no-raise (List 'other String))
;; An assertion violation as its who, its message and its irritants;
;; 'no-raise when nothing was raised; any other raise, or one with no who or
;; message, as (other text).
(define (raised-as thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e) (message-condition? e))
             (list (condition-who e) (condition-message e)
                   (if (irritants-condition? e) (condition-irritants e) '())))
            (#t (list 'other (describe e))))
    (thunk)
    'no-raise))

(define (written x) (call-with-string-output-port (lambda (p) (write x p))))

;; allocated : -> Natural     every byte allocated so far, collected or not
(define (allocated) (+ (bytes-allocated) (bytes-deallocated)))

(define v7-text "0190b3a4-5c6d-7e8f-9a0b-1c2d3e4f5a6b")
(define v7-bytes
  (u8-list->bytevector '(#x01 #x90 #xb3 #xa4 #x5c #x6d #x7e #x8f
                         #x9a #x0b #x1c #x2d #x3e #x4f #x5a #x6b)))
(define other-v7-text "018f0000-0000-7000-bfff-ffffffffffff")
(define other-v7-bytes
  (u8-list->bytevector '(#x01 #x8f #x00 #x00 #x00 #x00 #x70 #x00
                         #xbf #xff #xff #xff #xff #xff #xff #xff)))
(define v4-text "0190b3a4-5c6d-4e8f-9a0b-1c2d3e4f5a6b")

;; The three types, written out here, not read from link-types.
(define types '("related" "mentions" "blocks"))

(test-begin "links")

;;; The types (K1)

(test-equal "link-types: the three, as K1 names them"
  '("related" "mentions" "blocks")
  (attempt (lambda () link-types)))

;; A type may be added but never removed: its stored links could then not be
;; named in a path or a cursor, and a list page ending on one would be a 500.
;; The shipped types are written out here; the test above holds exactly these.
(test-equal "link-types: each type once shipped is still there (related, mentions, blocks)"
  '(#t #t #t)
  (attempt (lambda () (map (lambda (t) (and (member t link-types) #t)) '("related" "mentions" "blocks")))))

(test-equal "link-types: sorted by name, as a page sorts them: blocks, mentions, related"
  '("blocks" "mentions" "related")
  (attempt (lambda () (list-sort string<? link-types))))

(test-equal "type: each of the three is itself"
  '("related" "mentions" "blocks")
  (attempt (lambda () (map parse-link-type types))))

(for-each
 (lambda (c)
   (test-equal (string-append "type: refused, " (car c))
     'invalid
     (attempt (lambda () (parse-link-type (cdr c))))))
 (list (cons "empty" "")
       (cons "another case, Related" "Related")
       (cons "another case, MENTIONS" "MENTIONS")
       (cons "another case, bLocks" "bLocks")
       (cons "a space before" " related")
       (cons "a space after" "related ")
       (cons "a type not in the list, folder" "folder")
       (cons "a type not in the list, relates" "relates")
       (cons "a prefix of one, relate" "relate")
       (cons "two types" "related,blocks")
       (cons "a type and a colon" "related:")
       (cons "a symbol" 'related)
       (cons "the query's answer for twice, 'invalid" 'invalid)
       (cons "#f" #f)
       (cons "a number" 7)
       (cons "a list of a type" '("related"))))

;;; The list's query: ?type= and ?direction=

(test-equal "?type=: not given is #f, every type; each of the three is itself"
  '(#f "related" "mentions" "blocks")
  (attempt (lambda () (map parse-type-param (cons #f types)))))

(for-each
 (lambda (c)
   (test-equal (string-append "?type=: refused, " (car c))
     'invalid
     (attempt (lambda () (parse-type-param (cdr c))))))
 (list (cons "given twice, 'invalid from query-one" 'invalid)
       (cons "empty" "")
       (cons "another case, Related" "Related")
       (cons "another case, BLOCKS" "BLOCKS")
       (cons "a type not in the list, folder" "folder")
       (cons "a space after" "mentions ")
       (cons "two types" "related,blocks")
       (cons "a symbol" 'blocks)
       (cons "a number" 1)
       (cons "#t" #t)))

(test-equal "?direction=: not given is out; out and in are themselves"
  '(out out in)
  (attempt (lambda () (map parse-direction '(#f "out" "in")))))

(for-each
 (lambda (c)
   (test-equal (string-append "?direction=: refused, " (car c))
     'invalid
     (attempt (lambda () (parse-direction (cdr c))))))
 (list (cons "given twice, 'invalid from query-one" 'invalid)
       (cons "empty" "")
       (cons "another case, OUT" "OUT")
       (cons "another case, Out" "Out")
       (cons "another case, In" "In")
       (cons "a space before" " out")
       (cons "a space after" "in ")
       (cons "outgoing" "outgoing")
       (cons "both" "both")
       (cons "out,in" "out,in")
       (cons "a symbol, out" 'out)
       (cons "a symbol, in" 'in)
       (cons "a number" 1)
       (cons "#t" #t)))

;;; The cursor: a page's next, <type>:<id>

(define (cursor-of type text) (string-append type ":" text))

(test-equal "cursor: each type with a v7 id is the type and the id's 16 bytes"
  (map (lambda (t) (cons t v7-bytes)) types)
  (attempt (lambda () (map (lambda (t) (parse-link-cursor (cursor-of t v7-text))) types))))

(test-equal "cursor: the id in upper case, as parse-node-id takes it"
  (cons "blocks" v7-bytes)
  (attempt (lambda () (parse-link-cursor (cursor-of "blocks" (string-upcase v7-text))))))

(test-equal "cursor: the longest, mentions and an id, is 45 characters, and is read"
  (list 45 (cons "mentions" v7-bytes))
  (attempt (lambda ()
             (let ((c (cursor-of "mentions" v7-text)))
               (list (string-length c) (parse-link-cursor c))))))

(for-each
 (lambda (c)
   (test-equal (string-append "cursor: refused, " (car c))
     'invalid
     (attempt (lambda () (parse-link-cursor (cdr c))))))
 (list (cons "given twice, 'invalid from query-one" 'invalid)
       (cons "empty" "")
       (cons "a colon alone" ":")
       (cons "no colon, the id alone" v7-text)
       (cons "no colon, a type alone" "related")
       (cons "no colon, the type and the id run together" (string-append "related" v7-text))
       (cons "another case, Related" (cursor-of "Related" v7-text))
       (cons "another case, BLOCKS" (cursor-of "BLOCKS" v7-text))
       (cons "a type not in the list, folder" (cursor-of "folder" v7-text))
       (cons "an empty type" (cursor-of "" v7-text))
       (cons "a space before the type" (cursor-of " related" v7-text))
       (cons "an empty id" "related:")
       (cons "a v4 id" (cursor-of "related" v4-text))
       (cons "text after the id" (string-append (cursor-of "related" v7-text) "x"))
       (cons "a colon after the id" (string-append (cursor-of "related" v7-text) ":"))
       (cons "a second colon before the id" (cursor-of "related" (string-append ":" v7-text)))
       (cons "a space before the id" (cursor-of "related" (string-append " " v7-text)))
       (cons "the id in braces" (cursor-of "blocks" (string-append "{" v7-text "}")))
       (cons "the id without hyphens" (cursor-of "related" "0190b3a45c6d7e8f9a0b1c2d3e4f5a6b"))
       (cons "the id before the type" (string-append v7-text ":related"))
       (cons "a symbol" 'related)
       (cons "#f" #f)
       (cons "a number" 7)
       (cons "the pair it answers" (cons "related" v7-bytes))
       (cons "the id's 16 bytes" v7-bytes)))

(test-equal "cursor: 46 characters are refused, the longest and one more, at either end"
  '((46 invalid) (46 invalid))
  (attempt (lambda ()
             (map (lambda (c) (list (string-length c) (parse-link-cursor c)))
                  (list (string-append (cursor-of "mentions" v7-text) "a")
                        (string-append "a" (cursor-of "mentions" v7-text)))))))

;; Past the cap no answer differs: no string over 45 characters is a type,
;; a colon and an id. What the cap holds is the work, so these measure it.
(test-equal "cursor: 1,000,000 characters after a type and a colon are refused at once, and not copied"
  '(invalid quick not-copied)
  (attempt (lambda ()
             (let* ((x (cursor-of "related" (make-string 999992 #\a)))
                    (a0 (allocated))
                    (t0 (real-time))
                    (r (parse-link-cursor x))
                    (t1 (real-time))
                    (a1 (allocated)))
               (list r
                     (if (< (- t1 t0) 100) 'quick (- t1 t0))
                     (if (< (- a1 a0) 65536) 'not-copied (- a1 a0)))))))

(test-equal "cursor: 1,000,000 characters with no colon are refused at once"
  '(invalid quick)
  (attempt (lambda ()
             (let* ((x (make-string 1000000 #\a))
                    (t0 (real-time))
                    (r (parse-link-cursor x))
                    (t1 (real-time)))
               (list r (if (< (- t1 t0) 100) 'quick (- t1 t0)))))))

(test-equal "link-cursor: the type, a colon, and the id as node-id->string writes it, lower case"
  (list (cursor-of "related" v7-text) (cursor-of "mentions" v7-text) (cursor-of "blocks" v7-text))
  (attempt (lambda () (map (lambda (t) (link-cursor t v7-bytes)) types))))

(test-equal "link-cursor and parse-link-cursor: parse-link-cursor reads back every cursor written, every type"
  (apply append (map (lambda (t) (list (cons t v7-bytes) (cons t other-v7-bytes))) types))
  (attempt (lambda ()
             (apply append
                    (map (lambda (t)
                           (map (lambda (id) (parse-link-cursor (link-cursor t id)))
                                (list v7-bytes other-v7-bytes)))
                         types)))))

(test-equal "link-cursor and parse-link-cursor: link-cursor writes back every cursor read, lower case"
  (apply append (map (lambda (t) (list (cursor-of t v7-text) (cursor-of t other-v7-text)
                                       (cursor-of t v7-text)))
                     types))
  (attempt (lambda ()
             (apply append
                    (map (lambda (t)
                           (map (lambda (text)
                                  (let ((p (parse-link-cursor (cursor-of t text))))
                                    (link-cursor (car p) (cdr p))))
                                (list v7-text other-v7-text (string-upcase v7-text))))
                         types)))))

(test-equal "link-cursor: a type not in the list raises, with nothing of it"
  '((link-cursor "not a link's type" ()) (link-cursor "not a link's type" ())
    (link-cursor "not a link's type" ()) (link-cursor "not a link's type" ())
    (link-cursor "not a link's type" ()))
  (map (lambda (t) (raised-as (lambda () (link-cursor t v7-bytes))))
       (list "folder" "Related" "" 'related #f)))

(test-equal "link-cursor: an id that is no 16 bytes raises"
  '(assertion assertion assertion)
  (map (lambda (id) (raised-kind (lambda () (link-cursor "related" id))))
       (list (make-bytevector 15 0) v7-text #f)))

;;; link-command (the review's blocker 3 and its pinned table)

(define end-states '(#f active archived trashed))

;; What link-command answers, written out by hand from the review's table,
;; not computed: under each event and each answer to "is the link there?",
;; a row per source state in end-states' order, an entry per target state
;; in the same order. #f is no node: missing, purged or another account's.
;;   1 no source                                     refuse-404
;;   2 link, and no target                           refuse-404
;;   3 the link is there                             keep for link, unlink for unlink
;;   4 unlink, and it is not there                   refuse-404
;;   5 link refused at the source or at the target   refuse-wrong-state
;;   6 otherwise                                     link
(define link-command-table
  '((link
     (#f                                ; the link is not there
      (#f       refuse-404 refuse-404         refuse-404         refuse-404)
      (active   refuse-404 link               link               refuse-wrong-state)
      (archived refuse-404 link               link               refuse-wrong-state)
      (trashed  refuse-404 refuse-wrong-state refuse-wrong-state refuse-wrong-state))
     (#t                                ; the link is there
      (#f       refuse-404 refuse-404         refuse-404         refuse-404)
      (active   refuse-404 keep               keep               keep)
      (archived refuse-404 keep               keep               keep)
      (trashed  refuse-404 keep               keep               keep)))
    (unlink
     (#f
      (#f       refuse-404 refuse-404         refuse-404         refuse-404)
      (active   refuse-404 refuse-404         refuse-404         refuse-404)
      (archived refuse-404 refuse-404         refuse-404         refuse-404)
      (trashed  refuse-404 refuse-404         refuse-404         refuse-404))
     (#t
      (#f       refuse-404 refuse-404         refuse-404         refuse-404)
      (active   unlink     unlink             unlink             unlink)
      (archived unlink     unlink             unlink             unlink)
      (trashed  unlink     unlink             unlink             unlink)))))

;; expected-link : Symbol Boolean (U Symbol #f) (U Symbol #f) -> Symbol
;; The table's entry for the cell; a cell the table lacks expects what
;; link-command never answers.
(define (expected-link event there source target)
  (let* ((by-there (cond ((assq event link-command-table) => cdr) (else '())))
         (rows (cond ((assq there by-there) => cdr) (else '())))
         (row (assq source rows))
         (tail (memq target end-states)))
    (if (and row tail (= (length (cdr row)) (length end-states)))
        (list-ref (cdr row) (- (length end-states) (length tail)))
        'missing-from-the-suites-table)))

(define (for-each-cell f)
  (for-each
   (lambda (e)
     (for-each
      (lambda (there)
        (for-each
         (lambda (s)
           (for-each (lambda (t) (f e there s t)) end-states))
         end-states))
      '(#f #t)))
   '(link unlink)))

;; Every one of the 64 cells, by construction: 4 sources, 4 targets, 2
;; events, the link there or not.
(for-each-cell
 (lambda (e there s t)
   (test-equal (string-append "command: source " (written s) ", target " (written t) ", "
                              (written e) ", there " (written there))
     (expected-link e there s t)
     (attempt (lambda () (link-command s t e there))))))

(test-equal "command: the grid above expects each of the five commands"
  '(#t #t #t #t #t)
  (let ((seen '()))
    (for-each-cell (lambda (e there s t) (set! seen (cons (expected-link e there s t) seen))))
    (map (lambda (c) (and (memq c seen) #t)) '(link keep unlink refuse-404 refuse-wrong-state))))

(test-equal "command: an event not link or unlink raises, with nothing of the request"
  (map (lambda (e) '(link-command "not a link's event" ()))
       '(archive write move keep refuse-404 "link" #f Link))
  (map (lambda (e) (raised-as (lambda () (link-command 'active 'active e #f))))
       '(archive write move keep refuse-404 "link" #f Link)))

(test-equal "command: a source's state that is no live state or #f raises, for either event"
  (map (lambda (x) '(link-command "the source's state is active, archived, trashed or #f" ()))
       '(1 2 3 4 5 6))
  (map (lambda (args) (raised-as (lambda () (apply link-command args))))
       (list (list 'purged 'active 'link #f) (list 'purged #f 'unlink #t)
             (list "active" 'active 'link #f) (list 'gone 'active 'unlink #f)
             (list 0 'active 'link #t) (list #t 'active 'unlink #t))))

(test-equal "command: a link's target's state that is no live state or #f raises, wherever the source is"
  (map (lambda (x) '(link-command "a link's target's state is active, archived, trashed or #f" ()))
       '(1 2 3 4 5))
  (map (lambda (args) (raised-as (lambda () (apply link-command args))))
       (list (list 'active 'purged 'link #f) (list 'trashed "trashed" 'link #t)
             (list #f 'purged 'link #f) (list 'archived 'gone 'link #f)
             (list 'active 0 'link #t))))

(test-equal "command: whether the link is there must be a boolean: 0 and () are not #f"
  (map (lambda (x) '(link-command "whether the link is there is a boolean" ()))
       '(1 2 3 4 5))
  (map (lambda (args) (raised-as (lambda () (apply link-command args))))
       (list (list 'active 'active 'link 0) (list 'active 'active 'unlink '())
             (list #f #f 'link 1) (list 'trashed 'active 'unlink 'yes)
             (list #f 'active 'unlink "there"))))

;; An unlink reads no target: the handler passes #f, and nothing else of
;; it is asked. Any value answers as #f would.
(test-equal "command: an unlink does not look at the target: any value is ignored"
  '(unlink unlink unlink unlink refuse-404 refuse-404 refuse-404)
  (map (lambda (args) (attempt (lambda () (apply link-command args))))
       (list (list 'active 'purged 'unlink #t) (list 'trashed "active" 'unlink #t)
             (list 'archived 'gone 'unlink #t) (list 'active 0 'unlink #t)
             (list 'active 'purged 'unlink #f) (list #f 'purged 'unlink #t)
             (list 'trashed 0 'unlink #f))))

(test-end "links")

(exit (suite-exit-status runner))
