#!r6rs
;;; (techo tags): slice 7a's tags, judged before any job. Pure: no
;;; database, no circuit, no clock.
;;;
;;;   the caps            50 a node, 64 folded, 256 sent, 500 a step, 10 a filter
;;;   normalise-tag       a sent tag's stored form, or 'invalid
;;;   request-tags        a PUT's tags member: the stored forms, sorted, distinct
;;;   filter-tags         the list's ?tag= values
;;;   parse-rename-body   a rename's {"from","to"}
;;;   parse-remove-body   a removal's {"tag"}
;;;   tags->json          a snapshot's tags as text
;;;   json->tags          a snapshot's text read back, as stored
;;;
;;; The rule (G3, as its review fixed it, the owner's H2 and H3, and his
;;; rulings F1 to F6): what is no string, or is over tag-raw-cap
;;; characters, is refused before any character is read: NFKC can grow a
;;; string 18 times (traps.md). Then a string that holds an
;;; unassigned-char? is refused as sent, before it is folded (F1). Then
;;; NFKC, string-downcase, NFKC: lowercasing a normalised string can leave
;;; it not normalised, so it is normalised again (traps.md). Then each
;;; dash-char? becomes `-` (F5): a dash is no space, so it is never
;;; trimmed, and a run of them is a run of `-`. Then each space-char? at
;;; either end is trimmed, and each run of them inside becomes one `-`; a
;;; hyphen sent is left. The result must be 1 to tag-length-cap
;;; characters, the first no mark-char? (F4: only the first), and each
;;; allowed-char? (no control, line break or noncharacter), and none
;;; invisible-char? (H3, F2, F3), private-use-char? (F6) or
;;; unassigned-char?. Nothing is stripped: a string that breaks the rule
;;; is refused whole. So a stored tag is a fixed point (L1): folding it
;;; again gives it back.
;;;
;;; A tag is stored as Chez's tables fold it today. Every character a
;;; stored tag holds was assigned in them, and Unicode promises that an
;;; assigned character normalises the same in every later version: an
;;; upgrade can take more tags. One read back from a snapshot is taken as
;;; stored, never folded again (H4).
;;;
;;; Nothing here raises but tags->json and json->tags, and their raises are
;;; assertion violations with no irritant: no raise carries a tag.
(library (techo tags)
  (export tag-cap tag-length-cap tag-raw-cap tag-step-cap tag-filter-cap
          normalise-tag request-tags filter-tags tags->json json->tags
          parse-rename-body parse-remove-body)
  (import (rnrs)
          (only (jsonparse easy) string->json json->string)
          (only (techo chars) allowed-char? space-char? invisible-char? private-use-char?
                unassigned-char? mark-char? dash-char?))

  ;;; The caps

  ;; tag-cap : Natural
  ;; The most tags a node carries (G5), and the most entries a request's
  ;; tags may send, counted as sent, before any is folded.
  (define tag-cap 50)

  ;; tag-length-cap : Natural
  ;; A tag's limit, in characters of its stored form.
  (define tag-length-cap 64)

  ;; tag-raw-cap : Natural
  ;; A sent tag's limit, in characters, before it is folded (the review's
  ;; blocker 3): the worst request is then 50 of 256.
  (define tag-raw-cap 256)

  ;; tag-step-cap : Natural
  ;; The most nodes one step of a rename or a removal touches (G8).
  (define tag-step-cap 500)

  ;; tag-filter-cap : Natural
  ;; The most ?tag= values a list takes, counted as sent (G6).
  (define tag-filter-cap 10)

  ;;; The rule

  ;; collapse : String -> String
  ;; S without the space-char?s at either end, each run of them inside
  ;; one `-`.
  (define (collapse s)
    (let* ((n (string-length s))
           (start (let loop ((i 0))
                    (if (and (< i n) (space-char? (string-ref s i))) (loop (+ i 1)) i)))
           (end (let loop ((j n))
                  (if (and (> j start) (space-char? (string-ref s (- j 1)))) (loop (- j 1)) j))))
      (let loop ((i start) (acc '()) (in-run? #f))
        (cond ((= i end) (list->string (reverse acc)))
              ((space-char? (string-ref s i))
               (loop (+ i 1) (if in-run? acc (cons #\- acc)) #t))
              (else (loop (+ i 1) (cons (string-ref s i) acc) #f))))))

  ;; hyphens : String -> String     S with each dash-char? a `-`
  (define (hyphens s)
    (list->string (map (lambda (c) (if (dash-char? c) #\- c)) (string->list s))))

  ;; shown-char? : Char -> Boolean     what a stored tag may hold
  (define (shown-char? c)
    (and (allowed-char? c #f) (not (invisible-char? c)) (not (private-use-char? c))
         (not (unassigned-char? c))))

  ;; every-char? : (Char -> Boolean) String -> Boolean     whether PRED holds of each of S
  (define (every-char? pred s)
    (let ((n (string-length s)))
      (let loop ((i 0))
        (or (= i n) (and (pred (string-ref s i)) (loop (+ i 1)))))))

  ;; normalise-tag : Any -> (U String 'invalid)
  ;; X's stored form, by the rule above. 'invalid for what is no string;
  ;; for a string over tag-raw-cap characters, before any character is
  ;; read; for one that holds an unassigned code point, before it is
  ;; folded; and for one whose folded form is empty, over tag-length-cap,
  ;; begins with a combining mark, or holds a character that is no
  ;; allowed-char? (U+0000 to U+001F, U+007F to U+009F, U+2028, U+2029, a
  ;; noncharacter) or is invisible-char?, private-use-char? or
  ;; unassigned-char?. Never raises.
  (define (normalise-tag x)
    (if (and (string? x) (<= (string-length x) tag-raw-cap)
             (every-char? (lambda (c) (not (unassigned-char? c))) x))
        (let ((t (collapse (hyphens (string-normalize-nfkc (string-downcase (string-normalize-nfkc x)))))))
          (if (and (<= 1 (string-length t) tag-length-cap)
                   (not (mark-char? (string-ref t 0)))
                   (every-char? shown-char? t))
              t
              'invalid))
        'invalid))

  ;; stored-forms : (Listof Any) -> (U (Listof String) 'invalid)
  ;; Each folded: sorted by code point, no two the same; 'invalid when
  ;; normalise-tag refuses one.
  (define (stored-forms sent)
    (let loop ((l sent) (acc '()))
      (if (null? l)
          (distinct (list-sort string<? acc))
          (let ((t (normalise-tag (car l))))
            (if (eq? t 'invalid) 'invalid (loop (cdr l) (cons t acc)))))))

  ;; distinct : (Listof String) -> (Listof String)     a sorted list, each run of one string once
  (define (distinct sorted)
    (cond ((null? sorted) '())
          ((and (pair? (cdr sorted)) (string=? (car sorted) (cadr sorted))) (distinct (cdr sorted)))
          (else (cons (car sorted) (distinct (cdr sorted))))))

  ;;; Objects, read in bounded time

  ;; at-most? : Any Natural -> Boolean
  ;; Whether X is a proper list of at most N elements. It walks at most
  ;; N + 1 pairs, however long X is.
  (define (at-most? x n)
    (cond ((null? x) #t)
          ((and (pair? x) (> n 0)) (at-most? (cdr x) (- n 1)))
          (else #f)))

  ;; named? : Any -> Boolean     a (String . value) pair
  (define (named? m) (and (pair? m) (string? (car m))))

  ;; no-twice? : (Listof String) -> Boolean     no name twice; seven at most here
  (define (no-twice? names)
    (or (null? names)
        (and (not (member (car names) (cdr names))) (no-twice? (cdr names)))))

  ;; object-of? : Any Natural -> Boolean
  ;; Whether X is an object as the JSON reader gives one, '() or a list of
  ;; (String . value), of at most N members, no name twice. The members are
  ;; counted before any name is read.
  (define (object-of? x n)
    (and (at-most? x n) (for-all named? x) (no-twice? (map car x))))

  ;; none : what member answers for a member not given: no JSON value is it
  (define none (list 'none))

  (define (given? v) (not (eq? v none)))

  ;; member-value : Alist String -> Any     the member's value, or none
  (define (member-value x name)
    (let ((m (find (lambda (m) (string=? (car m) name)) x)))
      (if m (cdr m) none)))

  ;;; A request's tags

  ;; request-tags : Alist Boolean -> (U (Listof String) 'absent 'invalid)
  ;; The request's whole object, as parse-content took it, and whether it
  ;; is a create. No tags member: '() on a create, 'absent on a replace,
  ;; which keeps the stored tags (G2). A JSON array of at most tag-cap
  ;; entries, its length counted before any entry is read: each entry's
  ;; stored form, sorted with string<? (by code point), no two the same; so
  ;; [] is '(), and ["Work","work"] is ("work"). 'invalid for an array of
  ;; more entries (counted as sent: 51 that fold to one are refused), for
  ;; an entry normalise-tag refuses (what is no string among them), for a
  ;; value that is no array (null, a string, an object), and for what is
  ;; no object of at most seven members with no name twice, or a create?
  ;; that is no boolean. Never raises.
  (define (request-tags x create?)
    (if (and (boolean? create?) (object-of? x 7))
        (let ((v (member-value x "tags")))
          (cond ((not (given? v)) (if create? '() 'absent))
                ((and (vector? v) (<= (vector-length v) tag-cap)) (stored-forms (vector->list v)))
                (else 'invalid)))
        'invalid))

  ;; filter-tags : (Listof String) -> (U (Listof String) 'invalid)
  ;; The list's ?tag= values, as sent, each a stored tag's: their stored
  ;; forms, sorted, no two the same; '() for none. 'invalid for more than
  ;; tag-filter-cap values as sent, counted before any is read (so
  ;; ?tag=Work&tag=work is two toward the ten, and one tag); for a value
  ;; normalise-tag refuses (an empty one too); and for what is no list.
  ;; Never raises.
  (define (filter-tags values)
    (if (at-most? values tag-filter-cap)
        (stored-forms values)
        'invalid))

  ;;; The commands' bodies

  ;; parse-rename-body : Any -> (U (Pair String String) 'invalid)
  ;; A rename's JSON, as the reader gives it: exactly the members from and
  ;; to, in either order, each a tag normalise-tag takes, as their stored
  ;; forms (from . to). 'invalid for anything else: another member, a
  ;; member missing or twice, a tag refused, from and to the same once
  ;; folded, what is no object. Never raises; it reads at most three pairs.
  (define (parse-rename-body x)
    (if (object-of? x 2)
        (let ((from (member-value x "from")) (to (member-value x "to")))
          (if (and (given? from) (given? to))
              (let ((f (normalise-tag from)) (t (normalise-tag to)))
                (if (or (eq? f 'invalid) (eq? t 'invalid) (string=? f t))
                    'invalid
                    (cons f t)))
              'invalid))
        'invalid))

  ;; parse-remove-body : Any -> (U String 'invalid)
  ;; A removal's JSON: exactly the member tag, a tag normalise-tag takes,
  ;; as its stored form. 'invalid for anything else: another member, the
  ;; member missing or twice, a tag refused, what is no object. Never
  ;; raises; it reads at most two pairs.
  (define (parse-remove-body x)
    (if (object-of? x 1)
        (let ((tag (member-value x "tag")))
          (if (given? tag) (normalise-tag tag) 'invalid))
        'invalid))

  ;;; A snapshot's tags

  ;; tags->json : (Listof String) -> String
  ;; The tags as a JSON array, the text the JSON writer writes for it
  ;; (json->string), "[]" for none. An assertion violation, with no
  ;; irritant, for what is no list of strings.
  (define (tags->json tags)
    (unless (and (list? tags) (for-all string? tags))
      (assertion-violation 'tags->json "tags are a list of strings"))
    (json->string (list->vector tags)))

  ;; json->tags : String -> (Listof String)
  ;; A snapshot's tags text read back: the array's strings in its order,
  ;; as stored, never folded again (H4). An assertion violation, with no
  ;; irritant, for what is no text of a JSON array of strings; the reader's
  ;; own raise, which names an offset, is not passed on.
  (define (json->tags text)
    (let ((v (and (string? text) (guard (e (#t #f)) (string->json text)))))
      (if (and (vector? v) (for-all string? (vector->list v)))
          (vector->list v)
          (assertion-violation 'json->tags "stored tags are not a JSON array of strings"))))
)
