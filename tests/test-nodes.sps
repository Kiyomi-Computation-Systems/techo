#!r6rs
;;; The nodes suite: slice 4's pure core, (techo nodes). All pure.
;;;
;;;   the constants     the five kinds and the three caps (D6, D7)
;;;   ids               a node's id is a UUID of version 7, RFC variant (D2, H10)
;;;   revisions         a path's revision, and the ETag (D4)
;;;   preconditions     If-Match and If-None-Match, exactly as D4 takes them (H9)
;;;   content           the body's members, types and limits (D6, D7, H8)
;;;   the linear rule   a request at the cap, whatever its members, is quick (H13)
;;;   the table         D5's table, checked exhaustively, every cell stepped (H7)
;;;   the lifecycle     slice 4b's table, checked exhaustively, every cell stepped (G1)
;;;   node-command      the two tables answer one request, every cell (G5, G15)
;;;   states and events the store's names, ?state= and the feed's ops
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

(test-equal "content: a create"
  '("note" "A title" "Some text" "text/plain" "{}")
  (parsed good #t))

(test-equal "content: the members in another order"
  '("note" "A title" "Some text" "text/plain" "{}")
  (parsed (reverse good) #t))

(test-equal "content: props given as {}"
  '("note" "A title" "Some text" "text/plain" "{}")
  (parsed (with "props" '() good) #t))

(test-equal "content: a replace with no kind"
  '(#f "A title" "Some text" "text/plain" "{}")
  (parsed (without "kind" good) #f))

(test-equal "content: a replace that names a kind keeps it"
  '("task" "A title" "Some text" "text/plain" "{}")
  (parsed (with "kind" "task" good) #f))

(test-equal "content: each of the five kinds"
  '("project" "journal" "note" "task" "contact")
  (attempt (lambda ()
             (map (lambda (k) (content-kind (parse-content (with "kind" k good) #t)))
                  '("project" "journal" "note" "task" "contact")))))

(test-equal "content: an empty title and an empty body"
  '("note" "" "" "text/plain" "{}")
  (parsed (with "body" "" (with "title" "" good)) #t))

(test-equal "content: a body may hold any character but U+0000"
  (list "note" "A title" (string (integer->char 1) #\tab #\newline (integer->char #x1F600))
        "text/plain" "{}")
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
  ;; props
  (list "props {\"a\":1}" (with "props" '(("a" . 1)) good) #t)
  (list "props []" (with "props" (vector) good) #t)
  (list "props a string" (with "props" "{}" good) #t)
  (list "props null" (with "props" 'null good) #t)
  (list "props false" (with "props" #f good) #t)
  ;; U+0000
  (list "U+0000 in the title" (with "title" (string #\a (integer->char 0) #\b) good) #t)
  (list "U+0000 alone as the title" (with "title" (string (integer->char 0)) good) #t)
  (list "U+0000 in the body" (with "body" (string #\a (integer->char 0) #\b) good) #t)
  (list "U+0000 at the body's end" (with "body" (string #\a (integer->char 0)) good) #t)))

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
               (with "body" big (with "props" '(("a" . 1)) good))
               (with "body" (string-append big (string (integer->char 0))) good)))))

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

(define fuzz-names '("kind" "title" "body" "content_type" "props" "id" "revision" "Title" ""))
(define fuzz-strings
  (list "" "note" "task" "Note" "text/plain" "/" "plain" (string #\a (integer->char 0)) "x"
        (make-string 1001 #\t)))

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
(define (fits? x c)
  (let ((given (lambda (name) (let ((m (assoc name x))) (and m (cdr m))))))
    (and (equal? (content-title c) (given "title"))
         (equal? (content-body c) (given "body"))
         (equal? (content-content-type c) (given "content_type"))
         (equal? (content-kind c) (given "kind"))
         (equal? (content-props c) "{}"))))

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

(test-equal "linear: the five known members, then 199,995 repeats of title"
  '(invalid quick)
  (timed (lambda () (members 199995 (lambda (i) (cons "title" "t"))
                             (append good '(("props"))))) #t))

(test-equal "linear: a body of the request's cap, 2 MiB of ASCII, too large at once"
  '(too-large quick)
  (timed (lambda () (with "body" (make-string 2097152 #\b) good)) #t))

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
(define life-events '(archive unarchive trash untrash purge write))

;; The table the owner approved, written out here, not read from
;; lifecycle-rows: (state event next command) for a row, (state event) for a
;; cell that cannot happen. In the table's order.
(define lifecycle-table
  '((active archive archived set-state)
    (active unarchive active refuse-wrong-state)
    (active trash trashed set-state)
    (active untrash active refuse-wrong-state)
    (active purge active refuse-wrong-state)
    (active write active allow)
    (archived archive archived refuse-wrong-state)
    (archived unarchive active set-state)
    (archived trash trashed set-state)
    (archived untrash archived refuse-wrong-state)
    (archived purge archived refuse-wrong-state)
    (archived write archived allow)
    (trashed archive trashed refuse-wrong-state)
    (trashed unarchive trashed refuse-wrong-state)
    (trashed trash trashed refuse-wrong-state)
    (trashed untrash active set-state)
    (trashed purge purged purge)
    (trashed write trashed refuse-wrong-state)
    (purged archive)
    (purged unarchive)
    (purged trash)
    (purged untrash)
    (purged purge)
    (purged write)))

(define (lifecycle-problems rows)
  (attempt (lambda () (machine-problems (make-machine rows) '(active) '(purged)
                                        lifecycle-cant-happen))))

(test-equal "lifecycle: machine-problems, start active and end purged, answers ()"
  '()
  (lifecycle-problems lifecycle-rows))

(test-equal "lifecycle: eighteen rows"
  18
  (attempt (lambda () (length lifecycle-rows))))

(test-equal "lifecycle: the rows are exactly the table's, in its order"
  (filter (lambda (c) (= (length c) 4)) lifecycle-table)
  (attempt (lambda () (map (lambda (r) (list (car r) (cadr r) (caddr r) (cadddr r)))
                           lifecycle-rows))))

(test-equal "lifecycle: the can't-happen pairs are purged's six, in the table's order"
  (filter (lambda (c) (= (length c) 2)) lifecycle-table)
  (attempt (lambda () (map (lambda (c) (list (car c) (cadr c))) lifecycle-cant-happen))))

(test-equal "lifecycle: every can't-happen pair has a reason, a non-empty string"
  '(#t #t #t #t #t #t)
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

;; Every one of the 24 cells, by construction: a cell the table above lacks
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

;;; node-command: the two tables answer one request (slice 4b, G5, G15)

(define request-events '(create replace replace-other-kind restore restore-unknown
                         archive unarchive trash untrash purge))
(define request-states '(#f active archived trashed purged))

;; What node-command answers, written out: under each Found, a row per state
;; in request-states' order, an entry per event in request-events' order. X is
;; an assertion violation (the cell cannot happen); a symbol is that command
;; and #f; (set-state S) is set-state and the state S to store.
(define node-command-table
  '((none
     (#f       insert refuse-404 X X refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404)
     (active   insert refuse-404 X X refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404)
     (archived insert refuse-404 X X refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404)
     (trashed  insert refuse-404 X X refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404)
     (purged   insert refuse-404 X X refuse-404 refuse-404 refuse-404 refuse-404 refuse-404 refuse-404))
    (match
     (#f       X X X X X X X X X X)
     (active   X write refuse-409 copy refuse-404
               (set-state archived) refuse-wrong-state (set-state trashed)
               refuse-wrong-state refuse-wrong-state)
     (archived X write refuse-409 copy refuse-404
               refuse-wrong-state (set-state active) (set-state trashed)
               refuse-wrong-state refuse-wrong-state)
     (trashed  X refuse-wrong-state refuse-wrong-state refuse-wrong-state refuse-wrong-state
               refuse-wrong-state refuse-wrong-state refuse-wrong-state
               (set-state active) purge)
     (purged   X X X X X X X X X X))
    (differ
     (#f       refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               refuse-412 refuse-412 refuse-412 refuse-412 refuse-412)
     (active   refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               refuse-412 refuse-412 refuse-412 refuse-412 refuse-412)
     (archived refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               refuse-412 refuse-412 refuse-412 refuse-412 refuse-412)
     (trashed  refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               refuse-412 refuse-412 refuse-412 refuse-412 refuse-412)
     (purged   refuse-412 refuse-412 refuse-412 refuse-412 refuse-412
               refuse-412 refuse-412 refuse-412 refuse-412 refuse-412))))

;; expected-command : Found (U Symbol #f) Symbol -> Any
;; The table's entry for the cell, as commanded answers it; a cell the table
;; lacks expects what node-command never answers.
(define (expected-command f s e)
  (let* ((rows (cond ((assq f node-command-table) => cdr) (else '())))
         (row (assq s rows))
         (tail (memq e request-events))
         (entries (and row (cdr row))))
    (if (and entries tail (= (length entries) (length request-events)))
        (let ((entry (list-ref entries (- (length request-events) (length tail)))))
          (cond ((eq? entry 'X) 'cannot-happen)
                ((symbol? entry) (list entry #f))
                (else entry)))
        'missing-from-the-suites-table)))

;; commanded : Any Any Any -> (U (List Symbol (U Symbol #f)) 'cannot-happen (List 'raised String))
;; The command and the state to store; 'cannot-happen for an assertion
;; violation from node-command whose irritants are the cell, the Found, the
;; state and the event; any other raise as itself.
(define (commanded f s e)
  (guard (x ((and (assertion-violation? x)
                  (who-condition? x) (eq? (condition-who x) 'node-command)
                  (irritants-condition? x) (equal? (condition-irritants x) (list f s e)))
             'cannot-happen)
            (#t (list 'raised (describe x))))
    (call-with-values (lambda () (node-command f s e)) list)))

;; Every one of the 150 cells, by construction.
(for-each
 (lambda (f)
   (for-each
    (lambda (s)
      (for-each
       (lambda (e)
         (test-equal (string-append "command: " (written f) ", " (written s) ", " (written e))
           (expected-command f s e)
           (commanded f s e)))
       request-events))
    request-states))
 '(none match differ))

(test-equal "command: the nine commands it answers, in the order the cells first give them"
  '(insert refuse-404 write refuse-409 copy set-state refuse-wrong-state purge refuse-412)
  (attempt
   (lambda ()
     (fold-left
      (lambda (acc f)
        (fold-left
         (lambda (acc s)
           (fold-left
            (lambda (acc e)
              (let ((a (commanded f s e)))
                (if (and (pair? a) (symbol? (car a)) (not (eq? (car a) 'raised))
                         (not (memq (car a) acc)))
                    (append acc (list (car a)))
                    acc)))
            acc request-events))
         acc request-states))
      '() '(none match differ)))))

(test-equal "command: an event no request sends raises, whatever was found"
  '(cannot-happen cannot-happen cannot-happen cannot-happen cannot-happen cannot-happen)
  (list (commanded 'none #f 'write) (commanded 'match 'active 'write)
        (commanded 'differ 'active 'write) (commanded 'none #f 'delete)
        (commanded 'match 'active 'delete) (commanded 'differ 'trashed 'delete)))

(test-equal "command: a Found the write machine has not raises"
  '(cannot-happen cannot-happen)
  (list (commanded 'gone 'active 'replace) (commanded #f 'active 'archive)))

(test-equal "command: with match the state must be a live one; with none and differ it is not looked at"
  '(cannot-happen cannot-happen (refuse-412 #f) (refuse-412 #f) (insert #f) (refuse-404 #f))
  (list (commanded 'match 'gone 'replace) (commanded 'match "active" 'archive)
        (commanded 'differ 'gone 'replace) (commanded 'differ "trashed" 'untrash)
        (commanded 'none 'gone 'create) (commanded 'none "active" 'archive)))

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

(test-equal "events: the five a state change sends, in the table's order"
  '(archive unarchive trash untrash purge)
  (attempt (lambda () lifecycle-events)))

(test-equal "event-op: each event's op in the feed is its own name"
  '("archive" "unarchive" "trash" "untrash" "purge")
  (attempt (lambda () (map event-op '(archive unarchive trash untrash purge)))))

(test-equal "event-op: a write's events, the table's write and what is no event raise"
  '(assertion assertion assertion assertion assertion)
  (map (lambda (x) (raised-kind (lambda () (event-op x))))
       (list 'create 'replace 'write "archive" #f)))

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
  '(#t #t #t #t #t #t #t #t)
  (let ((doc (attempt (lambda () (lifecycle-document)))))
    (map (lambda (needle) (and (string? doc) (string-index-of doc needle) #t))
         (list "stateDiagram-v2"
               "trashed --> purged: purge"
               "| State | archive | unarchive | trash | untrash | purge | write |"
               "| active | -> archived, set-state | refuse-wrong-state | -> trashed, set-state | refuse-wrong-state | refuse-wrong-state | allow |"
               "| archived | refuse-wrong-state | -> active, set-state | -> trashed, set-state | refuse-wrong-state | refuse-wrong-state | allow |"
               "| trashed | refuse-wrong-state | refuse-wrong-state | refuse-wrong-state | -> active, set-state | -> purged, purge | refuse-wrong-state |"
               "| purged | cannot happen | cannot happen | cannot happen | cannot happen | cannot happen | cannot happen |"
               "`node-command`"))))

(test-equal "the lifecycle document gives each can't-happen pair its reason"
  '(#t #t #t #t #t #t)
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
