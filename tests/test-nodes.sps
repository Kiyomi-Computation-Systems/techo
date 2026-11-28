#!r6rs
;;; The nodes suite: slice 4's pure core, (techo nodes). All pure.
;;;
;;;   the constants     the five kinds and the caps (D6, D7; slice 5a's three)
;;;   ids               a node's id is a UUID of version 7, RFC variant (D2, H10)
;;;   revisions         a path's revision, and the ETag (D4)
;;;   preconditions     If-Match and If-None-Match, exactly as D4 takes them (H9)
;;;   content           the body's members, types and limits (D6, D7, H8), a create's parent;
;;;                     props and tags handed on as read (slices 6 and 7a)
;;;   the linear rule   a request at the cap, whatever its members, is quick (H13)
;;;   a move's body     and the list's ?parent= (slice 5a)
;;;   the table         D5's table, checked exhaustively, every cell stepped (H7)
;;;   the lifecycle     slice 4b's table with 5a's two events, 5b's two and 7a's
;;;                     retag, every cell stepped (G1)
;;;   the tree          what may hold what, the verdict on a new parent, which
;;;                     children a bulk move takes, every combination (T2, T5, T8, P18)
;;;   node-command      the two tables, the verdict and the children answer one
;;;                     request, every cell; link, unlink and retag are not its
;;;                     (G5, G15, P6, P17, Q19; slice 7a's review, blocker 10)
;;;   states and events the store's names, ?state=, the three lists of events,
;;;                     retag-states and the feed's ops
;;;   the diagrams      .plans/machines/write.md and lifecycle.md are what the tables render
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (only (chezscheme) real-time)
        (techo-testing)
        (techo machine)
        (techo nodes))

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

(define (read-file path)
  (attempt (lambda () (call-with-input-file path get-string-all))))

(define (string-index-of hay needle)
  (let ((n (string-length needle)) (h (string-length hay)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) i)
            (else (loop (+ i 1)))))))

(define (written x) (call-with-string-output-port (lambda (p) (write x p))))

(test-begin "nodes")

;;; The constants

(test-equal "kinds: the five, lower case, in D7's order"
  '("project" "journal" "note" "task" "contact")
  (attempt (lambda () node-kinds)))

(test-equal "caps: body 1 MiB, request 2 MiB, title 1000"
  '(1048576 2097152 1000)
  (attempt (lambda () (list body-cap request-cap title-cap))))

(test-equal "caps: a parent's depth 64, a bulk move's children 1000, a move's body 16 KiB"
  '(64 1000 16384)
  (attempt (lambda () (list depth-cap move-children-cap move-body-cap))))

;;; Ids (D2, H10)

(define v7-text "0190b3a4-5c6d-7e8f-9a0b-1c2d3e4f5a6b")
(define v7-bytes
  (u8-list->bytevector '(#x01 #x90 #xb3 #xa4 #x5c #x6d #x7e #x8f
                         #x9a #x0b #x1c #x2d #x3e #x4f #x5a #x6b)))

(test-equal "id: a v7 id in lower case" v7-bytes (attempt (lambda () (parse-node-id v7-text))))
(test-equal "id: the same id in upper case" v7-bytes
  (attempt (lambda () (parse-node-id (string-upcase v7-text)))))
(test-equal "id: the RFC variant's two ends, 8 and b, are both v7"
  '(#t #t)
  (attempt (lambda ()
             (map (lambda (s) (bytevector? (parse-node-id s)))
                  '("0190b3a4-5c6d-7e8f-8a0b-1c2d3e4f5a6b"
                    "0190b3a4-5c6d-7e8f-ba0b-1c2d3e4f5a6b")))))

(for-each
 (lambda (c)
   (test-equal (string-append "id: refused, " (car c))
     'invalid
     (attempt (lambda () (parse-node-id (cdr c))))))
 (list (cons "a v4 id" "0190b3a4-5c6d-4e8f-9a0b-1c2d3e4f5a6b")
       (cons "a v6 id" "0190b3a4-5c6d-6e8f-9a0b-1c2d3e4f5a6b")
       (cons "a v8 id" "0190b3a4-5c6d-8e8f-9a0b-1c2d3e4f5a6b")
       (cons "the nil id" "00000000-0000-0000-0000-000000000000")
       (cons "the max id" "ffffffff-ffff-ffff-ffff-ffffffffffff")
       (cons "v7-looking, NCS variant" "0190b3a4-5c6d-7e8f-1a0b-1c2d3e4f5a6b")
       (cons "v7-looking, Microsoft variant" "0190b3a4-5c6d-7e8f-ca0b-1c2d3e4f5a6b")
       (cons "v7-looking, future variant" "0190b3a4-5c6d-7e8f-ea0b-1c2d3e4f5a6b")
       (cons "35 characters" (substring v7-text 0 35))
       (cons "37 characters" (string-append v7-text "b"))
       (cons "no hyphens" "0190b3a45c6d7e8f9a0b1c2d3e4f5a6b")
       (cons "braces" (string-append "{" v7-text "}"))
       (cons "empty" "")
       (cons "a number" 7)
       (cons "#f" #f)
       (cons "its 16 bytes" v7-bytes)
       (cons "a symbol" 'id)))

(test-equal "id->string: lower case, 36 characters"
  v7-text
  (attempt (lambda () (node-id->string v7-bytes))))
(test-equal "id->string: an upper-case id comes back lower case"
  v7-text
  (attempt (lambda () (node-id->string (parse-node-id (string-upcase v7-text))))))

;;; Revisions and the ETag (D4)

(define two-53 9007199254740992)

(test-equal "revision: 1, 7, 10 and 2^53"
  (list 1 7 10 two-53)
  (attempt (lambda () (map parse-revision '("1" "7" "10" "9007199254740992")))))

(for-each
 (lambda (x)
   (test-equal (string-append "revision: refused, " (written x))
     'invalid
     (attempt (lambda () (parse-revision x)))))
 (list "9007199254740993" "10000000000000000" "0" "00" "01" "+1" "-1" "1.0" "1e3" ""
       " 1" "1 " "#x10" "\x663;" "1/2" "seven" 7 #f '()))

(test-equal "revision: 1,000,000 nines are refused at once, before they are read"
  '(invalid quick)
  (attempt (lambda ()
             (let* ((x (make-string 1000000 #\9))
                    (t0 (real-time))
                    (r (parse-revision x))
                    (t1 (real-time)))
               (list r (if (< (- t1 t0) 100) 'quick (- t1 t0)))))))

(test-equal "etag: 7 is the strong tag \"7\", three characters"
  '("\"7\"" 3)
  (attempt (lambda () (list (etag 7) (string-length (etag 7))))))

(test-equal "etag: 2^53"
  "\"9007199254740992\""
  (attempt (lambda () (etag two-53))))

(test-equal "etag: -1, 1.5 and \"7\" raise"
  '(assertion assertion assertion)
  (map (lambda (x) (raised-kind (lambda () (etag x)))) (list -1 1.5 "7")))

(test-equal "etag: precondition reads back every tag etag writes"
  (list 1 9 10 99 12345 two-53)
  (attempt (lambda ()
             (map (lambda (n) (precondition (list (etag n)) '()))
                  (list 1 9 10 99 12345 two-53)))))

;;; Preconditions (D4, H9)

(define (pre im inm) (attempt (lambda () (precondition im inm))))

(test-equal "precondition: neither header is missing" 'missing (pre '() '()))
(test-equal "precondition: If-None-Match: * is a create" 'create (pre '() '("*")))
(test-equal "precondition: If-None-Match: * with spaces and tabs around it"
  'create (pre '() '(" \t* \t")))
(test-equal "precondition: If-Match: \"7\" is 7" 7 (pre '("\"7\"") '()))
(test-equal "precondition: If-Match with spaces and tabs around the tag"
  7 (pre '("\t \"7\" \t") '()))
(test-equal "precondition: If-Match: \"2^53\"" two-53 (pre '("\"9007199254740992\"") '()))

(for-each
 (lambda (c)
   (test-equal (string-append "precondition: invalid, " (car c))
     'invalid
     (pre (cadr c) (caddr c))))
 (list
  (list "both headers" '("\"7\"") '("*"))
  (list "both, If-None-Match empty" '("\"7\"") '(""))
  (list "If-Match given twice, the same" '("\"7\"" "\"7\"") '())
  (list "If-Match given twice, different" '("\"7\"" "\"8\"") '())
  (list "If-Match given twice, the first empty" '("" "\"7\"") '())
  (list "If-Match given twice, the second empty" '("\"7\"" "") '())
  (list "If-Match split across two fields" '("\"7" "\"") '())
  (list "If-None-Match given twice" '() '("*" "*"))
  (list "* in If-Match" '("*") '())
  (list "a list in If-Match" '("\"7\", \"8\"") '())
  (list "a list of one and a comma" '("\"7\",") '())
  (list "a weak tag" '("W/\"7\"") '())
  (list "a weak tag, lower case" '("w/\"7\"") '())
  (list "a space inside the quotes, before" '("\" 7\"") '())
  (list "a space inside the quotes, after" '("\"7 \"") '())
  (list "no quotes" '("7") '())
  (list "only an opening quote" '("\"7") '())
  (list "only a closing quote" '("7\"") '())
  (list "empty quotes" '("\"\"") '())
  (list "an empty If-Match" '("") '())
  (list "only spaces" '("  ") '())
  (list "a tag and more" '("\"7\"x") '())
  (list "three quotes" '("\"7\"\"") '())
  (list "revision 0" '("\"0\"") '())
  (list "a leading zero" '("\"07\"") '())
  (list "2^53 + 1" '("\"9007199254740993\"") '())
  (list "a sign" '("\"+7\"") '())
  (list "an ETag in If-None-Match" '() '("\"7\""))
  (list "a weak tag in If-None-Match" '() '("W/\"7\""))
  (list "* in a list in If-None-Match" '() '("*, \"7\""))
  (list "an empty If-None-Match" '() '(""))
  (list "** in If-None-Match" '() '("**"))
  (list "a newline around *" '() '("*\n"))))

(test-equal "precondition: what is no list of strings is invalid, and does not raise"
  '(invalid invalid invalid invalid)
  (map (lambda (args) (pre (car args) (cadr args)))
       (list (list "\"7\"" '()) (list '() "*") (list '(7) '()) (list '() '(*)))))

;;; Content (D6, D7, H8)

(define good
  '(("kind" . "note") ("title" . "A title") ("body" . "Some text")
    ("content_type" . "text/plain")))

;; without : String Alist -> Alist      every member but NAME
(define (without name x) (filter (lambda (m) (not (string=? (car m) name))) x))
;; with : String Any Alist -> Alist     NAME's member replaced, or added, at the end
(define (with name value x) (append (without name x) (list (cons name value))))

;; summary : Any -> Any      a Content opened up, anything else as it is
(define (summary r)
  (if (content? r)
      (list (content-kind r) (content-title r) (content-body r)
            (content-content-type r) (content-props r))
      r))

;; verdict : Any -> Any     'content for a Content, anything else as it is
(define (verdict r) (if (content? r) 'content r))

(define (parsed x create?) (attempt (lambda () (summary (parse-content x create?)))))
(define (judged x create?) (attempt (lambda () (verdict (parse-content x create?)))))

(test-equal "content: a create; props not given are absent"
  '("note" "A title" "Some text" "text/plain" absent)
  (parsed good #t))

(test-equal "content: the members in another order"
  '("note" "A title" "Some text" "text/plain" absent)
  (parsed (reverse good) #t))

(test-equal "content: props given as {} are handed on as (), not as absent"
  '("note" "A title" "Some text" "text/plain" ())
  (parsed (with "props" '() good) #t))

(test-equal "content: a replace with no kind"
  '(#f "A title" "Some text" "text/plain" absent)
  (parsed (without "kind" good) #f))

(test-equal "content: a replace that names a kind keeps it"
  '("task" "A title" "Some text" "text/plain" absent)
  (parsed (with "kind" "task" good) #f))

;; Slice 6: parse-content takes props absent or any object, and hands them
;; on as read; (techo props)' request-props judges them, for the kind.
(test-equal "content: props are handed on as read, their members not judged, on a create and a replace"
  '(("note" "A title" "Some text" "text/plain" (("a" . 1)))
    (#f "A title" "Some text" "text/plain" (("status" . "DONE") ("status" . 5)))
    ("project" "A title" "Some text" "text/plain" (("x" ("y" . #(1 null))) ("" . #f))))
  (list (parsed (with "props" '(("a" . 1)) good) #t)
        (parsed (with "props" '(("status" . "DONE") ("status" . 5)) (without "kind" good)) #f)
        (parsed (with "props" '(("x" ("y" . #(1 null))) ("" . #f)) (with "kind" "project" good))
                #t)))

(test-equal "content: each of the five kinds"
  '("project" "journal" "note" "task" "contact")
  (attempt (lambda ()
             (map (lambda (k) (content-kind (parse-content (with "kind" k good) #t)))
                  '("project" "journal" "note" "task" "contact")))))

(test-equal "content: an empty title and an empty body"
  '("note" "" "" "text/plain" absent)
  (parsed (with "body" "" (with "title" "" good)) #t))

(test-equal "content: a body may hold any character but U+0000"
  (list "note" "A title" (string (integer->char 1) #\tab #\newline (integer->char #x1F600))
        "text/plain" 'absent)
  (parsed (with "body" (string (integer->char 1) #\tab #\newline (integer->char #x1F600)) good)
          #t))

(for-each
 (lambda (c)
   (test-equal (string-append "content: invalid, " (car c))
     'invalid
     (judged (cadr c) (caddr c))))
 (list
  ;; not an object
  (list "an array" (vector good) #t)
  (list "an empty array" (vector) #t)
  (list "a string" "note" #t)
  (list "a number" 7 #t)
  (list "null" 'null #t)
  (list "true" #t #t)
  (list "false" #f #t)
  (list "an empty object" '() #t)
  (list "an empty object, a replace" '() #f)
  (list "an improper list" (cons '("title" . "a") 5) #t)
  (list "a list of numbers" '(1 2 3) #t)
  (list "a member named by a symbol" (cons '(kind . "note") (without "kind" good)) #t)
  ;; the members
  (list "a create with no kind" (without "kind" good) #t)
  (list "no title" (without "title" good) #t)
  (list "no title, a replace" (without "title" (without "kind" good)) #f)
  (list "no body" (without "body" good) #t)
  (list "no body, a replace" (without "body" (without "kind" good)) #f)
  (list "no content_type" (without "content_type" good) #t)
  (list "no content_type, a replace" (without "content_type" (without "kind" good)) #f)
  (list "an unknown member, id" (with "id" "0190b3a4-5c6d-7e8f-9a0b-1c2d3e4f5a6b" good) #t)
  (list "an unknown member, revision" (with "revision" 3 good) #f)
  (list "a member in another case, Title" (cons '("Title" . "x") (without "title" good)) #t)
  (list "a member with an empty name" (with "" "x" good) #t)
  (list "title twice, the same" (append good '(("title" . "A title"))) #t)
  (list "kind twice" (append good '(("kind" . "note"))) #t)
  (list "kind twice, a replace" (append good '(("kind" . "note"))) #f)
  (list "props twice" (append good '(("props") ("props"))) #t)
  ;; kind
  (list "kind not one of the five" (with "kind" "folder" good) #t)
  (list "kind in capitals" (with "kind" "Note" good) #t)
  (list "kind with a space" (with "kind" "note " good) #t)
  (list "kind a number" (with "kind" 3 good) #t)
  (list "kind null, a replace" (with "kind" 'null good) #f)
  (list "kind an object" (with "kind" '(("x" . 1)) good) #t)
  (list "kind not one of the five, a replace" (with "kind" "folder" good) #f)
  ;; the types
  (list "title a number" (with "title" 5 good) #t)
  (list "title null" (with "title" 'null good) #t)
  (list "title true" (with "title" #t good) #t)
  (list "title an array" (with "title" (vector "a") good) #t)
  (list "title an object" (with "title" '() good) #t)
  (list "body a number" (with "body" 5 good) #t)
  (list "body null" (with "body" 'null good) #t)
  (list "body false" (with "body" #f good) #t)
  (list "content_type a number" (with "content_type" 5 good) #t)
  (list "content_type null" (with "content_type" 'null good) #t)
  ;; props: any object is taken; any other value is not
  (list "props []" (with "props" (vector) good) #t)
  (list "props [{}], an array, a replace" (with "props" (vector '()) (without "kind" good)) #f)
  (list "props a string" (with "props" "{}" good) #t)
  (list "props a number" (with "props" 0 good) #t)
  (list "props null" (with "props" 'null good) #t)
  (list "props null, a replace" (with "props" 'null (without "kind" good)) #f)
  (list "props false" (with "props" #f good) #t)
  (list "props true" (with "props" #t good) #t)
  ;; U+0000
  (list "U+0000 in the title" (with "title" (string #\a (integer->char 0) #\b) good) #t)
  (list "U+0000 alone as the title" (with "title" (string (integer->char 0)) good) #t)
  (list "U+0000 in the body" (with "body" (string #\a (integer->char 0) #\b) good) #t)
  (list "U+0000 at the body's end" (with "body" (string #\a (integer->char 0)) good) #t)))

;;; A create's parent (slice 5a, T3)

(define v4-text "0190b3a4-5c6d-4e8f-9a0b-1c2d3e4f5a6b")

;; parent-of : Any Boolean -> Any     (parent P) for a Content, anything else as it is
(define (parent-of x create?)
  (attempt (lambda ()
             (let ((r (parse-content x create?)))
               (if (content? r) (list 'parent (content-parent r)) r)))))

(test-equal "content: a create with no parent is at the top level"
  '(parent #f) (parent-of good #t))
(test-equal "content: a create with parent null is at the top level"
  '(parent #f) (parent-of (with "parent" 'null good) #t))
(test-equal "content: a create's parent, a v7 id in either case, is its 16 bytes"
  (list (list 'parent v7-bytes) (list 'parent v7-bytes))
  (list (parent-of (with "parent" v7-text good) #t)
        (parent-of (with "parent" (string-upcase v7-text) good) #t)))
(test-equal "content: the six members of a create, in another order"
  (list 'parent v7-bytes)
  (parent-of (reverse (with "props" '() (with "parent" v7-text good))) #t))
(test-equal "content: a parent changes none of the other members"
  '("note" "A title" "Some text" "text/plain" absent)
  (parsed (with "parent" v7-text good) #t))
(test-equal "content: a replace has no parent"
  '(parent #f) (parent-of (without "kind" good) #f))

(for-each
 (lambda (c)
   (test-equal (string-append "content: invalid, " (car c))
     'invalid
     (judged (cadr c) (caddr c))))
 (list
  (list "a v4 id as the parent" (with "parent" v4-text good) #t)
  (list "a parent that is no id" (with "parent" "x" good) #t)
  (list "an empty parent" (with "parent" "" good) #t)
  (list "a parent's id in braces" (with "parent" (string-append "{" v7-text "}") good) #t)
  (list "a number as the parent" (with "parent" 5 good) #t)
  (list "false as the parent" (with "parent" #f good) #t)
  (list "true as the parent" (with "parent" #t good) #t)
  (list "{} as the parent" (with "parent" '() good) #t)
  (list "an array as the parent" (with "parent" (vector v7-text) good) #t)
  (list "an object as the parent" (with "parent" (list (cons "id" v7-text)) good) #t)
  (list "parent twice, the same" (append (with "parent" v7-text good) (list (cons "parent" v7-text))) #t)
  (list "parent twice, null then an id" (append (with "parent" 'null good) (list (cons "parent" v7-text))) #t)
  (list "a seventh member, unknown" (with "x" 1 (with "props" '() (with "parent" v7-text good))) #t)
  (list "Parent, another case" (with "Parent" v7-text good) #t)
  (list "a replace with a parent" (with "parent" v7-text (without "kind" good)) #f)
  (list "a replace with parent null" (with "parent" 'null (without "kind" good)) #f)
  (list "a replace with a kind and a parent" (with "parent" v7-text good) #f)))

;;; Tags (slice 7a): parse-content takes tags of any value, and hands them
;;; on as read; (techo tags)' request-tags judges them.

(define (tags-of x create?)
  (attempt (lambda ()
             (let ((r (parse-content x create?)))
               (if (content? r) (list 'tags (content-tags r)) r)))))

(test-equal "content: tags not given are absent, on a create and a replace"
  '((tags absent) (tags absent))
  (list (tags-of good #t) (tags-of (without "kind" good) #f)))

(test-equal "content: tags of any value are handed on as read, not judged, on a create and a replace"
  '(#t #t #t #t #t #t #t #t #t #t #t #t)
  (attempt
   (lambda ()
     (apply append
            (map (lambda (v)
                   (map (lambda (create?)
                          (let ((r (parse-content (with "tags" v (if create? good (without "kind" good))) create?)))
                            (and (content? r) (eq? (content-tags r) v))))
                        '(#t #f)))
                 (list (vector "Work" "work") (vector) 'null "work" 5 (vector 5 'null)))))))

(test-equal "content: tags change none of the other members, and props and tags are each their own"
  '(("note" "A title" "Some text" "text/plain" absent) ("note" "A title" "Some text" "text/plain" (("a" . 1))))
  (list (parsed (with "tags" (vector "a") good) #t)
        (parsed (with "tags" '(("b" . 2)) (with "props" '(("a" . 1)) good)) #t)))

(test-equal "content: a create's seven members and a replace's six, tags among them, in another order"
  (list (list 'parent v7-bytes) '(tags #("a")))
  (list (parent-of (reverse (with "tags" (vector "a") (with "props" '() (with "parent" v7-text good)))) #t)
        (tags-of (reverse (with "tags" (vector "a") (with "props" '() good))) #f)))

(for-each
 (lambda (c)
   (test-equal (string-append "content: invalid, " (car c))
     'invalid
     (judged (cadr c) (caddr c))))
 (list
  (list "tags twice" (append good '(("tags" . #()) ("tags" . #()))) #t)
  (list "tags twice, a replace" (append (without "kind" good) '(("tags" . #("a")) ("tags" . #("a")))) #f)
  (list "Tags, another case" (with "Tags" (vector "a") good) #t)
  (list "tag, not tags" (with "tag" (vector "a") good) #t)
  (list "an eighth member" (with "x" 1 (with "tags" (vector) (with "props" '() (with "parent" v7-text good)))) #t)
  (list "a replace's seventh member, its parent"
        (with "parent" v7-text (with "tags" (vector) (with "props" '() good))) #f)))

;;; The limits, at each and one past it (H8)

(define e-acute (integer->char #xe9))          ; two bytes of UTF-8
(define cjk (integer->char #x65e5))            ; three
(define emoji (integer->char #x1F600))         ; four

(test-equal "title: 1000 characters is the limit"
  'content (judged (with "title" (make-string 1000 #\t) good) #t))
(test-equal "title: 1001 characters is past it"
  'invalid (judged (with "title" (make-string 1001 #\t) good) #t))
(test-equal "title: 1000 two-byte characters, characters counted, not bytes"
  'content (judged (with "title" (make-string 1000 e-acute) good) #t))
(test-equal "title: 1000 four-byte characters"
  'content (judged (with "title" (make-string 1000 emoji) good) #t))
(test-equal "title: 1001 two-byte characters"
  'invalid (judged (with "title" (make-string 1001 e-acute) good) #t))

(define (body-of . parts) (with "body" (apply string-append parts) good))

(test-equal "body: 1,048,576 ASCII characters is the limit"
  'content (judged (body-of (make-string 1048576 #\b)) #t))
(test-equal "body: 1,048,577 ASCII characters is past it"
  'too-large (judged (body-of (make-string 1048577 #\b)) #t))
(test-equal "body: 524,288 two-byte characters is exactly the limit"
  'content (judged (body-of (make-string 524288 e-acute)) #t))
(test-equal "body: 524,288 two-byte characters and one more byte"
  'too-large (judged (body-of (make-string 524288 e-acute) "b") #t))
(test-equal "body: 600,000 two-byte characters is over: bytes, not characters"
  'too-large (judged (body-of (make-string 600000 e-acute)) #t))
(test-equal "body: 349,525 three-byte characters and one byte is exactly the limit"
  'content (judged (body-of (make-string 349525 cjk) "b") #t))
(test-equal "body: 349,526 three-byte characters is past it"
  'too-large (judged (body-of (make-string 349526 cjk)) #t))
(test-equal "body: 262,144 four-byte characters is exactly the limit"
  'content (judged (body-of (make-string 262144 emoji)) #t))
(test-equal "body: 262,144 four-byte characters and one more byte"
  'too-large (judged (body-of (make-string 262144 emoji) "b") #t))
(test-equal "body: a body of exactly the limit comes back whole"
  1048576
  (attempt (lambda ()
             (string-length (content-body (parse-content (body-of (make-string 1048576 #\b)) #t))))))
;; exactly : Natural Char -> String     CAP bytes of UTF-8: C as often as fits, then b's
(define (exactly width c)
  (let ((k (div body-cap width)))
    (string-append (make-string k c) (make-string (- body-cap (* k width)) #\b))))

(test-equal "body: each width's two ends, at the limit and one byte past it"
  '((content too-large) (content too-large) (content too-large) (content too-large)
    (content too-large) (content too-large) (content too-large))
  (attempt
   (lambda ()
     (map (lambda (w)
            (let ((s (exactly (car w) (integer->char (cdr w)))))
              (list (verdict (parse-content (body-of s) #t))
                    (verdict (parse-content (body-of s "b") #t)))))
          '((1 . #x7f) (2 . #x80) (2 . #x7ff) (3 . #x800) (3 . #xffff) (4 . #x10000)
            (4 . #x10ffff))))))

(test-equal "body: too large on a replace with no kind"
  'too-large
  (judged (with "body" (make-string 1048577 #\b) (without "kind" good)) #f))

(test-equal "body: too large is answered only when all else is right"
  '(invalid invalid invalid invalid invalid invalid)
  (let ((big (make-string 1048577 #\b)))
    (map (lambda (x) (judged x #t))
         (list (with "body" big (without "kind" good))
               (with "body" big (with "id" "x" good))
               (with "body" big (with "title" (make-string 1001 #\t) good))
               (with "body" big (with "content_type" "plain" good))
               (with "body" big (with "props" (vector) good))
               (with "body" (string-append big (string (integer->char 0))) good)))))

(test-equal "body: too large whatever the props' members: parse-content does not judge them"
  '(too-large too-large)
  (let ((big (make-string 1048577 #\b)))
    (list (judged (with "body" big (with "props" '(("a" . 1)) good)) #t)
          (judged (with "body" big (with "props" '(("status" . "nope")) (without "kind" good))) #f))))

(test-equal "body: too large is answered only when the parent is right too"
  '(invalid invalid too-large)
  (let ((big (make-string 1048577 #\b)))
    (list (judged (with "body" big (with "parent" v4-text good)) #t)
          (judged (with "body" big (with "parent" v7-text (without "kind" good))) #f)
          (judged (with "body" big (with "parent" v7-text good)) #t))))

(define (with-type t) (with "content_type" t good))

(test-equal "content_type: 255 characters is the limit"
  'content (judged (with-type (string-append "a/" (make-string 253 #\x))) #t))
(test-equal "content_type: 256 characters is past it"
  'invalid (judged (with-type (string-append "a/" (make-string 254 #\x))) #t))
(test-equal "content_type: one character, /"
  'content (judged (with-type "/") #t))
(test-equal "content_type: U+0020 and U+007E, the ends of what is allowed, with spaces inside"
  '(content content content)
  (map (lambda (t) (judged (with-type t) #t))
       (list " /" "~/" "text/plain; charset=utf-8")))
(test-equal "content_type: two slashes are allowed"
  'content (judged (with-type "a/b/c") #t))

(for-each
 (lambda (c)
   (test-equal (string-append "content_type: invalid, " (car c))
     'invalid
     (judged (with-type (cdr c)) #t)))
 (list (cons "empty" "")
       (cons "no slash" "textplain")
       (cons "a tab" "text/\t")
       (cons "a newline" "text/plain\n")
       (cons "U+001F" (string (integer->char #x1f) #\/))
       (cons "DEL" (string #\a #\/ (integer->char #x7f)))
       (cons "e acute" (string #\a #\/ e-acute))
       (cons "U+0000" (string #\a #\/ (integer->char 0)))))

;; A small deterministic generator (a linear congruential one); no entropy.
(define (make-lcg seed)
  (let ((state seed))
    (lambda (n)
      (set! state (mod (+ (* state 1103515245) 12345) 2147483648))
      (mod (div state 65536) n))))

(define fuzz-names
  '("kind" "title" "body" "content_type" "props" "parent" "tags" "id" "revision" "Title" "Parent" ""))
(define fuzz-strings
  (list "" "note" "task" "Note" "text/plain" "/" "plain" (string #\a (integer->char 0)) "x"
        (make-string 1001 #\t) v7-text v4-text))

;; fuzz-value : (Natural -> Natural) Natural -> Any     a value as jsonparse makes one
(define (fuzz-value next depth)
  (case (next 10)
    ((0 1 2) (list-ref fuzz-strings (next (length fuzz-strings))))
    ((3) (next 100))
    ((4) 1.5)
    ((5) 'null)
    ((6) (= 0 (next 2)))
    ((7) '())
    ((8) (vector (next 3)))
    (else (if (> depth 0) (fuzz-object next (- depth 1)) "deep"))))

;; fuzz-object : (Natural -> Natural) Natural -> Alist
;; Often the good content with a member dropped, changed or added.
(define (fuzz-object next depth)
  (let ((name (list-ref fuzz-names (next (length fuzz-names))))
        (value (fuzz-value next depth)))
    (case (next 4)
      ((0) (without name good))
      ((1) (with name value good))
      ((2) (append good (list (cons name value))))
      (else (let loop ((k (next 7)) (acc '()))
              (if (= k 0)
                  acc
                  (loop (- k 1)
                        (cons (cons (list-ref fuzz-names (next (length fuzz-names)))
                                    (fuzz-value next depth))
                              acc))))))))

;; fits? : Alist Content -> Boolean     each field what the object gave
;; A parent not given, or null, is #f; a given one is its id's bytes.
;; Props not given are absent; given, they are the very value, an object.
;; Tags the same, of any value.
(define (fits? x c)
  (let ((given (lambda (name) (let ((m (assoc name x))) (and m (cdr m))))))
    (and (equal? (content-title c) (given "title"))
         (equal? (content-body c) (given "body"))
         (equal? (content-content-type c) (given "content_type"))
         (equal? (content-kind c) (given "kind"))
         (let ((m (assoc "props" x)))
           (if m
               (and (eq? (content-props c) (cdr m)) (or (null? (cdr m)) (pair? (cdr m))))
               (eq? (content-props c) 'absent)))
         (let ((m (assoc "tags" x)))
           (if m (eq? (content-tags c) (cdr m)) (eq? (content-tags c) 'absent)))
         (equal? (content-parent c)
                 (let ((p (given "parent")))
                   (if (or (not p) (eq? p 'null)) #f (parse-node-id p)))))))

(test-equal "content: never raises, and a Content holds what was given"
  'ok
  (let ((next (make-lcg 20261125)))
    (let loop ((n 0) (contents 0))
      (if (= n 3000)
          (if (> contents 10) 'ok (list 'too-few-contents contents))
          (let* ((x (if (= 0 (next 8)) (fuzz-value next 2) (fuzz-object next 2)))
                 (create? (= 0 (next 2)))
                 (r (guard (e (#t (list 'raised (describe e)))) (parse-content x create?))))
            (cond ((content? r)
                   (if (fits? x r) (loop (+ n 1) (+ contents 1)) (list 'misread x)))
                  ((memq r '(invalid too-large)) (loop (+ n 1) contents))
                  (else (list 'bad x r))))))))

;;; The linear rule (the review's blocker 2, H13)

;; timed : (-> Alist) Boolean -> (List Any (U 'quick Natural))
;; MAKE builds the object first; only parse-content is timed: its answer,
;; and 'quick under 100 ms, else the milliseconds it took.
(define (timed make create?)
  (attempt
   (lambda ()
     (let* ((x (make))
            (t0 (real-time))
            (r (verdict (parse-content x create?)))
            (t1 (real-time)))
       (list r (if (< (- t1 t0) 100) 'quick (- t1 t0)))))))

;; members : Natural (Natural -> Pair) Alist -> Alist     N made members after HEAD
(define (members n make head)
  (let loop ((i (- n 1)) (acc '()))
    (if (< i 0) (append head acc) (loop (- i 1) (cons (make i) acc)))))

(test-equal "linear: 200,000 members of unknown names, refused at once"
  '(invalid quick)
  (timed (lambda () (members 200000 (lambda (i) (cons (string-append "x" (number->string i)) i))
                             '()))
         #t))

(test-equal "linear: 200,000 members all named title, refused at once"
  '(invalid quick)
  (timed (lambda () (members 200000 (lambda (i) (cons "title" "t")) '())) #t))

(test-equal "linear: the six known members, then 199,994 repeats of title"
  '(invalid quick)
  (timed (lambda () (members 199994 (lambda (i) (cons "title" "t"))
                             (append good '(("props") ("tags" . #()))))) #t))

(test-equal "linear: a body of the request's cap, 2 MiB of ASCII, too large at once"
  '(too-large quick)
  (timed (lambda () (with "body" (make-string 2097152 #\b) good)) #t))

(test-equal "linear: a parent of 2 MiB, refused at once"
  '(invalid quick)
  (timed (lambda () (with "parent" (make-string 2097152 #\a) good)) #t))

(test-equal "linear: props of 200,000 members are handed on at once, not walked"
  '(content quick)
  (timed (lambda () (with "props" (members 200000 (lambda (i) (cons "x" i)) '()) good)) #t))

(test-equal "linear: a create's seven members, then 199,993 repeats of parent"
  '(invalid quick)
  (timed (lambda () (members 199993 (lambda (i) (cons "parent" 'null))
                             (append (with "parent" 'null good) '(("props") ("tags" . #())))))
         #t))

(test-equal "linear: tags of 200,000 entries are handed on at once, not walked"
  '(content quick)
  (timed (lambda () (with "tags" (make-vector 200000 (make-string 300 #\a)) good)) #t))

;;; A move's body and the list's ?parent= (slice 5a)

(test-equal "move body: a v7 id, in either case, is its bytes; null is the top level"
  (list v7-bytes v7-bytes #f)
  (attempt (lambda ()
             (map parse-move-body
                  (list (list (cons "parent" v7-text))
                        (list (cons "parent" (string-upcase v7-text)))
                        '(("parent" . null)))))))

(for-each
 (lambda (c)
   (test-equal (string-append "move body: invalid, " (car c))
     'invalid
     (attempt (lambda () (parse-move-body (cdr c))))))
 (list (cons "{}, which reads as ()" '())
       (cons "a number" 7)
       (cons "a string" v7-text)
       (cons "null" 'null)
       (cons "true" #t)
       (cons "false" #f)
       (cons "an empty array" (vector))
       (cons "an array holding the object" (vector (list (cons "parent" v7-text))))
       (cons "a v4 id" (list (cons "parent" v4-text)))
       (cons "a string that is no id" '(("parent" . "x")))
       (cons "an empty string" '(("parent" . "")))
       (cons "the id in braces" (list (cons "parent" (string-append "{" v7-text "}"))))
       (cons "a number as the parent" '(("parent" . 5)))
       (cons "false as the parent" '(("parent" . #f)))
       (cons "true as the parent" '(("parent" . #t)))
       (cons "{} as the parent" '(("parent")))
       (cons "an array as the parent" (list (cons "parent" (vector v7-text))))
       (cons "an object as the parent" (list (cons "parent" (list (cons "id" v7-text)))))
       (cons "the member twice, the same id" (list (cons "parent" v7-text) (cons "parent" v7-text)))
       (cons "the member twice, null" '(("parent" . null) ("parent" . null)))
       (cons "another member after it" (list (cons "parent" v7-text) (cons "kind" "note")))
       (cons "another member before it" (list (cons "kind" "note") (cons "parent" v7-text)))
       (cons "another member alone" '(("kind" . "note")))
       (cons "Parent, another case" '(("Parent" . null)))
       (cons "a member with an empty name" '(("" . null)))
       (cons "a member named by a symbol" '((parent . null)))
       (cons "an improper list" (cons '("parent" . null) 5))
       (cons "a list of a string" '("parent"))))

(test-equal "move body: a parent of 2 MiB, refused at once"
  '(invalid quick)
  (attempt (lambda ()
             (let* ((x (list (cons "parent" (make-string 2097152 #\a))))
                    (t0 (real-time))
                    (r (parse-move-body x))
                    (t1 (real-time)))
               (list r (if (< (- t1 t0) 100) 'quick (- t1 t0)))))))

(test-equal "move body: 200,000 members, refused at once"
  '(invalid quick)
  (attempt (lambda ()
             (let* ((x (members 200000 (lambda (i) (cons "parent" 'null)) '()))
                    (t0 (real-time))
                    (r (parse-move-body x))
                    (t1 (real-time)))
               (list r (if (< (- t1 t0) 100) 'quick (- t1 t0)))))))

(test-equal "?parent=: not given is any; null is the top level; a v7 id, in either case, is its bytes"
  (list 'any #f v7-bytes v7-bytes)
  (attempt (lambda ()
             (map parse-parent-param (list #f "null" v7-text (string-upcase v7-text))))))

(for-each
 (lambda (x)
   (test-equal (string-append "?parent=: refused, " (written x))
     'invalid
     (attempt (lambda () (parse-parent-param x)))))
 (list "" "NULL" "Null" " null" "null " "nul" "none" "any" "x" v4-text
       (string-append v7-text ",") (string-append "{" v7-text "}") 7 'null))

;;; found and write-event: what the job saw, as the table's state and event

(test-equal "found: no node, the revision given, another revision"
  '(none match differ differ)
  (attempt (lambda () (list (found #f 7) (found 7 7) (found 8 7) (found 6 7)))))

(test-equal "found: a node past 2^53 is at another revision, not an error"
  'differ
  (attempt (lambda () (found (+ two-53 1) two-53))))

(test-equal "found-for-create: an id not in use, and one in use"
  '(none differ)
  (attempt (lambda () (list (found-for-create #f) (found-for-create #t)))))

(define (event . args) (attempt (lambda () (apply write-event args))))

(test-equal "event: put with If-None-Match: * is create, whatever the kinds"
  '(create create create)
  (list (event 'put 'create "note" #f #f)
        (event 'put 'create "note" "task" #f)
        (event 'put 'create #f #f #t)))

(test-equal "event: put with a revision is replace, the kind the same, left out, or no node"
  '(replace replace replace replace)
  (list (event 'put 7 "note" "note" #f)
        (event 'put 7 #f "note" #f)
        (event 'put 7 "note" #f #f)
        (event 'put 7 #f #f #f)))

(test-equal "event: put naming another kind than the node's is replace-other-kind"
  '(replace-other-kind replace-other-kind)
  (list (event 'put 7 "task" "note" #f)
        (event 'put 7 "project" "contact" #t)))

(test-equal "event: restore, with the snapshot there or not"
  '(restore restore-unknown restore restore-unknown)
  (list (event 'restore 7 #f "note" #t)
        (event 'restore 7 #f "note" #f)
        (event 'restore 3 #f #f #t)
        (event 'restore 3 #f #f #f)))

(test-equal "event: what no route sends raises"
  '(assertion assertion assertion assertion assertion assertion)
  (map (lambda (args) (raised-kind (lambda () (apply write-event args))))
       (list (list 'get 7 #f #f #f)
             (list 'restore 'create #f #f #t)
             (list 'put 'missing #f #f #f)
             (list 'put 'invalid #f #f #f)
             (list 'put 0 #f #f #f)
             (list 'put 7 'note "note" #f))))

;;; D5's table (H7)

(define starts '(none match differ))

(define (write-problems rows)
  (attempt (lambda () (machine-problems (make-machine rows) starts #f write-cant-happen))))

(test-equal "table: machine-problems, every Found a start and no end, answers ()"
  '()
  (write-problems write-rows))

(test-equal "table: twelve rows"
  12
  (attempt (lambda () (length write-rows))))

(test-equal "table: dropping match + restore is reported"
  '((unlisted-gap match restore))
  (write-problems (filter (lambda (r) (not (and (eq? (car r) 'match) (eq? (cadr r) 'restore))))
                          write-rows)))

(test-equal "table: a row for a can't-happen pair is reported"
  '((listed-but-has-row match create))
  (write-problems (append write-rows (list (list 'match 'create 'differ 'insert (lambda (d e) d))))))

(test-equal "table: a second row for one pair is reported"
  '((double-row none create))
  (write-problems (append write-rows (list (list 'none 'create 'none 'refuse-412 (lambda (d e) d))))))

(test-equal "table: the can't-happen pairs, three of them"
  '((none replace-other-kind) (none restore) (match create))
  (attempt (lambda () (map (lambda (c) (list (car c) (cadr c))) write-cant-happen))))

(test-assert "table: every can't-happen reason is a non-empty string"
  (for-all (lambda (c) (and (string? (caddr c)) (> (string-length (caddr c)) 0)))
           write-cant-happen))

(define events '(create replace replace-other-kind restore restore-unknown))
(define commands '(insert write copy refuse-404 refuse-409 refuse-412))

(test-equal "table: every cell of three states and five events is a row or a can't-happen, once"
  '()
  (attempt
   (lambda ()
     (apply append
            (map (lambda (s)
                   (apply append
                          (map (lambda (e)
                                 (let ((rows (length (filter (lambda (r) (and (eq? (car r) s)
                                                                              (eq? (cadr r) e)))
                                                             write-rows)))
                                       (cants (length (filter (lambda (c) (and (eq? (car c) s)
                                                                               (eq? (cadr c) e)))
                                                              write-cant-happen))))
                                   (if (= (+ rows cants) 1) '() (list (list s e rows cants)))))
                               events)))
                 starts)))))

(test-equal "table: no state, event or command but D5's"
  '()
  (attempt (lambda ()
             (filter (lambda (r) (not (and (memq (car r) starts) (memq (cadr r) events)
                                           (memq (caddr r) starts) (memq (cadddr r) commands))))
                     write-rows))))

(test-equal "table: insert, write and copy go to differ; a refusal stays where it was"
  '()
  (attempt (lambda ()
             (filter (lambda (r)
                       (not (if (memq (cadddr r) '(insert write copy))
                                (eq? (caddr r) 'differ)
                                (eq? (caddr r) (car r)))))
                     write-rows))))

;; stepped : Found EventKind -> (List Found CommandKind)
(define (stepped s e)
  (attempt (lambda () (call-with-values (lambda () (write-step s e)) list))))

(define d5
  '((none create differ insert)
    (none replace none refuse-404)
    (none restore-unknown none refuse-404)
    (match replace differ write)
    (match replace-other-kind match refuse-409)
    (match restore differ copy)
    (match restore-unknown match refuse-404)
    (differ create differ refuse-412)
    (differ replace differ refuse-412)
    (differ replace-other-kind differ refuse-412)
    (differ restore differ refuse-412)
    (differ restore-unknown differ refuse-412)))

(for-each
 (lambda (row)
   (test-equal (string-append "step: " (symbol->string (car row)) " + "
                              (symbol->string (cadr row)))
     (list (caddr row) (cadddr row))
     (stepped (car row) (cadr row))))
 d5)

(test-equal "step: the rows are exactly D5's, in order"
  d5
  (attempt (lambda () (map (lambda (r) (list (car r) (cadr r) (caddr r) (cadddr r))) write-rows))))

(test-equal "step: each can't-happen pair raises an assertion violation"
  '(assertion assertion assertion)
  (map (lambda (c) (raised-kind (lambda () (write-step (car c) (cadr c)))))
       '((none replace-other-kind) (none restore) (match create))))

(test-equal "step: an unknown state or event raises"
  '(assertion assertion)
  (list (raised-kind (lambda () (write-step 'gone 'replace)))
        (raised-kind (lambda () (write-step 'match 'delete)))))

;; A write, from the headers to the command: the pure path a route takes.
;; command : Symbol (Listof String) (Listof String) (U Natural #f) Boolean
;;           (U String #f) (U String #f) Boolean -> CommandKind
(define (command route im inm stored in-use? request-kind stored-kind snapshot?)
  (attempt
   (lambda ()
     (let* ((p (precondition im inm))
            (f (if (eq? p 'create) (found-for-create in-use?) (found stored p)))
            (e (write-event route p request-kind stored-kind snapshot?)))
       (let-values (((next c) (write-step f e))) c)))))

(test-equal "path: create, stale create, replace, stale replace, other kind, missing, restore"
  '(insert refuse-412 write refuse-412 refuse-409 refuse-404 copy refuse-404 refuse-404)
  (list (command 'put '() '("*") #f #f "note" #f #f)
        (command 'put '() '("*") #f #t "note" #f #f)
        (command 'put '("\"3\"") '() 3 #f #f "note" #f)
        (command 'put '("\"2\"") '() 3 #f "note" "note" #f)
        (command 'put '("\"3\"") '() 3 #f "task" "note" #f)
        (command 'put '("\"3\"") '() #f #f "note" #f #f)
        (command 'restore '("\"3\"") '() 3 #f #f "note" #t)
        (command 'restore '("\"3\"") '() 3 #f #f "note" #f)
        (command 'restore '("\"3\"") '() #f #f #f #f #f)))

;;; The lifecycle's table (slice 4b, G1)

(define life-states '(active archived trashed purged))
(define life-events '(archive unarchive trash untrash purge write move move-children link unlink retag))

;; The table the owner approved, written out here, not read from
;; lifecycle-rows: (state event next command) for a row, (state event) for a
;; cell that cannot happen. In the table's order. Slice 5a's two events
;; (T8, the review's blocker 3): move is refused for a trashed node, and
;; move-children allowed in every state. Slice 5b's two (K6, the review's
;; blocker 5): link is refused for a trashed node, and unlink allowed in
;; every state. Slice 7a's retag (its review, blocker 10): a rename's or a
;; removal's step takes a node in every live state.
(define lifecycle-table
  '((active archive archived set-state)
    (active unarchive active refuse-wrong-state)
    (active trash trashed set-state)
    (active untrash active refuse-wrong-state)
    (active purge active refuse-wrong-state)
    (active write active allow)
    (active move active allow)
    (active move-children active allow)
    (active link active allow)
    (active unlink active allow)
    (active retag active allow)
    (archived archive archived refuse-wrong-state)
    (archived unarchive active set-state)
    (archived trash trashed set-state)
    (archived untrash archived refuse-wrong-state)
    (archived purge archived refuse-wrong-state)
    (archived write archived allow)
    (archived move archived allow)
    (archived move-children archived allow)
    (archived link archived allow)
    (archived unlink archived allow)
    (archived retag archived allow)
    (trashed archive trashed refuse-wrong-state)
    (trashed unarchive trashed refuse-wrong-state)
    (trashed trash trashed refuse-wrong-state)
    (trashed untrash active set-state)
    (trashed purge purged purge)
    (trashed write trashed refuse-wrong-state)
    (trashed move trashed refuse-wrong-state)
    (trashed move-children trashed allow)
    (trashed link trashed refuse-wrong-state)
    (trashed unlink trashed allow)
    (trashed retag trashed allow)
    (purged archive)
    (purged unarchive)
    (purged trash)
    (purged untrash)
    (purged purge)
    (purged write)
    (purged move)
    (purged move-children)
    (purged link)
    (purged unlink)
    (purged retag)))

(define (lifecycle-problems rows)
  (attempt (lambda () (machine-problems (make-machine rows) '(active) '(purged)
                                        lifecycle-cant-happen))))

(test-equal "lifecycle: machine-problems, start active and end purged, answers ()"
  '()
  (lifecycle-problems lifecycle-rows))

(test-equal "lifecycle: thirty-three rows, three states by eleven events"
  33
  (attempt (lambda () (length lifecycle-rows))))

(test-equal "lifecycle: the rows are exactly the table's, in its order"
  (filter (lambda (c) (= (length c) 4)) lifecycle-table)
  (attempt (lambda () (map (lambda (r) (list (car r) (cadr r) (caddr r) (cadddr r)))
                           lifecycle-rows))))

(test-equal "lifecycle: the can't-happen pairs are purged's eleven, in the table's order"
  (filter (lambda (c) (= (length c) 2)) lifecycle-table)
  (attempt (lambda () (map (lambda (c) (list (car c) (cadr c))) lifecycle-cant-happen))))

(test-equal "lifecycle: every can't-happen pair has a reason, a non-empty string"
  '(#t #t #t #t #t #t #t #t #t #t #t)
  (attempt (lambda ()
             (map (lambda (c) (and (string? (caddr c)) (> (string-length (caddr c)) 0)))
                  lifecycle-cant-happen))))

(test-equal "lifecycle: dropping archived + untrash is reported"
  '((unlisted-gap archived untrash))
  (lifecycle-problems
   (filter (lambda (r) (not (and (eq? (car r) 'archived) (eq? (cadr r) 'untrash))))
           lifecycle-rows)))

(test-equal "lifecycle: a row for purged, the end, is reported"
  '((listed-but-has-row purged write) (terminal-has-row purged))
  (lifecycle-problems
   (append lifecycle-rows (list (list 'purged 'write 'purged 'allow (lambda (d e) d))))))

(test-equal "lifecycle: only set-state and purge move a node, each from its own cell"
  '((active archive archived set-state) (active trash trashed set-state)
    (archived unarchive active set-state) (archived trash trashed set-state)
    (trashed untrash active set-state) (trashed purge purged purge))
  (attempt (lambda ()
             (map (lambda (r) (list (car r) (cadr r) (caddr r) (cadddr r)))
                  (filter (lambda (r) (not (eq? (car r) (caddr r)))) lifecycle-rows)))))

(test-equal "lifecycle: what leaves the state is a refusal or allow, and nothing else"
  '(refuse-wrong-state allow)
  (attempt (lambda ()
             (fold-left (lambda (acc r) (if (memq (cadddr r) acc) acc (append acc (list (cadddr r)))))
                        '()
                        (filter (lambda (r) (eq? (car r) (caddr r))) lifecycle-rows)))))

;; life-stepped : Symbol Symbol -> (U (List Symbol Symbol) 'cannot-happen (List 'raised String))
;; The next state and the command; 'cannot-happen for an assertion violation
;; whose irritants are the cell, the state and the event; any other raise as
;; itself.
(define (life-stepped s e)
  (guard (x ((and (assertion-violation? x) (irritants-condition? x)
                  (equal? (condition-irritants x) (list s e)))
             'cannot-happen)
            (#t (list 'raised (describe x))))
    (call-with-values (lambda () (lifecycle-step s e)) list)))

;; Every one of the 44 cells, by construction: a cell the table above lacks
;; expects what no step answers.
(for-each
 (lambda (s)
   (for-each
    (lambda (e)
      (let ((c (find (lambda (c) (and (eq? (car c) s) (eq? (cadr c) e))) lifecycle-table)))
        (test-equal (string-append "lifecycle step: " (symbol->string s) " + " (symbol->string e))
          (cond ((not c) 'missing-from-the-suites-table)
                ((= (length c) 4) (list (caddr c) (cadddr c)))
                (else 'cannot-happen))
          (life-stepped s e))))
    life-events))
 life-states)

(test-equal "lifecycle step: an unknown state, an unknown event and a request's own event raise"
  '(assertion assertion assertion)
  (list (raised-kind (lambda () (lifecycle-step 'gone 'archive)))
        (raised-kind (lambda () (lifecycle-step 'active 'delete)))
        (raised-kind (lambda () (lifecycle-step 'active 'replace)))))

;;; The tree: what may hold what, the verdict on a new parent, and which
;;; children a bulk move takes (slice 5a: T2, T5, T8, the review's blockers
;;; 2 and 3, P18)

(define kinds '("project" "journal" "note" "task" "contact"))

;; What may hold what (T2), written out here, not read from the library: a
;; parent's kind, then every kind it holds. A Project holds any kind,
;; Projects too; a Journal only Notes; the rest nothing.
(define hold-table
  '(("project" "project" "journal" "note" "task" "contact")
    ("journal" "note")
    ("note")
    ("task")
    ("contact")))

;; holds? : String String -> Boolean     the table above's answer
(define (holds? parent child) (and (member child (cdr (assoc parent hold-table))) #t))

;; Every one of the 25 pairs.
(for-each
 (lambda (p)
   (for-each
    (lambda (c)
      (test-equal (string-append "may-hold?: " p " holds " c "?")
        (holds? p c)
        (attempt (lambda () (may-hold? p c)))))
    kinds))
 kinds)

;; raised-who : (-> Any) -> (U Symbol 'no-raise 'other)
;; The who of an assertion violation; 'no-raise when nothing was raised;
;; 'other for any other raise, or one with no who. A check of the library's
;; own is told from a car or a bytevector=? that happened to raise.
(define (raised-who thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e)) (condition-who e))
            (#t 'other))
    (thunk)
    'no-raise))

(test-equal "may-hold?: what is no kind raises, as the parent or as the child"
  '(may-hold? may-hold? may-hold? may-hold? may-hold? may-hold? may-hold?)
  (map (lambda (pc) (raised-who (lambda () (may-hold? (car pc) (cadr pc)))))
       '(("Project" "note") ("folder" "note") (#f "note") (project "note")
         ("project" "Note") ("project" "folder") ("journal" #f))))

;; The verdict's facts. K is the id kept out, P another; a chain's ids are
;; neither.
(define (test-id n)
  (let ((b (make-bytevector 16 0)))
    (bytevector-u16-set! b 14 n (endianness big))
    b))
(define keep-id (test-id 1000))
(define other-id (test-id 2000))
;; chain : Natural -> (Listof Bytevector)     N distinct ids, none K or P
(define (chain n)
  (let loop ((i n) (acc '()))
    (if (= i 0) acc (loop (- i 1) (cons (test-id i) acc)))))

;; Each fact by a name, and its value.
(define verdict-parents (list (cons 'top #f) (cons 'other other-id) (cons 'itself keep-id)))
(define verdict-ancestors
  (list (cons 'none '())
        (cons 'holding-it (list (test-id 1) keep-id (test-id 2)))
        (cons 'sixty-three (chain 63))
        (cons 'sixty-four (chain 64))
        (cons 'sixty-four-holding-it (append (chain 63) (list keep-id)))
        (cons 'sixty-five (chain 65))))
(define verdict-founds
  (cons #f (apply append (map (lambda (k) (map (lambda (s) (list k s)) '(active archived trashed)))
                              kinds))))
(define kinds-in (append kinds '(#f)))

;; expected-verdict : Symbol (U (List String Symbol) #f) Symbol (U String #f) -> Symbol
;; The plan's review's order, by the facts' names, the first that applies:
;; the top level is ok; nothing found is missing; a trashed parent is
;; trashed; the node itself as the parent, or among the parent's ancestors,
;; is a loop; a kind the parent may not hold, or for a bulk move (#f) a
;; parent that holds nothing, is wrong-kind; 64 ancestors or more is too
;; deep (a parent may have 63); else ok.
(define (expected-verdict parent found ancestors kind)
  (let ((held (and found (cdr (assoc (car found) hold-table)))))
    (cond ((eq? parent 'top) 'ok)
          ((not found) 'missing)
          ((eq? (cadr found) 'trashed) 'trashed)
          ((or (eq? parent 'itself) (memq ancestors '(holding-it sixty-four-holding-it))) 'loop)
          ((if kind (not (member kind held)) (null? held)) 'wrong-kind)
          ((memq ancestors '(sixty-four sixty-four-holding-it sixty-five)) 'too-deep)
          (else 'ok))))

;; Every combination: 3 parents, 16 founds, 6 ancestries, 6 kinds going in.
(for-each
 (lambda (p)
   (for-each
    (lambda (f)
      (for-each
       (lambda (a)
         (for-each
          (lambda (k)
            (test-equal (string-append "verdict: parent " (written (car p)) ", found " (written f)
                                       ", ancestors " (written (car a)) ", going in " (written k))
              (expected-verdict (car p) f (car a) k)
              (attempt (lambda () (parent-verdict (cdr p) f (cdr a) keep-id k)))))
          kinds-in))
       verdict-ancestors))
    verdict-founds))
 verdict-parents)

(test-equal "verdict: the grid above expects each of the six verdicts"
  '(#t #t #t #t #t #t)
  (let ((seen (apply append
                     (map (lambda (p)
                            (apply append
                                   (map (lambda (f)
                                          (apply append
                                                 (map (lambda (a)
                                                        (map (lambda (k) (expected-verdict (car p) f (car a) k))
                                                             kinds-in))
                                                      verdict-ancestors)))
                                        verdict-founds)))
                          verdict-parents))))
    (map (lambda (v) (and (memq v seen) #t)) '(ok missing trashed loop wrong-kind too-deep))))

(test-equal "verdict: facts no job finds raise; a state given as a string is no state"
  '(parent-verdict parent-verdict parent-verdict parent-verdict parent-verdict parent-verdict
    parent-verdict parent-verdict parent-verdict)
  (map (lambda (args) (raised-who (lambda () (apply parent-verdict args))))
       (list (list other-id '("project" purged) '() keep-id "note")
             (list other-id '("project" "active") '() keep-id "note")
             (list other-id '("project" "trashed") '() keep-id "note")
             (list other-id '("folder" active) '() keep-id "note")
             (list other-id '("project" active) '() keep-id "Note")
             (list (make-bytevector 15 0) '("project" active) '() keep-id "note")
             (list other-id '("project" active) '() (make-bytevector 15 0) "note")
             (list other-id '("project" active) (list "x") keep-id "note")
             (list other-id '("project" active) 'none keep-id "note"))))

;; expected-move : Symbol String (U String #f) -> Boolean
;; A child moves when it is active or archived (T8) and the new parent may
;; hold it; the top level holds every kind.
(define (expected-move state kind parent-kind)
  (and (memq state '(active archived)) (or (not parent-kind) (holds? parent-kind kind)) #t))

;; Every child's state a job can find, by every kind, by every new parent's kind.
(for-each
 (lambda (s)
   (for-each
    (lambda (k)
      (for-each
       (lambda (pk)
         (test-equal (string-append "child-moves?: " (written s) " " k " into " (written pk))
           (expected-move s k pk)
           (attempt (lambda () (child-moves? s k pk)))))
       kinds-in))
    kinds))
 '(active archived trashed))

(test-equal "child-moves?: a purged child and a state as a string raise in the step; a kind that is none in may-hold?"
  '(machine-step machine-step may-hold?)
  (list (raised-who (lambda () (child-moves? 'purged "note" "project")))
        (raised-who (lambda () (child-moves? "active" "note" "project")))
        (raised-who (lambda () (child-moves? 'active "folder" "project")))))

(test-equal "child-kind-filter: the top level and a project take any kind; a journal only notes"
  '(any any "note")
  (attempt (lambda () (map child-kind-filter '(#f "project" "journal")))))

(test-equal "child-kind-filter: a kind that holds nothing raises, and so does what is no kind"
  '(child-kind-filter child-kind-filter child-kind-filter may-hold? may-hold?)
  (map (lambda (k) (raised-who (lambda () (child-kind-filter k))))
       '("note" "task" "contact" "folder" "Project")))

(test-equal "child-kind-filter: agrees with may-hold? over every kind"
  '()
  (attempt
   (lambda ()
     (filter (lambda (x) x)
             (map (lambda (p)
                    (let ((held (filter (lambda (c) (may-hold? p c)) kinds))
                          (f (guard (e ((assertion-violation? e) 'raised)) (child-kind-filter p))))
                      (if (cond ((null? held) (eq? f 'raised))
                                ((eq? f 'any) (equal? held kinds))
                                ((string? f) (equal? held (list f)))
                                (else #f))
                          #f
                          (list p f held))))
                  kinds)))))

;;; node-command: the two tables, the verdict and the children answer one
;;; request (slice 4b, G5, G15; slice 5a, P6, P17)

;; link and unlink are the lifecycle table's events but no request's to
;; node-command: link-command answers them (the review's blocker 5, Q19), so
;; every cell of theirs here cannot happen. retag the same: a tag's step
;; names no one node (slice 7a's review, blocker 10).
(define request-events '(create replace replace-other-kind restore restore-unknown
                         archive unarchive trash untrash purge move move-children
                         link unlink retag))
(define request-states '(#f active archived trashed purged))
(define verdicts '(ok missing trashed loop wrong-kind too-deep))

;; What each verdict answers, written out (T10, P17): go is the request's
;; own command; any other is its refusal.
(define verdict-answers
  '((ok . go) (missing . refuse-invalid-parent) (trashed . refuse-invalid-parent)
    (loop . refuse-would-loop) (wrong-kind . refuse-invalid-parent)
    (too-deep . refuse-invalid-parent)))

;; What node-command answers, written out: under each Found, a row per state
;; in request-states' order, an entry per event in request-events' order. X is
;; an assertion violation (the cell cannot happen); a symbol is that command
;; and #f; (set-state S) is set-state and the state S to store; (parent C)
;; is C when the verdict is ok, else the verdict's refusal; (children C) is
;; refuse-has-children when the node has children, else C. No other entry
;; looks at the verdict or the children.
(define node-command-table
  '((none
     (#f       (parent insert) refuse-404 X X refuse-404
               refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404
               X X X)
     (active   (parent insert) refuse-404 X X refuse-404
               refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404
               X X X)
     (archived (parent insert) refuse-404 X X refuse-404
               refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404
               X X X)
     (trashed  (parent insert) refuse-404 X X refuse-404
               refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404
               X X X)
     (purged   (parent insert) refuse-404 X X refuse-404
               refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404
               X X X))
    (match
     (#f       X X X X X X X X X X X X X X X)
     (active   X write refuse-409 copy refuse-404
               (set-state archived) refuse-wrong-state (set-state trashed)
               refuse-wrong-state refuse-wrong-state (parent move) (parent move-children)
               X X X)
     (archived X write refuse-409 copy refuse-404
               refuse-wrong-state (set-state active) (set-state trashed)
               refuse-wrong-state refuse-wrong-state (parent move) (parent move-children)
               X X X)
     (trashed  X refuse-wrong-state refuse-wrong-state refuse-wrong-state refuse-wrong-state
               refuse-wrong-state refuse-wrong-state refuse-wrong-state
               (set-state active) (children purge) refuse-wrong-state (parent move-children)
               X X X)
     (purged   X X X X X X X X X X X X X X X))
    (differ
     (#f       refuse-412 refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               refuse-412 refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               X X X)
     (active   refuse-412 refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               refuse-412 refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               X X X)
     (archived refuse-412 refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               refuse-412 refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               X X X)
     (trashed  refuse-412 refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               refuse-412 refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               X X X)
     (purged   refuse-412 refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               refuse-412 refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               X X X))))

;; expected-command : Found (U Symbol #f) Symbol Symbol Boolean -> Any
;; The table's entry for the cell, with the verdict V and the children C, as
;; commanded answers it; a cell the table lacks expects what node-command
;; never answers.
(define (expected-command f s e v c)
  (let* ((rows (cond ((assq f node-command-table) => cdr) (else '())))
         (row (assq s rows))
         (tail (memq e request-events))
         (entries (and row (cdr row))))
    (if (and entries tail (= (length entries) (length request-events)))
        (let ((entry (list-ref entries (- (length request-events) (length tail)))))
          (cond ((eq? entry 'X) 'cannot-happen)
                ((symbol? entry) (list entry #f))
                ((eq? (car entry) 'parent)
                 (let ((answer (cdr (assq v verdict-answers))))
                   (list (if (eq? answer 'go) (cadr entry) answer) #f)))
                ((eq? (car entry) 'children)
                 (list (if c 'refuse-has-children (cadr entry)) #f))
                (else entry)))
        'missing-from-the-suites-table)))

;; commanded : Any Any Any Any Any -> (U (List Symbol (U Symbol #f)) 'cannot-happen (List 'raised String))
;; The command and the state to store; 'cannot-happen for an assertion
;; violation from node-command whose irritants are the whole cell, the
;; Found, the state, the event, the verdict and the children; any other
;; raise as itself.
(define (commanded f s e v c)
  (guard (x ((and (assertion-violation? x)
                  (who-condition? x) (eq? (condition-who x) 'node-command)
                  (irritants-condition? x) (equal? (condition-irritants x) (list f s e v c)))
             'cannot-happen)
            (#t (list 'raised (describe x))))
    (call-with-values (lambda () (node-command f s e v c)) list)))

;; Every one of the 2,700 cells, by construction: 3 Founds, 5 states, 15
;; events, 6 verdicts, and with children or without.
(for-each
 (lambda (f)
   (for-each
    (lambda (s)
      (for-each
       (lambda (e)
         (for-each
          (lambda (v)
            (for-each
             (lambda (c)
               (test-equal (string-append "command: " (written f) ", " (written s) ", " (written e)
                                          ", " (written v) ", " (written c))
                 (expected-command f s e v c)
                 (commanded f s e v c)))
             '(#f #t)))
          verdicts))
       request-events))
    request-states))
 '(none match differ))

(test-equal "command: the fourteen commands it answers, in the order the cells first give them"
  '(insert refuse-invalid-parent refuse-would-loop refuse-404 write refuse-409 copy set-state
    refuse-wrong-state move move-children purge refuse-has-children refuse-412)
  (attempt
   (lambda ()
     (fold-left
      (lambda (acc f)
        (fold-left
         (lambda (acc s)
           (fold-left
            (lambda (acc e)
              (fold-left
               (lambda (acc v)
                 (fold-left
                  (lambda (acc c)
                    (let ((a (commanded f s e v c)))
                      (if (and (pair? a) (symbol? (car a)) (not (eq? (car a) 'raised))
                               (not (memq (car a) acc)))
                          (append acc (list (car a)))
                          acc)))
                  acc '(#f #t)))
               acc verdicts))
            acc request-events))
         acc request-states))
      '() '(none match differ)))))

(test-equal "command: an event no request sends raises, whatever was found"
  '(cannot-happen cannot-happen cannot-happen cannot-happen cannot-happen cannot-happen
    cannot-happen)
  (list (commanded 'none #f 'write 'ok #f) (commanded 'match 'active 'write 'ok #f)
        (commanded 'differ 'active 'write 'ok #f) (commanded 'none #f 'delete 'ok #f)
        (commanded 'match 'active 'delete 'ok #f) (commanded 'differ 'trashed 'delete 'ok #f)
        (commanded 'match 'active 'move-child 'ok #f)))

(test-equal "command: a Found the write machine has not raises"
  '(cannot-happen cannot-happen)
  (list (commanded 'gone 'active 'replace 'ok #f) (commanded #f 'active 'archive 'ok #f)))

(test-equal "command: with match the state must be a live one; with none and differ it is not looked at"
  '(cannot-happen cannot-happen (refuse-412 #f) (refuse-412 #f) (insert #f) (refuse-404 #f))
  (list (commanded 'match 'gone 'replace 'ok #f) (commanded 'match "active" 'archive 'ok #f)
        (commanded 'differ 'gone 'replace 'ok #f) (commanded 'differ "trashed" 'untrash 'ok #f)
        (commanded 'none 'gone 'create 'ok #f) (commanded 'none "active" 'archive 'ok #f)))

;; raised-as : (-> Any) -> (U (List String (Listof Any)) 'no-raise (List 'raised String))
;; An assertion violation from node-command as its message and irritants;
;; 'no-raise when nothing was raised; any other raise as itself.
(define (raised-as thunk)
  (guard (x ((and (assertion-violation? x)
                  (who-condition? x) (eq? (condition-who x) 'node-command)
                  (message-condition? x) (irritants-condition? x))
             (list (condition-message x) (condition-irritants x)))
            (#t (list 'raised (describe x))))
    (thunk)
    'no-raise))

(test-equal "command: a verdict that is none of the six raises where it is looked at"
  '(("not a verdict on a parent" (fine)) ("not a verdict on a parent" (fine))
    ("not a verdict on a parent" (fine)) ("not a verdict on a parent" (#f))
    ("not a verdict on a parent" ("ok")))
  (list (raised-as (lambda () (node-command 'none #f 'create 'fine #f)))
        (raised-as (lambda () (node-command 'match 'active 'move 'fine #f)))
        (raised-as (lambda () (node-command 'match 'trashed 'move-children 'fine #f)))
        (raised-as (lambda () (node-command 'match 'archived 'move #f #f)))
        (raised-as (lambda () (node-command 'none #f 'create "ok" #f)))))

(test-equal "command: where the verdict is not looked at, any value is ignored"
  '((refuse-wrong-state #f) (refuse-412 #f) (refuse-412 #f) (write #f) (refuse-404 #f)
    (refuse-404 #f) (set-state archived) (purge #f))
  (list (commanded 'match 'trashed 'move 'fine #f)
        (commanded 'differ 'active 'create 'fine #f)
        (commanded 'differ 'active 'move 'fine #f)
        (commanded 'match 'active 'replace 'fine #f)
        (commanded 'none #f 'move 'fine #f)
        (commanded 'none #f 'replace 'fine #f)
        (commanded 'match 'active 'archive 'fine #f)
        (commanded 'match 'trashed 'purge 'fine #f)))

(test-equal "command: whether the node has children must be a boolean where it is looked at: 0 is not #f"
  '(("whether the node has children is a boolean" (0))
    ("whether the node has children is a boolean" (())))
  (list (raised-as (lambda () (node-command 'match 'trashed 'purge 'ok 0)))
        (raised-as (lambda () (node-command 'match 'trashed 'purge 'ok '())))))

(test-equal "command: where the children are not looked at, any value is ignored"
  '((refuse-wrong-state #f) (refuse-404 #f) (refuse-412 #f) (move #f) (move-children #f)
    (insert #f))
  (list (commanded 'match 'active 'purge 'ok 0)
        (commanded 'none #f 'purge 'ok 0)
        (commanded 'differ 'trashed 'purge 'ok 0)
        (commanded 'match 'active 'move 'ok 0)
        (commanded 'match 'trashed 'move-children 'ok 0)
        (commanded 'none #f 'create 'ok 0)))

;;; The states and the events, as the store and the feed name them

(test-equal "states: the four, in the table's order"
  '(active archived trashed purged)
  (attempt (lambda () node-states)))

(test-equal "state->string: each state's name"
  '("active" "archived" "trashed" "purged")
  (attempt (lambda () (map node-state->string '(active archived trashed purged)))))

(test-equal "string->state: each name's state"
  '(active archived trashed purged)
  (attempt (lambda () (map string->node-state '("active" "archived" "trashed" "purged")))))

(test-equal "state: a round trip through the string is the state"
  '(active archived trashed purged)
  (attempt (lambda () (map (lambda (s) (string->node-state (node-state->string s)))
                           node-states))))

(test-equal "state->string: what is no state raises"
  '(assertion assertion assertion assertion)
  (map (lambda (x) (raised-kind (lambda () (node-state->string x))))
       (list 'gone "active" #f 'Active)))

(test-equal "string->state: what is no state's name raises"
  '(assertion assertion assertion assertion assertion assertion)
  (map (lambda (x) (raised-kind (lambda () (string->node-state x))))
       (list "gone" "Active" "" " active" 'active #f)))

(test-equal "?state=: none given is active; each listable state is itself"
  '(active active archived trashed)
  (attempt (lambda () (map parse-state-param (list #f "active" "archived" "trashed")))))

(for-each
 (lambda (x)
   (test-equal (string-append "?state=: refused, " (written x))
     'invalid
     (attempt (lambda () (parse-state-param x)))))
 (list "purged" "" "Active" "ARCHIVED" "Trashed" " active" "active " "trash" "archive"
       "deleted" "active,archived" 7 'active))

(test-equal "events: the five a state change sends, in the table's order; no link among them"
  '(archive unarchive trash untrash purge)
  (attempt (lambda () lifecycle-events)))

(test-equal "link-events: the two a link's request sends, in the table's order"
  '(link unlink)
  (attempt (lambda () link-events)))

(test-equal "link-events: neither is node-command's: each cannot happen, whatever was found"
  '((cannot-happen cannot-happen cannot-happen cannot-happen)
    (cannot-happen cannot-happen cannot-happen cannot-happen))
  (attempt (lambda ()
             (map (lambda (e)
                    (list (commanded 'none #f e 'ok #f) (commanded 'match 'active e 'ok #f)
                          (commanded 'match 'trashed e 'ok #f) (commanded 'differ 'active e 'ok #f)))
                  link-events))))

(test-equal "tag-events: the one a tag's rename or removal sends to each node it steps"
  '(retag)
  (attempt (lambda () tag-events)))

(test-equal "tag-events: retag is not node-command's: it cannot happen, whatever was found"
  '((cannot-happen cannot-happen cannot-happen cannot-happen cannot-happen))
  (attempt (lambda ()
             (map (lambda (e)
                    (list (commanded 'none #f e 'ok #f) (commanded 'match 'active e 'ok #f)
                          (commanded 'match 'archived e 'ok #f) (commanded 'match 'trashed e 'ok #f)
                          (commanded 'differ 'active e 'ok #f)))
                  tag-events))))

(test-equal "retag-states: every live state, in the table's order"
  '(active archived trashed)
  (attempt (lambda () retag-states)))

(test-equal "retag-states: exactly the states whose retag the table allows"
  (attempt (lambda ()
             (filter (lambda (s) (let-values (((next command) (lifecycle-step s 'retag)))
                                   (and (eq? command 'allow) (eq? next s))))
                     '(active archived trashed))))
  (attempt (lambda () retag-states)))

(test-equal "event-op: each event's op in the feed is its own name, a move's is move, a link's link and unlink"
  '("archive" "unarchive" "trash" "untrash" "purge" "move" "link" "unlink")
  (attempt (lambda () (map event-op '(archive unarchive trash untrash purge move link unlink)))))

(test-equal "event-op: a write's events, the table's write, a bulk move, retag and what is no event raise"
  '(assertion assertion assertion assertion assertion assertion assertion assertion assertion)
  (map (lambda (x) (raised-kind (lambda () (event-op x))))
       (list 'create 'replace 'write 'move-children 'retag "archive" #f "link" 'keep)))

;;; The diagram, held to its file

(test-equal ".plans/machines/write.md is what the table renders"
  (attempt (lambda () (write-document)))
  (read-file ".plans/machines/write.md"))

(test-equal "the document shows the diagram and every cell's command"
  '(#t #t #t #t #t #t)
  (let ((doc (attempt (lambda () (write-document)))))
    (map (lambda (needle) (and (string? doc) (string-index-of doc needle) #t))
         (list "stateDiagram-v2"
               "none --> differ: create"
               "| Found | create | replace | replace-other-kind | restore | restore-unknown |"
               "| none | insert | refuse-404 | cannot happen | cannot happen | refuse-404 |"
               "| match | cannot happen | write | refuse-409 | copy | refuse-404 |"
               "| differ | refuse-412 | refuse-412 | refuse-412 | refuse-412 | refuse-412 |"))))

(test-equal "the document gives each can't-happen pair its reason"
  '(#t #t #t)
  (attempt
   (lambda ()
     (let ((doc (write-document)))
       (map (lambda (c)
              (and (string-index-of doc (string-append "| " (symbol->string (car c))
                                                       " | " (symbol->string (cadr c))
                                                       " | " (caddr c) " |"))
                   #t))
            write-cant-happen)))))

(test-equal ".plans/machines/lifecycle.md is what the table renders"
  (attempt (lambda () (lifecycle-document)))
  (read-file ".plans/machines/lifecycle.md"))

(test-equal "the lifecycle document shows the diagram and every cell's answer"
  '(#t #t #t #t #t #t #t #t #t #t #t #t #t #t #t #t)
  (let ((doc (attempt (lambda () (lifecycle-document)))))
    (map (lambda (needle) (and (string? doc) (string-index-of doc needle) #t))
         (list "stateDiagram-v2"
               "trashed --> purged: purge"
               "active --> active: unarchive, untrash, purge, write, move, move-children, link, unlink, retag\n"
               "archived --> archived: archive, untrash, purge, write, move, move-children, link, unlink, retag\n"
               "trashed --> trashed: archive, unarchive, trash, write, move, move-children, link, unlink, retag\n"
               "| State | archive | unarchive | trash | untrash | purge | write | move | move-children | link | unlink | retag |\n"
               "| active | -> archived, set-state | refuse-wrong-state | -> trashed, set-state | refuse-wrong-state | refuse-wrong-state | allow | allow | allow | allow | allow | allow |\n"
               "| archived | refuse-wrong-state | -> active, set-state | -> trashed, set-state | refuse-wrong-state | refuse-wrong-state | allow | allow | allow | allow | allow | allow |\n"
               "| trashed | refuse-wrong-state | refuse-wrong-state | refuse-wrong-state | -> active, set-state | -> purged, purge | refuse-wrong-state | refuse-wrong-state | allow | refuse-wrong-state | allow | allow |\n"
               "| purged | cannot happen | cannot happen | cannot happen | cannot happen | cannot happen | cannot happen | cannot happen | cannot happen | cannot happen | cannot happen | cannot happen |\n"
               "`node-command`"
               "`link-command` in `(techo links)`"
               "`write` is a replace, a revision's restore or a Task's transition"
               "`task-command` in `(techo tasks)`"
               "`retag` is a step of a tag's rename or removal"
               "`retag-states`"))))

(test-equal "the lifecycle document gives each verdict its answer"
  '(#t #t #t #t #t #t #t)
  (let ((doc (attempt (lambda () (lifecycle-document)))))
    (map (lambda (needle) (and (string? doc) (string-index-of doc needle) #t))
         (list "| Verdict | Answer |"
               "| ok | the request's own: insert, move or move-children |"
               "| missing | refuse-invalid-parent |"
               "| trashed | refuse-invalid-parent |"
               "| loop | refuse-would-loop |"
               "| wrong-kind | refuse-invalid-parent |"
               "| too-deep | refuse-invalid-parent |"))))

(test-equal "the lifecycle document gives each can't-happen pair its reason"
  '(#t #t #t #t #t #t #t #t #t #t #t)
  (attempt
   (lambda ()
     (let ((doc (lifecycle-document)))
       (map (lambda (c)
              (and (string-index-of doc (string-append "| " (symbol->string (car c))
                                                       " | " (symbol->string (cadr c))
                                                       " | " (caddr c) " |"))
                   #t))
            lifecycle-cant-happen)))))

(test-end "nodes")

(exit (suite-exit-status runner))
