#!r6rs
;;; (techo nodes): slice 4's pure core. A node's id (D2); a revision, in a
;;; path and as the ETag (D4); If-Match and If-None-Match (D4); the content
;;; a write carries, and its limits (D6, D7); and the versioned write as a
;;; table (D5). Slice 4b's lifecycle: a node's states, the list's ?state=,
;;; the feed's ops, the lifecycle as a table, and node-command, the one pure
;;; function by which the two tables answer a request. Pure: no database, no
;;; circuit, no clock (ADR-0007).
;;;
;;; The table is over what a write's job found: none (no node, or another
;;; account's), match (the node, at the revision given) and differ (the node
;;; at another revision, or a create's id in use). A state here has no data,
;;; so write-step takes and answers kinds. Every Found is a start, and no
;;; state is an end. The lifecycle's table is over the states active,
;;; archived, trashed and purged, a symbol each (the store keeps their
;;; names): active is its start, and purged its one end.
;;;
;;; Slice 5a's tree: what may hold what, the verdict on a new parent from
;;; the facts a job read, which children a bulk move takes, a create's
;;; parent, a move's body and the list's ?parent=. The lifecycle's table
;;; gains move and move-children, and node-command takes the verdict and
;;; whether the node has children.
;;;
;;; Nothing here raises with a title or a body: parse-content,
;;; parse-move-body and parse-parent-param never raise, and every other
;;; raise carries a symbol, a number, a boolean or an id at most.
(library (techo nodes)
  (export node-kinds body-cap request-cap title-cap
          depth-cap move-children-cap move-body-cap
          parse-node-id node-id->string parse-revision etag precondition
          content? content-kind content-title content-body content-content-type content-props
          content-parent
          parse-content parse-move-body parse-parent-param
          found found-for-create write-event
          write-rows write-cant-happen write-step write-document
          node-states node-state->string string->node-state parse-state-param
          lifecycle-events event-op
          lifecycle-rows lifecycle-cant-happen lifecycle-step lifecycle-document
          may-hold? parent-verdict child-moves? child-kind-filter
          node-command)
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

  ;; depth-cap : Natural
  ;; A new parent's depth limit (T5): it may have at most 63 ancestors. A
  ;; walk up asked for depth-cap ids that answers depth-cap is too deep.
  (define depth-cap 64)

  ;; move-children-cap : Natural
  ;; The most children one bulk move moves.
  (define move-children-cap 1000)

  ;; move-body-cap : Natural
  ;; A move's or a bulk move's JSON's limit, in bytes: 16 KiB.
  (define move-body-cap 16384)

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
  ;; content-parent : Content -> (U Bytevector #f)
  ;;   a create's parent; #f for the top level, and always for a replace
  (define-record-type content
    (fields kind title body content-type props parent))

  ;; A replace's five members; a create's are those and parent (T3).
  (define member-names '("kind" "title" "body" "content_type" "props"))
  (define create-member-names (append member-names '("parent")))
  (define content-type-cap 255)

  ;; at-most? : Any Natural -> Boolean
  ;; Whether X is a proper list of at most N elements. It walks at most N + 1
  ;; pairs, however long X is: the review's blocker 2.
  (define (at-most? x n)
    (cond ((null? x) #t)
          ((and (pair? x) (> n 0)) (at-most? (cdr x) (- n 1)))
          (else #f)))

  ;; known-member? : Any (Listof String) -> Boolean     a (name . value) pair, its name one of NAMES
  (define (known-member? m names)
    (and (pair? m) (string? (car m)) (member (car m) names) #t))

  ;; distinct? : (Listof String) -> Boolean     no name twice; at most six here
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

  ;; parent-value : Any -> (U Bytevector #f 'invalid)
  ;; A parent member's value, as req-json gives it: JSON null, the symbol
  ;; null, is the top level, #f; a v7 id's text, in either case, is its 16
  ;; bytes. 'invalid for anything else: JSON false (which reads as #f), {}
  ;; (which reads as '()), a number, an array, an object, a v4 id. Never
  ;; raises, and bounded: parse-node-id refuses any string but one of 36
  ;; characters before it reads it.
  (define (parent-value v)
    (cond ((eq? v 'null) #f)
          ((string? v) (parse-node-id v))
          (else 'invalid)))

  ;; parse-content : Any Boolean -> (U Content 'invalid 'too-large)
  ;; From req-json's value (an object is an alist of (String . value), a
  ;; name given twice kept; {} is '()), and whether this is a create. The
  ;; members are kind, title, body, content_type and props, and on a create
  ;; parent. title, body and content_type are required strings; kind is
  ;; required on a create and optional otherwise, one of node-kinds; props
  ;; is optional and must be an empty object; a create's parent is optional,
  ;; as parent-value takes it, and null is as none (T3). 'invalid for what is
  ;; no object, a member past a create's six or a replace's five, a member
  ;; not of those (so parent on a replace), a name twice, a member missing or
  ;; of the wrong type, a title over title-cap characters, U+0000 in the
  ;; title or the body, a content_type that content-type-ok? refuses, or a
  ;; parent that parent-value refuses. 'too-large only for a body over
  ;; body-cap bytes of UTF-8, when all else is right.
  ;; Never raises. Its work is bounded by its members' lengths: a list longer
  ;; than six (five for a replace) is refused before any name is compared,
  ;; and a title, a content type or a parent over its limit before it is read.
  (define (parse-content x create?)
    (let ((names (if create? create-member-names member-names)))
      (if (and (at-most? x (length names))
               (for-all (lambda (m) (known-member? m names)) x)
               (distinct? (map car x)))
          (let ((kind (value-of x "kind"))
                (title (value-of x "title"))
                (body (value-of x "body"))
                (type (value-of x "content_type"))
                (props (value-of x "props"))
                (parent (let ((p (value-of x "parent")))
                          (if (eq? p absent) #f (parent-value p)))))
            (cond ((not (if (eq? kind absent)
                            (not create?)
                            (and (string? kind) (member kind node-kinds))))
                   'invalid)
                  ((not (and (string? title) (string? body) (string? type))) 'invalid)
                  ((not (or (eq? props absent) (null? props))) 'invalid)
                  ((not (<= (string-length title) title-cap)) 'invalid)
                  ((has-nul? title) 'invalid)
                  ((not (content-type-ok? type)) 'invalid)
                  ((eq? parent 'invalid) 'invalid)
                  (else
                   (let-values (((bytes nul?) (scan-body body)))
                     (cond (nul? 'invalid)
                           ((<= bytes body-cap)
                            (make-content (if (eq? kind absent) #f kind) title body type "{}"
                                          parent))
                           (else 'too-large))))))
          'invalid)))

  ;; parse-move-body : Any -> (U Bytevector #f 'invalid)
  ;; A move's or a bulk move's JSON, as req-json gives it: exactly one
  ;; object with exactly one member, parent, whose value parent-value takes:
  ;; a v7 id's 16 bytes, or #f for null, the top level. 'invalid for anything
  ;; else: {} (which reads as '(), and is no top level), another member, the
  ;; member twice, a parent parent-value refuses, what is no object. Never
  ;; raises; it looks at no more than the list's first two pairs.
  (define (parse-move-body x)
    (if (and (pair? x) (null? (cdr x)) (pair? (car x))
             (string? (caar x)) (string=? (caar x) "parent"))
        (parent-value (cdar x))
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
  ;;; The lifecycle (slice 4b: L1, L2, L5, L8, L10)

  ;; node-states : (Listof Symbol)
  ;; A node's four states. purged is the one end, and no client sees it.
  (define node-states '(active archived trashed purged))

  ;; The states a list may be asked for, and a found node may be in.
  (define live-states '(active archived trashed))

  ;; state-named : Any (Listof Symbol) -> (U Symbol #f)
  ;; The state among STATES whose name is the string X; #f for anything else.
  (define (state-named x states)
    (and (string? x) (find (lambda (s) (string=? (symbol->string s) x)) states)))

  ;; node-state->string : Symbol -> String
  ;; The state's name, as the store keeps it. An assertion violation, with
  ;; no irritant, for anything not in node-states.
  (define (node-state->string state)
    (unless (and (symbol? state) (memq state node-states))
      (assertion-violation 'node-state->string "not a node's state"))
    (symbol->string state))

  ;; string->node-state : String -> Symbol
  ;; The state the store's name names, exactly: no other case, no spaces. An
  ;; assertion violation, with no irritant, for anything else.
  (define (string->node-state x)
    (or (state-named x node-states)
        (assertion-violation 'string->node-state "not a node's state's name")))

  ;; parse-state-param : (U String #f) -> (U Symbol 'invalid)
  ;; The list's ?state=: #f (not given) is active; "active", "archived" and
  ;; "trashed" are themselves. 'invalid for anything else: "purged", "",
  ;; another case, what is no string. Never raises.
  (define (parse-state-param x)
    (cond ((not x) 'active)
          ((state-named x live-states))
          (else 'invalid)))

  ;; parse-parent-param : (U String #f) -> (U 'any #f Bytevector 'invalid)
  ;; The list's ?parent=, as nodes-page takes it: not given (#f) is 'any,
  ;; the flat list; exactly "null" is #f, the top level; a v7 id's text, in
  ;; either case, is its 16 bytes. 'invalid for anything else: "", "NULL",
  ;; a v4 id, what is no string. Never raises.
  (define (parse-parent-param x)
    (cond ((not x) 'any)
          ((and (string? x) (string=? x "null")) #f)
          (else (parse-node-id x))))

  ;; lifecycle-events : (Listof Symbol)
  ;; The five events a state change sends, each its own route.
  (define lifecycle-events '(archive unarchive trash untrash purge))

  ;; The two a move sends (slice 5a), each its own route: move puts the node
  ;; under a new parent; move-children moves its children, and leaves it.
  (define move-events '(move move-children))

  ;; The lifecycle table's eight events: the five, write (a replace or a
  ;; revision's restore) and the two moves. The document's columns.
  (define table-events (append lifecycle-events '(write) move-events))

  ;; event-op : Symbol -> String
  ;; An event's op in the change feed: a lifecycle event's own name, and
  ;; "move" for move. A bulk move's children each get "move"; the node whose
  ;; children move gets no change row, so move-children has no op. An
  ;; assertion violation, with no irritant, for anything else.
  (define (event-op event)
    (unless (and (symbol? event) (or (memq event lifecycle-events) (eq? event 'move)))
      (assertion-violation 'event-op "not an event with an op of its own"))
    (symbol->string event))

  ;; lifecycle-rows : (Listof Row)
  ;; The twenty-four rows, three states by eight events, by state and then
  ;; by event, as the plans' tables read. Row is (state event next command
  ;; update), as (techo machine) takes it. write is a replace or a
  ;; revision's restore. A refusal and allow leave the state; untrash always
  ;; lands on active (L2); a purge is only from trashed (L8); a trashed node
  ;; is not moved, but its children may be (T8, slice 5a's review). A state
  ;; here has no data.
  (define lifecycle-rows
    (list
     (list 'active 'archive 'archived 'set-state same)
     (list 'active 'unarchive 'active 'refuse-wrong-state same)
     (list 'active 'trash 'trashed 'set-state same)
     (list 'active 'untrash 'active 'refuse-wrong-state same)
     (list 'active 'purge 'active 'refuse-wrong-state same)
     (list 'active 'write 'active 'allow same)
     (list 'active 'move 'active 'allow same)
     (list 'active 'move-children 'active 'allow same)
     (list 'archived 'archive 'archived 'refuse-wrong-state same)
     (list 'archived 'unarchive 'active 'set-state same)
     (list 'archived 'trash 'trashed 'set-state same)
     (list 'archived 'untrash 'archived 'refuse-wrong-state same)
     (list 'archived 'purge 'archived 'refuse-wrong-state same)
     (list 'archived 'write 'archived 'allow same)
     (list 'archived 'move 'archived 'allow same)
     (list 'archived 'move-children 'archived 'allow same)
     (list 'trashed 'archive 'trashed 'refuse-wrong-state same)
     (list 'trashed 'unarchive 'trashed 'refuse-wrong-state same)
     (list 'trashed 'trash 'trashed 'refuse-wrong-state same)
     (list 'trashed 'untrash 'active 'set-state same)
     (list 'trashed 'purge 'purged 'purge same)
     (list 'trashed 'write 'trashed 'refuse-wrong-state same)
     (list 'trashed 'move 'trashed 'refuse-wrong-state same)
     (list 'trashed 'move-children 'trashed 'allow same)))

  ;; lifecycle-cant-happen : (Listof (List StateKind EventKind String))
  ;; purged's eight cells, each with its reason. purged is the end: it has no row.
  (define lifecycle-cant-happen
    '((purged archive "a purged node is found as none, so its state is never stepped")
      (purged unarchive "a purged node is found as none, so its state is never stepped")
      (purged trash "a purged node is found as none, so its state is never stepped")
      (purged untrash "a purged node is found as none, so its state is never stepped")
      (purged purge "a purged node is found as none, so its state is never stepped")
      (purged write "a purged node is found as none, so its state is never stepped")
      (purged move "a purged node is found as none, so its state is never stepped")
      (purged move-children "a purged node is found as none, so its state is never stepped")))

  (define lifecycle-machine (make-machine lifecycle-rows))

  ;; lifecycle-step : Symbol Symbol -> (values Symbol Symbol)
  ;; The state and the event to the next state and the command. Commands:
  ;; set-state purge allow refuse-wrong-state. An assertion violation, who
  ;; 'machine-step, its irritants the state and the event, for a pair with
  ;; no row: purged's eight, and what is no state or event of the table.
  (define (lifecycle-step state event)
    (let-values (((next command)
                  (machine-step lifecycle-machine (cons state #f) (cons event #f))))
      (values (car next) (car command))))

  ;;; The tree (slice 5a: T2, T5, T8; the plan's review)

  ;; holds : (Listof (Pair String (Listof String)))
  ;; What may hold what (T2): a parent's kind, then every kind it holds. A
  ;; Project holds any kind, Projects too; a Journal only Notes; a Note, a
  ;; Task and a Contact nothing.
  (define holds
    '(("project" "project" "journal" "note" "task" "contact")
      ("journal" "note")
      ("note")
      ("task")
      ("contact")))

  ;; kind? : Any -> Boolean     one of node-kinds
  (define (kind? x) (and (string? x) (member x node-kinds) #t))

  ;; id? : Any -> Boolean       16 bytes
  (define (id? x) (and (bytevector? x) (= (bytevector-length x) 16)))

  ;; may-hold? : String String -> Boolean
  ;; Whether a parent of the first kind may hold a child of the second, by
  ;; holds. An assertion violation, with no irritant, for what is no kind,
  ;; either one.
  (define (may-hold? parent child)
    (unless (and (kind? parent) (kind? child))
      (assertion-violation 'may-hold? "not a node's kind"))
    (and (member child (cdr (assoc parent holds))) #t))

  ;; holds-any? : String -> Boolean     whether may-hold? lets KIND hold any kind
  (define (holds-any? kind)
    (exists (lambda (child) (may-hold? kind child)) node-kinds))

  ;; child-kind-filter : (U String #f) -> (U 'any String)
  ;; What the store's children-heads takes for a new parent's kind, read
  ;; from may-hold?: 'any when it holds every kind, as the top level (#f)
  ;; and a Project do; else the one kind it holds, "note" for a Journal. An
  ;; assertion violation, with no irritant, for what is no kind, and for a
  ;; kind that holds no kind (the verdict has refused it already) or some
  ;; but not all, which no filter names.
  (define (child-kind-filter kind)
    (if (not kind)
        'any
        (let ((held (filter (lambda (child) (may-hold? kind child)) node-kinds)))
          (cond ((equal? held node-kinds) 'any)
                ((and (pair? held) (null? (cdr held))) (car held))
                (else (assertion-violation 'child-kind-filter
                                           "no filter names the kinds this kind holds"))))))

  ;; Verdict = (U 'ok 'missing 'trashed 'loop 'wrong-kind 'too-deep)
  ;; parent-verdict : (U Bytevector #f) (U (List String Symbol) #f) (Listof Bytevector)
  ;;                  Bytevector (U String #f) -> Verdict
  ;; From the facts a job read: the new parent's id, #f for the top level;
  ;; what was found of it, its kind and its state, or #f when it is no node
  ;; of this account (missing, another account's, or purged: the store hides
  ;; those); its ancestors, nearest first, as the store answers when asked
  ;; for depth-cap of them; the id to keep out (the node moved or made, or
  ;; for a bulk move the node whose children move); and the kind going in,
  ;; #f for a bulk move. The first that applies (the plan's review):
  ;;   ok          the top level
  ;;   missing     nothing found
  ;;   trashed     the parent is trashed (T8)
  ;;   loop        the parent is the id kept out, or that id is among its
  ;;               ancestors (T5). Before the kind, so a node moved under
  ;;               itself is a loop whatever its kind
  ;;   wrong-kind  the parent may not hold the kind going in; for a bulk
  ;;               move, it holds no kind at all (T2)
  ;;   too-deep    depth-cap ancestors or more: a parent may have 63 (T5)
  ;;   ok          else
  ;; So a loop above the 64th ancestor is too-deep, not a loop. An assertion
  ;; violation, with no irritant, for facts no job finds: an id that is no
  ;; 16 bytes, ancestors that are no list of ids, a found kind not of
  ;; node-kinds or a found state that is no live state's symbol (a purged
  ;; parent, or a state still the store's string), a kind going in that is
  ;; no kind.
  (define (parent-verdict parent found ancestors keep-out kind)
    (define (bad what) (assertion-violation 'parent-verdict what))
    (unless (or (not parent) (id? parent)) (bad "a parent is an id or #f"))
    (unless (and (list? ancestors) (for-all id? ancestors)) (bad "ancestors are a list of ids"))
    (unless (id? keep-out) (bad "the id kept out is an id"))
    (unless (or (not found)
                (and (list? found) (= (length found) 2)
                     (kind? (car found)) (memq (cadr found) live-states)))
      (bad "what was found is #f, or a kind and a live state"))
    (unless (or (not kind) (kind? kind)) (bad "the kind going in is a kind or #f"))
    (cond ((not parent) 'ok)
          ((not found) 'missing)
          ((eq? (cadr found) 'trashed) 'trashed)
          ((or (bytevector=? parent keep-out)
               (exists (lambda (a) (bytevector=? a keep-out)) ancestors))
           'loop)
          ((if kind (not (may-hold? (car found) kind)) (not (holds-any? (car found))))
           'wrong-kind)
          ((>= (length ancestors) depth-cap) 'too-deep)
          (else 'ok)))

  ;; child-moves? : Symbol String (U String #f) -> Boolean
  ;; Whether a bulk move takes a child: its state, its kind, and the new
  ;; parent's kind (#f for the top level, which holds every kind). True when
  ;; lifecycle-step allows move in the child's state (active and archived,
  ;; not trashed) and may-hold? lets the new parent hold the child's kind.
  ;; An assertion violation, who 'machine-step, for a purged child (the
  ;; store answers none) or what is no state's symbol; may-hold?'s for what
  ;; is no kind.
  (define (child-moves? state kind parent-kind)
    (let-values (((next command) (lifecycle-step state 'move)))
      (and (eq? command 'allow)
           (or (not parent-kind) (may-hold? parent-kind kind)))))

  ;;; How the tables answer one request (4b's review, blocker 2; 5a's, blocker 3)

  (define write-events '(create replace replace-other-kind restore restore-unknown))

  ;; write-cant? : Found Symbol -> Boolean     a cell D5 says cannot happen
  (define (write-cant? found-kind event)
    (exists (lambda (c) (and (eq? (car c) found-kind) (eq? (cadr c) event)))
            write-cant-happen))

  ;; write-command : Found EventKind -> Symbol     D5's command for the cell
  (define (write-command found-kind event)
    (let-values (((next command) (write-step found-kind event))) command))

  ;; verdict-commands : (Listof (Pair Verdict (U Symbol #f)))
  ;; What each verdict answers (T10, P17), in parent-verdict's order: ok
  ;; the request's own command (#f here), loop refuse-would-loop, every
  ;; other refuse-invalid-parent.
  (define verdict-commands
    '((ok . #f)
      (missing . refuse-invalid-parent)
      (trashed . refuse-invalid-parent)
      (loop . refuse-would-loop)
      (wrong-kind . refuse-invalid-parent)
      (too-deep . refuse-invalid-parent)))

  ;; judged : Any Symbol -> (values Symbol #f)
  ;; COMMAND when VERDICT is ok, else the verdict's refusal. An assertion
  ;; violation, who 'node-command, its irritant the verdict, for what is
  ;; none of the six.
  (define (judged verdict command)
    (let ((v (and (symbol? verdict) (assq verdict verdict-commands))))
      (unless v (assertion-violation 'node-command "not a verdict on a parent" verdict))
      (values (or (cdr v) command) #f)))

  ;; children? : Any -> Boolean
  ;; X, which must be a boolean: 0 and '() are true in Scheme, so a count or
  ;; a list passed by mistake would refuse every purge. An assertion
  ;; violation, who 'node-command, its irritant X, for anything else.
  (define (children? x)
    (unless (boolean? x)
      (assertion-violation 'node-command "whether the node has children is a boolean" x))
    x)

  ;; node-command : Found (U Symbol #f) Symbol Verdict Boolean
  ;;                -> (values Symbol (U Symbol #f))
  ;; What the job found (none, match, differ, as found answers), the node's
  ;; state (#f when none was found), the request's event, the verdict on the
  ;; new parent (parent-verdict's), and whether the node has children. The
  ;; event is one of D5's five, one of lifecycle-events, move or
  ;; move-children. Answers the command to perform and, for set-state only,
  ;; the state to store; else #f. In this order (ADR-0007, amended
  ;; 2026-11-26: stale, the state, the parent, the children):
  ;;   none    create answers the verdict's answer, insert for ok; D5's
  ;;           other events write-step's command (refuse-404). A lifecycle
  ;;           event, move and move-children answer refuse-404. The state is
  ;;           not looked at.
  ;;   differ  refuse-412, whatever else: stale comes before the state, and
  ;;           a create on an id in use is a 412 before its parent is judged.
  ;;   match   the lifecycle's step, D5's four events but create as its
  ;;           write. refuse-wrong-state is answered as it is, before the
  ;;           kind, a missing snapshot and the parent; set-state answers
  ;;           the next state too; purge answers refuse-has-children when the
  ;;           node has children, else purge; allow answers, for a D5 event,
  ;;           write-step's command for match (write, copy, refuse-409,
  ;;           refuse-404), and for move and move-children the verdict's
  ;;           answer, the event itself for ok.
  ;; A verdict's answer is verdict-commands'. The verdict is looked at only
  ;; for a create found none, and for a move or a bulk move found match in a
  ;; state that allows it; the children only for a trashed node's purge.
  ;; Anywhere else any value is ignored: a caller passes 'ok and #f.
  ;; Commands: insert write copy set-state purge move move-children
  ;; refuse-404 refuse-409 refuse-412 refuse-wrong-state
  ;; refuse-invalid-parent refuse-would-loop refuse-has-children.
  ;; An assertion violation, who 'node-command:
  ;;   - its irritants the five arguments, for a cell that cannot happen: an
  ;;     event no request sends; a Found of none of the three; D5's three
  ;;     (none with replace-other-kind or restore, match with create),
  ;;     whatever the state; match with a state not active, archived or
  ;;     trashed (a purged node is found as none);
  ;;   - its irritant the verdict, where the verdict is looked at and is
  ;;     none of the six;
  ;;   - its irritant the children, where they are looked at and are no
  ;;     boolean.
  (define (node-command found-kind state event verdict has-children)
    (define (cannot) (assertion-violation 'node-command "this cell cannot happen"
                                          found-kind state event verdict has-children))
    (let ((life? (and (memq event lifecycle-events) #t))
          (move? (and (memq event move-events) #t)))
      (unless (or life? move? (memq event write-events)) (cannot))
      (case found-kind
        ((none)
         (cond ((or life? move?) (values 'refuse-404 #f))
               ((write-cant? 'none event) (cannot))
               ((eq? event 'create) (judged verdict (write-command 'none event)))
               (else (values (write-command 'none event) #f))))
        ((differ) (values 'refuse-412 #f))
        ((match)
         (unless (memq state live-states) (cannot))
         (when (and (not life?) (not move?) (write-cant? 'match event)) (cannot))
         (let-values (((next command)
                       (lifecycle-step state (if (or life? move?) event 'write))))
           (case command
             ((allow) (if move?
                          (judged verdict event)
                          (values (write-command 'match event) #f)))
             ((set-state) (values 'set-state next))
             ((purge) (values (if (children? has-children) 'refuse-has-children 'purge) #f))
             ((refuse-wrong-state) (values command #f))
             (else (cannot)))))
        (else (cannot)))))

  ;;; The lifecycle's document

  ;; lifecycle-cell : StateKind EventKind -> String
  ;; The row's command, with "-> next, " before it when the state moves;
  ;; "cannot happen"; or "no row", which no test passes.
  (define (lifecycle-cell s e)
    (cond ((find (lambda (r) (and (eq? (car r) s) (eq? (cadr r) e))) lifecycle-rows)
           => (lambda (r)
                (if (eq? (caddr r) s)
                    (symbol->string (cadddr r))
                    (string-append "-> " (symbol->string (caddr r)) ", "
                                   (symbol->string (cadddr r))))))
          ((find (lambda (c) (and (eq? (car c) s) (eq? (cadr c) e))) lifecycle-cant-happen)
           "cannot happen")
          (else "no row")))

  ;; verdict-answer : Verdict -> String     verdict-commands' answer, in words for ok
  (define (verdict-answer v)
    (let ((command (cdr (assq v verdict-commands))))
      (if command
          (symbol->string command)
          "the request's own: insert, move or move-children")))

  ;; lifecycle-document : -> String
  ;; The text of .plans/machines/lifecycle.md, rendered from the table: the
  ;; diagram, each cell's answer, each verdict's answer, and why each
  ;; can't-happen cell can't.
  (define (lifecycle-document)
    (string-append
     "# The lifecycle machine\n\n"
     "Generated from the table in `src/techo/nodes.sls`. Do not edit.\n"
     "Regenerate with `scripts/guix-env make machines`; "
     "a test fails when this file differs.\n\n"
     "A node starts `active`, and `purged` is the one end. `write` is a replace or a\n"
     "revision's restore. `move` puts the node under a new parent; `move-children`\n"
     "moves its children and leaves the node as it is. A refusal and `allow` leave\n"
     "the state.\n\n"
     "One function, `node-command`, answers a request from this table and the write\n"
     "machine's, with two facts more: the verdict on the new parent, and whether the\n"
     "node has children. It looks first at what the job found:\n\n"
     "- `none`: the write machine's answer. A create's is the verdict's: an insert\n"
     "  when it is `ok`. A state change, a move and a bulk move are a 404.\n"
     "- `differ`: a 412, whatever the state. Stale comes before the state, and a\n"
     "  create on an id in use is a 412 before its parent is judged.\n"
     "- `match`: this table. Its refusal comes before the kind, before a missing\n"
     "  snapshot and before the new parent. After `allow`, the write machine answers\n"
     "  a write, and the verdict a move or a bulk move. A purge is refused while the\n"
     "  node has children.\n\n"
     "A purged node is found as `none`, so it never reaches this table.\n\n"
     "```mermaid\n"
     (machine->mermaid lifecycle-machine)
     "```\n\n"
     "## The answer each cell names\n\n"
     (table-line (cons "State" (map symbol->string table-events)))
     (rule-line (cons 'state table-events))
     (apply string-append
            (map (lambda (s)
                   (table-line (cons (symbol->string s)
                                     (map (lambda (e) (lifecycle-cell s e)) table-events))))
                 node-states))
     "\n## The answer each verdict names\n\n"
     "`parent-verdict` judges the new parent. The first that applies: `ok` for the\n"
     "top level, then `missing`, `trashed`, `loop`, `wrong-kind` and `too-deep`; else\n"
     "`ok`.\n\n"
     (table-line '("Verdict" "Answer"))
     (rule-line '(verdict answer))
     (apply string-append
            (map (lambda (v) (table-line (list (symbol->string (car v)) (verdict-answer (car v)))))
                 verdict-commands))
     "\n## Why a cell cannot happen\n\n"
     (table-line '("State" "On" "Why"))
     (rule-line '(state on why))
     (apply string-append
            (map (lambda (c) (table-line (list (symbol->string (car c))
                                               (symbol->string (cadr c))
                                               (caddr c))))
                 lifecycle-cant-happen))))
)
