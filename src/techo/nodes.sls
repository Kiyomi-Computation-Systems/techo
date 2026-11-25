#!r6rs
;;; (techo nodes): slice 4's pure core. A node's id (D2); a revision, in a
;;; path and as the ETag (D4); If-Match and If-None-Match (D4); the content
;;; a write carries, and its limits (D6, D7); and the versioned write as a
;;; table (D5). Pure: no database, no circuit, no clock (ADR-0007).
;;;
;;; The table is over what a write's job found: none (no node, or another
;;; account's), match (the node, at the revision given) and differ (the node
;;; at another revision, or a create's id in use). A state here has no data,
;;; so write-step takes and answers kinds. Every Found is a start, and no
;;; state is an end.
;;;
;;; Nothing here raises with a title or a body: parse-content never raises,
;;; and every other raise carries a symbol or a number at most.
(library (techo nodes)
  (export node-kinds body-cap request-cap title-cap
          parse-node-id node-id->string parse-revision etag precondition
          content? content-kind content-title content-body content-content-type content-props
          parse-content
          found found-for-create write-event
          write-rows write-cant-happen write-step write-document)
  (import (rnrs)
          (techo machine)
          (only (unique-id) string->uuid uuid-version uuid->bytevector bytevector->uuid
                uuid->string))

  ;;; The constants (D6, D7)

  ;; node-kinds : (Listof String)
  ;; The five kinds, lower case. A node's kind is one of them, fixed at create.
  (define node-kinds '("project" "journal" "note" "task" "contact"))

  ;; body-cap : Natural
  ;; A body's limit, in bytes of UTF-8: 1 MiB.
  (define body-cap 1048576)

  ;; request-cap : Natural
  ;; A write's JSON's limit, in bytes, for wrap-json-body: 2 MiB.
  (define request-cap 2097152)

  ;; title-cap : Natural
  ;; A title's limit, in characters.
  (define title-cap 1000)

  ;;; Ids (D2)

  ;; parse-node-id : Any -> (U Bytevector 'invalid)
  ;; A fresh 16 bytes for a string that unique-id reads as a UUID, in either
  ;; case, of version 7. uuid-version answers #f for any variant but RFC
  ;; 9562's, so the variant is checked too. 'invalid for anything else.
  ;; Never raises.
  (define (parse-node-id x)
    (let ((u (and (string? x) (string->uuid x))))
      (if (and u (eqv? (uuid-version u) 7))
          (uuid->bytevector u)
          'invalid)))

  ;; node-id->string : Bytevector -> String
  ;; The id's canonical text, lower case, 36 characters. An assertion
  ;; violation for what is no 16-byte bytevector.
  (define (node-id->string bytes)
    (uuid->string (bytevector->uuid bytes)))

  ;;; Revisions and the ETag (D4)

  ;; 2^53, the largest revision, and its digits: no longer string can be one.
  (define max-revision 9007199254740992)
  (define max-revision-digits 16)

  (define (digit? c) (and (char<=? #\0 c) (char<=? c #\9)))

  ;; parse-revision : Any -> (U Natural 'invalid)
  ;; A string of ASCII decimal digits with no sign and no leading zero, worth
  ;; 1 to 2^53, as that number. 'invalid for anything else. A string longer
  ;; than 2^53's 16 digits is refused before it is read. Never raises.
  (define (parse-revision x)
    (if (and (string? x)
             (<= 1 (string-length x) max-revision-digits)
             (not (char=? (string-ref x 0) #\0))
             (for-all digit? (string->list x)))
        (let ((n (fold-left (lambda (acc c) (+ (* acc 10) (- (char->integer c) 48)))
                            0 (string->list x))))
          (if (<= n max-revision) n 'invalid))
        'invalid))

  ;; etag : Natural -> String
  ;; The strong entity tag of revision N: its digits in double quotes, so 7
  ;; is the three characters "7". An assertion violation for anything but an
  ;; exact natural number.
  (define (etag n)
    (unless (and (integer? n) (exact? n) (>= n 0))
      (assertion-violation 'etag "a revision is a natural number" n))
    (string-append "\"" (number->string n) "\""))

  ;;; If-Match and If-None-Match (D4)

  ;; ows? : Char -> Boolean     HTTP's optional white space: a space or a tab
  (define (ows? c) (or (char=? c #\space) (char=? c #\tab)))

  ;; trim : String -> String     S without the spaces and tabs at either end
  (define (trim s)
    (let* ((n (string-length s))
           (start (let loop ((i 0))
                    (if (and (< i n) (ows? (string-ref s i))) (loop (+ i 1)) i)))
           (end (let loop ((j n))
                  (if (and (> j start) (ows? (string-ref s (- j 1)))) (loop (- j 1)) j))))
      (substring s start end)))

  (define (strings? x) (and (list? x) (for-all string? x)))
  (define (one? x) (and (pair? x) (null? (cdr x))))

  ;; strong-tag : String -> (U Natural 'invalid)
  ;; "N" as N, by parse-revision: nothing inside the quotes but the digits.
  (define (strong-tag s)
    (let ((n (string-length s)))
      (if (and (>= n 2) (char=? (string-ref s 0) #\") (char=? (string-ref s (- n 1)) #\"))
          (parse-revision (substring s 1 (- n 1)))
          'invalid)))

  ;; Precondition = (U 'create Natural)
  ;; precondition : (Listof String) (Listof String) -> (U Precondition 'missing 'invalid)
  ;; From every If-Match field value and every If-None-Match field value, as
  ;; circuit's req-header-values gives them: each field whole. Neither header
  ;; is 'missing. One If-None-Match field of exactly `*`, and no If-Match, is
  ;; 'create. One If-Match field of exactly one strong tag "N", and no
  ;; If-None-Match, is N. Spaces and tabs around a field's value are allowed.
  ;; Anything else is 'invalid: both headers, a field given twice, `*` in
  ;; If-Match, a list, a weak tag, a space inside the quotes, a tag in
  ;; If-None-Match, an empty field, what is no list of strings. Never raises.
  (define (precondition if-match if-none-match)
    (cond ((not (and (strings? if-match) (strings? if-none-match))) 'invalid)
          ((and (null? if-match) (null? if-none-match)) 'missing)
          ((and (null? if-match) (one? if-none-match))
           (if (string=? (trim (car if-none-match)) "*") 'create 'invalid))
          ((and (null? if-none-match) (one? if-match))
           (strong-tag (trim (car if-match))))
          (else 'invalid)))

  ;;; The content a write carries (D6, D7)

  ;; Content: what a create or a replace writes.
  ;; content? : Any -> Boolean
  ;; content-kind : Content -> (U String #f)    #f for a replace that gave none
  ;; content-title : Content -> String
  ;; content-body : Content -> String
  ;; content-content-type : Content -> String
  ;; content-props : Content -> String          the text "{}", until slice 6
  (define-record-type content
    (fields kind title body content-type props))

  (define member-names '("kind" "title" "body" "content_type" "props"))
  (define content-type-cap 255)

  ;; at-most? : Any Natural -> Boolean
  ;; Whether X is a proper list of at most N elements. It walks at most N + 1
  ;; pairs, however long X is: the review's blocker 2.
  (define (at-most? x n)
    (cond ((null? x) #t)
          ((and (pair? x) (> n 0)) (at-most? (cdr x) (- n 1)))
          (else #f)))

  ;; known-member? : Any -> Boolean     a (name . value) pair, its name one of the five
  (define (known-member? m)
    (and (pair? m) (string? (car m)) (member (car m) member-names) #t))

  ;; distinct? : (Listof String) -> Boolean     no name twice; at most five here
  (define (distinct? names)
    (or (null? names)
        (and (not (member (car names) (cdr names))) (distinct? (cdr names)))))

  ;; absent : what value-of answers for a member not given: no JSON value is it
  (define absent (list 'absent))

  (define (value-of x name)
    (let ((m (assoc name x)))
      (if m (cdr m) absent)))

  ;; has-nul? : String -> Boolean
  (define (has-nul? s)
    (let ((n (string-length s)))
      (let loop ((i 0))
        (and (< i n)
             (or (char=? (string-ref s i) #\nul) (loop (+ i 1)))))))

  ;; content-type-ok? : String -> Boolean
  ;; 1 to 255 characters, each U+0020 to U+007E, at least one of them `/`.
  (define (content-type-ok? s)
    (let ((n (string-length s)))
      (and (<= 1 n content-type-cap)
           (let loop ((i 0) (slash? #f))
             (if (= i n)
                 slash?
                 (let ((c (char->integer (string-ref s i))))
                   (and (<= #x20 c #x7e)
                        (loop (+ i 1) (or slash? (= c #x2f))))))))))

  ;; utf8-width : Natural -> Natural     the bytes of UTF-8 a code point takes
  (define (utf8-width c)
    (cond ((< c #x80) 1) ((< c #x800) 2) ((< c #x10000) 3) (else 4)))

  ;; scan-body : String -> (values Natural Boolean)
  ;; The body's length in bytes of UTF-8, counted up to any U+0000, and
  ;; whether it holds one. One pass; no copy.
  (define (scan-body s)
    (let ((n (string-length s)))
      (let loop ((i 0) (bytes 0))
        (if (= i n)
            (values bytes #f)
            (let ((c (char->integer (string-ref s i))))
              (if (= c 0)
                  (values bytes #t)
                  (loop (+ i 1) (+ bytes (utf8-width c)))))))))

  ;; parse-content : Any Boolean -> (U Content 'invalid 'too-large)
  ;; From req-json's value (an object is an alist of (String . value), a
  ;; name given twice kept; {} is '()), and whether this is a create. The
  ;; members are kind, title, body, content_type and props. title, body and
  ;; content_type are required strings; kind is required on a create and
  ;; optional otherwise, one of node-kinds; props is optional and must be an
  ;; empty object. 'invalid for what is no object, a sixth member, a member
  ;; not of the five, a name twice, a member missing or of the wrong type, a
  ;; title over title-cap characters, U+0000 in the title or the body, or a
  ;; content_type that content-type-ok? refuses. 'too-large only for a body
  ;; over body-cap bytes of UTF-8, when all else is right.
  ;; Never raises. Its work is bounded by its members' lengths: a list longer
  ;; than five is refused before any name is compared, and a title or a
  ;; content type over its limit before it is read.
  (define (parse-content x create?)
    (if (and (at-most? x (length member-names))
             (for-all known-member? x)
             (distinct? (map car x)))
        (let ((kind (value-of x "kind"))
              (title (value-of x "title"))
              (body (value-of x "body"))
              (type (value-of x "content_type"))
              (props (value-of x "props")))
          (cond ((not (if (eq? kind absent)
                          (not create?)
                          (and (string? kind) (member kind node-kinds))))
                 'invalid)
                ((not (and (string? title) (string? body) (string? type))) 'invalid)
                ((not (or (eq? props absent) (null? props))) 'invalid)
                ((not (<= (string-length title) title-cap)) 'invalid)
                ((has-nul? title) 'invalid)
                ((not (content-type-ok? type)) 'invalid)
                (else
                 (let-values (((bytes nul?) (scan-body body)))
                   (cond (nul? 'invalid)
                         ((<= bytes body-cap)
                          (make-content (if (eq? kind absent) #f kind) title body type "{}"))
                         (else 'too-large))))))
        'invalid))

  ;;; What the job found, and the event it names (D5)

  (define (revision? x) (and (integer? x) (exact? x) (<= 1 x max-revision)))

  ;; Found = (U 'none 'match 'differ)
  ;; found : (U Natural #f) Natural -> Found
  ;; The stored revision, or #f for no node, against If-Match's revision:
  ;; none, match when they are equal, else differ. A stored revision may be
  ;; past 2^53 (a write at 2^53 makes one); no If-Match names it, so it
  ;; differs. An assertion violation, with no irritant, for a stored revision
  ;; that is no whole number from 1, or a given one outside 1 to 2^53.
  (define (found stored given)
    (unless (and (or (not stored) (and (integer? stored) (exact? stored) (>= stored 1)))
                 (revision? given))
      (assertion-violation 'found "a revision is a whole number from 1"))
    (cond ((not stored) 'none)
          ((= stored given) 'match)
          (else 'differ)))

  ;; found-for-create : Boolean -> Found
  ;; node-in-use?'s answer for a create: #f is none; #t is differ, since a
  ;; create gives no revision for any node to be at.
  (define (found-for-create in-use?)
    (if in-use? 'differ 'none))

  ;; EventKind = (U 'create 'replace 'replace-other-kind 'restore 'restore-unknown)
  ;; write-event : Symbol Precondition (U String #f) (U String #f) Boolean -> EventKind
  ;; The route (put or restore), the precondition, the request's kind, the
  ;; stored kind (#f for no node), and whether the snapshot to restore exists.
  ;; A put with 'create is create. A put with a revision is
  ;; replace-other-kind when the request names a kind, a stored kind exists,
  ;; and they differ; else replace. A restore is restore when the snapshot
  ;; exists, else restore-unknown. The snapshot is not looked at for a put,
  ;; nor the kinds for a restore. An assertion violation, its irritant the
  ;; route, for another route, a kind that is no string or #f, a put's
  ;; precondition that is no 'create or revision, and a restore's that is no
  ;; revision (If-None-Match on a restore is the route's 400).
  (define (write-event route pre request-kind stored-kind snapshot?)
    (define (bad what) (assertion-violation 'write-event what route))
    (unless (and (or (not request-kind) (string? request-kind))
                 (or (not stored-kind) (string? stored-kind)))
      (bad "a kind is a string or #f"))
    (case route
      ((put)
       (cond ((eq? pre 'create) 'create)
             ((not (revision? pre)) (bad "a put's precondition is 'create or a revision"))
             ((and request-kind stored-kind (not (string=? request-kind stored-kind)))
              'replace-other-kind)
             (else 'replace)))
      ((restore)
       (cond ((not (revision? pre)) (bad "a restore's precondition is a revision"))
             (snapshot? 'restore)
             (else 'restore-unknown)))
      (else (bad "a route is put or restore"))))

  ;;; D5's table

  (define (same d e) d)

  ;; write-rows : (Listof Row)
  ;; D5's twelve rows, by Found and then by event, as the plan's table reads.
  ;; Row is (state event next command update), as (techo machine) takes it.
  ;; After insert, write or copy the next state is differ: the same request
  ;; sent again is stale. After a refusal the state stays.
  (define write-rows
    (list
     (list 'none 'create 'differ 'insert same)
     (list 'none 'replace 'none 'refuse-404 same)
     (list 'none 'restore-unknown 'none 'refuse-404 same)
     (list 'match 'replace 'differ 'write same)
     (list 'match 'replace-other-kind 'match 'refuse-409 same)
     (list 'match 'restore 'differ 'copy same)
     (list 'match 'restore-unknown 'match 'refuse-404 same)
     (list 'differ 'create 'differ 'refuse-412 same)
     (list 'differ 'replace 'differ 'refuse-412 same)
     (list 'differ 'replace-other-kind 'differ 'refuse-412 same)
     (list 'differ 'restore 'differ 'refuse-412 same)
     (list 'differ 'restore-unknown 'differ 'refuse-412 same)))

  ;; write-cant-happen : (Listof (List StateKind EventKind String))
  ;; The three cells with no row, each with its reason.
  (define write-cant-happen
    '((none replace-other-kind "no node was found, so there is no stored kind to differ from")
      (none restore "no node was found, so it has no snapshot to restore")
      (match create "a create gives no revision, so it never matches one")))

  (define write-machine (make-machine write-rows))

  ;; write-step : Found EventKind -> (values Found CommandKind)
  ;; Commands: insert write copy refuse-404 refuse-409 refuse-412. An
  ;; assertion violation, who 'machine-step, for a pair with no row.
  (define (write-step found-kind event)
    (let-values (((next command)
                  (machine-step write-machine (cons found-kind #f) (cons event #f))))
      (values (car next) (car command))))

  ;;; The document

  ;; The document's rows and columns, in D5's order.
  (define found-kinds '(none match differ))
  (define event-kinds '(create replace replace-other-kind restore restore-unknown))

  ;; cell : StateKind EventKind -> String
  ;; The row's command, "cannot happen", or "no row", which no test passes.
  (define (cell s e)
    (cond ((find (lambda (r) (and (eq? (car r) s) (eq? (cadr r) e))) write-rows)
           => (lambda (r) (symbol->string (cadddr r))))
          ((find (lambda (c) (and (eq? (car c) s) (eq? (cadr c) e))) write-cant-happen)
           "cannot happen")
          (else "no row")))

  ;; table-line : (Listof String) -> String     "| a | b |" and a newline
  (define (table-line cells)
    (string-append "| " (fold-left (lambda (acc c) (string-append acc " | " c))
                                  (car cells) (cdr cells))
                   " |\n"))

  ;; rule-line : (Listof Any) -> String     "|---|---|" for two columns
  (define (rule-line columns)
    (string-append (apply string-append (map (lambda (c) "|---") columns)) "|\n"))

  ;; write-document : -> String
  ;; The text of .plans/machines/write.md, rendered from the table: the
  ;; diagram, each cell's command, and why each can't-happen cell can't.
  (define (write-document)
    (string-append
     "# The write machine\n\n"
     "Generated from the table in `src/techo/nodes.sls`. Do not edit.\n"
     "Regenerate with `scripts/guix-env make machines`; "
     "a test fails when this file differs.\n\n"
     "A write starts in what its job found: `none`, no node; `match`, the node at\n"
     "the revision given; `differ`, the node at another revision, or a create's id\n"
     "in use. The next state is what the same request would find if sent again. No\n"
     "state is an end, on purpose.\n\n"
     "```mermaid\n"
     (machine->mermaid write-machine)
     "```\n\n"
     "## The command each cell names\n\n"
     (table-line (cons "Found" (map symbol->string event-kinds)))
     (rule-line (cons 'found event-kinds))
     (apply string-append
            (map (lambda (s) (table-line (cons (symbol->string s)
                                               (map (lambda (e) (cell s e)) event-kinds))))
                 found-kinds))
     "\n## Why a cell cannot happen\n\n"
     (table-line '("Found" "On" "Why"))
     (rule-line '(found on why))
     (apply string-append
            (map (lambda (c) (table-line (list (symbol->string (car c))
                                               (symbol->string (cadr c))
                                               (caddr c))))
                 write-cant-happen))))
)
