#!r6rs
;;; (techo contact): slice 6's Contact props (P8), a strict subset of
;;; JSContact (RFC 9553), its names and shapes exactly, as the plan's
;;; Contact table and its review's pinned rules have them. Pure.
;;;
;;; parse-contact-props takes the JSON reader's value of a node's props and
;;; answers it checked and canonical, in the reader's own representation (an
;;; object an alist of (String . value), an array a vector, true #t, a
;;; number an exact integer), so the JSON writer writes one text for one
;;; value (R17):
;;;
;;;   - each object's members in the table's order;
;;;   - an Id map's entries sorted by key with string<?;
;;;   - a set's members (contexts, features) in the plan's order;
;;;   - an array as sent;
;;;   - @type, where it names the right type, and an explicit default
;;;     (kind individual, isOrdered false, a title's kind title) dropped.
;;;
;;; Its work is linear in the value's size. An object's names are counted
;;; against its bound, and each found in its table, before any of its
;;; values is read: a 100,000-member object is refused after at most one
;;; name more than it may hold. An Id given twice and an organizationId are
;;; found by a hashtable. No size cap here: the caller measures the text.
;;;
;;; Nothing here raises, whatever it is given, and so no condition carries a
;;; request's text.
(library (techo contact)
  (export parse-contact-props)
  (import (rnrs)
          (only (uri easy) uri-string?)
          (only (techo when) real-date?))

  ;;; Answers

  ;; fail : what a judge answers for a value it refuses: no JSON value is it
  (define fail (list 'fail))
  (define (fail? x) (eq? x fail))

  ;; absent : a member's slot when the member was not given
  (define absent (list 'absent))

  ;; no-default : a member's default when it has none
  (define no-default (list 'no-default))

  ;; A Judge is Any -> (U Canonical fail): a value's canonical form, or fail.

  ;;; Strings (the review: every string)

  ;; same? : String String -> Boolean     equal, the lengths compared first
  (define (same? a b)
    (and (= (string-length a) (string-length b)) (string=? a b)))

  ;; allowed-char? : Char Boolean -> Boolean
  ;; Not U+0000, and no noncharacter: U+FDD0 to U+FDEF, and the last two
  ;; code points of each plane. JSContact is I-JSON (RFC 7493). And no
  ;; control character: U+0000 to U+001F, U+007F, U+0080 to U+009F; but a
  ;; line feed (U+000A) when LINES? is true. And no line or paragraph
  ;; separator (U+2028, U+2029): the line feed is the only line break.
  (define (allowed-char? c lines?)
    (let ((n (char->integer c)))
      (not (or (and (< n #x20) (not (and lines? (= n #xA))))
               (<= #x7F n #x9F)
               (<= #x2028 n #x2029)
               (<= #xFDD0 n #xFDEF)
               (= (bitwise-and n #xFFFE) #xFFFE)))))

  ;; blank-char? : Char -> Boolean
  ;; White space, or a zero-width character: what shows nothing by itself.
  ;; The list is written out, so that it cannot move with Chez's Unicode
  ;; tables: a rule once shipped is never tightened (P3). It is Unicode's
  ;; White_Space, less the control characters but the line feed, and
  ;; U+200B to U+200D, U+2060 and U+FEFF.
  (define (blank-char? c)
    (let ((n (char->integer c)))
      (or (= n #x20) (= n #xA) (= n #xA0) (= n #x1680)
          (<= #x2000 n #x200D)
          (<= #x2028 n #x2029)
          (= n #x202F) (= n #x205F) (= n #x2060) (= n #x3000) (= n #xFEFF))))

  ;; text? : Any Natural Boolean -> Boolean
  ;; A string of at most LIMIT characters, each allowed-char? (with
  ;; LINES?), and at least one of them no blank-char?: so never empty. Its
  ;; length is checked before any character is read.
  (define (text? v limit lines?)
    (and (string? v)
         (<= 1 (string-length v) limit)
         (let ((n (string-length v)))
           (let loop ((i 0) (shown? #f))
             (if (= i n)
                 shown?
                 (let ((c (string-ref v i)))
                   (and (allowed-char? c lines?)
                        (loop (+ i 1) (or shown? (not (blank-char? c)))))))))))

  ;; text-limit : Natural     every string's limit, unless a smaller one is given
  (define text-limit 1000)

  ;; text : Judge     any string within the rules: not blank, no control character
  (define (text v) (if (text? v text-limit #f) v fail))

  ;; lines : Judge     the same, but a line feed (U+000A) is taken: an address's full
  (define (lines v) (if (text? v text-limit #t) v fail))

  ;; one-of : String ... -> Judge     exactly one of CHOICES, case and all
  (define (one-of . choices)
    (lambda (v)
      (if (and (string? v) (exists (lambda (c) (same? c v)) choices)) v fail)))

  ;; flag : Judge     JSON true or false
  (define (flag v) (if (boolean? v) v fail))

  ;; whole : Integer Integer -> Judge     an exact integer from LO to HI: 1.0 is none
  (define (whole lo hi)
    (lambda (v) (if (and (integer? v) (exact? v) (<= lo v hi)) v fail)))

  ;; ascii-in? : Char Char Char -> Boolean     C from A to B, by code point
  (define (ascii-in? c a b)
    (and (char<=? a c) (char<=? c b)))

  ;; id? : Any -> Boolean
  ;; RFC 9553's Id: 1 to 255 characters of A-Z, a-z, 0-9, - and _.
  (define (id? v)
    (and (string? v)
         (<= 1 (string-length v) 255)
         (let ((n (string-length v)))
           (let loop ((i 0))
             (or (= i n)
                 (let ((c (string-ref v i)))
                   (and (or (ascii-in? c #\A #\Z) (ascii-in? c #\a #\z) (ascii-in? c #\0 #\9)
                            (char=? c #\-) (char=? c #\_))
                        (loop (+ i 1)))))))))

  ;; an-id : Judge
  (define (an-id v) (if (id? v) v fail))

  ;; country-code : Judge     two capital ASCII letters (P13): not checked against ISO's list
  (define (country-code v)
    (if (and (string? v)
             (= (string-length v) 2)
             (ascii-in? (string-ref v 0) #\A #\Z)
             (ascii-in? (string-ref v 1) #\A #\Z))
        v
        fail))

  ;; atom-char? : Char -> Boolean
  ;; What an email's atom may hold, RFC 5322's atext: an ASCII letter or
  ;; digit, or one of !#$%&'*+-/=?^_`{|}~ . Nothing past ASCII: JSContact
  ;; takes no internationalised address.
  (define (atom-char? c)
    (or (ascii-in? c #\a #\z)
        (ascii-in? c #\A #\Z)
        (ascii-in? c #\0 #\9)
        (and (memv c '(#\! #\# #\$ #\% #\& #\' #\* #\+ #\- #\/ #\= #\? #\^ #\_ #\` #\{ #\| #\} #\~))
             #t)))

  ;; dot-atom? : String Natural Natural -> Boolean
  ;; Whether S from START up to END is atoms joined by single dots: not
  ;; empty, no dot first or last, no two dots together.
  (define (dot-atom? s start end)
    (and (< start end)
         (not (char=? (string-ref s start) #\.))
         (not (char=? (string-ref s (- end 1)) #\.))
         (let loop ((i start))
           (or (= i end)
               (let ((c (string-ref s i)))
                 (if (char=? c #\.)
                     (and (not (char=? (string-ref s (+ i 1)) #\.)) (loop (+ i 1)))
                     (and (atom-char? c) (loop (+ i 1)))))))))

  ;; email-address : Judge
  ;; The review's rule: atoms joined by single dots, an @, atoms joined by
  ;; single dots; at most 254 characters, and the string rules. Narrower
  ;; than RFC 5322: a quoted local part and an address literal are refused.
  (define (email-address v)
    (if (and (text? v 254 #f)
             (let ((n (string-length v)))
               (let loop ((i 0))
                 (cond ((= i n) #f)
                       ((char=? (string-ref v i) #\@)
                        (and (dot-atom? v 0 i) (dot-atom? v (+ i 1) n)))
                       (else (loop (+ i 1)))))))
        v
        fail))

  ;; uri-taken? : String -> Boolean
  ;; uri-string?'s verdict, an RFC 3986 URI with its scheme. It raises only
  ;; on what is no string, and a fuzz of 300,000 strings raised nothing;
  ;; the guard keeps a fault there from carrying the text out in a
  ;; condition, and answers no.
  (define (uri-taken? s)
    (guard (e (#t #f))
      (and (uri-string? s) #t)))

  ;; a-uri : Judge     a string within the rules that uri-string? takes
  (define (a-uri v)
    (if (and (text? v text-limit #f) (uri-taken? v)) v fail))

  ;;; Shapes

  ;; Prop = (List String Judge Any)     a name, its judge, and its default or no-default
  (define (prop name judge . default)
    (list name judge (if (null? default) no-default (car default))))
  (define (prop-name m) (car m))
  (define (prop-judge m) (cadr m))
  (define (prop-default m) (caddr m))

  ;; index-of : (Vector String) String -> (U Natural #f)     where NAME is in NAMES
  (define (index-of names name)
    (let ((n (vector-length names)))
      (let loop ((i 0))
        (cond ((= i n) #f)
              ((same? (vector-ref names i) name) i)
              (else (loop (+ i 1)))))))

  ;; gather : Any (Vector String) (U String #f) -> (U (Vector Any) fail)
  ;; V's members, each value in its name's slot, absent where none was
  ;; given, after the @type member's value is checked to be TYPE (#f: no
  ;; @type here). fail for what is no list of (String . value), a name not
  ;; of NAMES, a name twice, an @type not exactly TYPE. The names are
  ;; counted against NAMES' length, and @type's, before any value is read:
  ;; it walks at most one pair past them, however long V is.
  (define (gather v names type)
    (let* ((n (vector-length names))
           (bound (if type (+ n 1) n))
           (slots (make-vector n absent)))
      (let loop ((l v) (count 0) (typed #f))
        (cond ((null? l)
               (if (or (not typed)
                       (and (string? (cdr typed)) (same? (cdr typed) type)))
                   slots
                   fail))
              ((or (not (pair? l)) (= count bound)) fail)
              (else
               (let ((m (car l)))
                 (if (and (pair? m) (string? (car m)))
                     (if (and type (same? (car m) "@type"))
                         (if typed fail (loop (cdr l) (+ count 1) m))
                         (let ((i (index-of names (car m))))
                           (if (and i (eq? (vector-ref slots i) absent))
                               (begin (vector-set! slots i (cdr m))
                                      (loop (cdr l) (+ count 1) typed))
                               fail)))
                     fail)))))))

  ;; judge-members : (Listof Prop) (Vector Any) -> (U Alist fail)
  ;; Each given member's value judged, in the table's order; a member whose
  ;; value is its default is dropped.
  (define (judge-members members slots)
    (let loop ((ms members) (i 0) (acc '()))
      (if (null? ms)
          (reverse acc)
          (let ((raw (vector-ref slots i)) (m (car ms)))
            (if (eq? raw absent)
                (loop (cdr ms) (+ i 1) acc)
                (let ((x ((prop-judge m) raw)))
                  (cond ((fail? x) fail)
                        ((equal? x (prop-default m)) (loop (cdr ms) (+ i 1) acc))
                        (else (loop (cdr ms) (+ i 1) (cons (cons (prop-name m) x) acc))))))))))

  ;; object : (U String #f) (Listof Prop) (Alist -> Boolean) -> Judge
  ;; A JSContact object of TYPE (#f for the top, which takes no @type and
  ;; may be empty) with MEMBERS, whose canonical form RULE must take. A
  ;; nested object is never empty.
  (define (object type members rule)
    (let ((names (list->vector (map prop-name members))))
      (lambda (v)
        (if (and type (null? v))
            fail
            (let ((slots (gather v names type)))
              (if (fail? slots)
                  fail
                  (let ((out (judge-members members slots)))
                    (if (or (fail? out) (not (rule out))) fail out))))))))

  ;; has? : Alist String -> Boolean     whether a canonical object holds NAME (a dozen members at most)
  (define (has? out name) (and (assoc name out) #t))

  ;; value-of : Alist String -> Any     NAME's value, #f when it is not there (no canonical value is #f)
  (define (value-of out name)
    (let ((m (assoc name out))) (and m (cdr m))))

  ;; needs : String ... -> (Alist -> Boolean)     every one of NAMES given
  (define (needs . names) (lambda (out) (for-all (lambda (n) (has? out n)) names)))

  ;; needs-one : String ... -> (Alist -> Boolean)     at least one of NAMES given
  (define (needs-one . names) (lambda (out) (exists (lambda (n) (has? out n)) names)))

  ;; set-of : String ... -> Judge
  ;; A set (RFC 9553's String[Boolean], every value true) of NAMES, not
  ;; empty, answered in NAMES' order. Its names are counted against their
  ;; number before any value is read.
  (define (set-of . names)
    (let ((v-names (list->vector names)))
      (lambda (v)
        (if (null? v)
            fail
            (let ((slots (gather v v-names #f)))
              (if (and (not (fail? slots))
                       (for-all (lambda (x) (or (eq? x absent) (eq? x #t))) (vector->list slots)))
                  (let loop ((i (- (vector-length v-names) 1)) (acc '()))
                    (cond ((< i 0) acc)
                          ((eq? (vector-ref slots i) absent) (loop (- i 1) acc))
                          (else (loop (- i 1) (cons (cons (vector-ref v-names i) #t) acc)))))
                  fail))))))

  ;; list-of : Judge -> Judge     a JSON array, not empty, each element judged, in the order sent
  (define (list-of judge)
    (lambda (v)
      (if (and (vector? v) (> (vector-length v) 0))
          (let* ((n (vector-length v)) (out (make-vector n)))
            (let loop ((i 0))
              (if (= i n)
                  out
                  (let ((x (judge (vector-ref v i))))
                    (if (fail? x)
                        fail
                        (begin (vector-set! out i x) (loop (+ i 1))))))))
          fail)))

  ;; key<? : (Pair String Any) (Pair String Any) -> Boolean
  (define (key<? a b) (string<? (car a) (car b)))

  ;; id-map : Judge -> Judge
  ;; RFC 9553's Id[T]: an object, not empty, each key an Id and each value
  ;; judged, its entries answered sorted by key. A key given twice is found
  ;; by a hashtable.
  (define (id-map judge)
    (lambda (v)
      (if (pair? v)
          (let ((seen (make-hashtable string-hash string=?)))
            (let loop ((l v) (acc '()))
              (cond ((null? l) (list-sort key<? acc))
                    ((not (pair? l)) fail)
                    (else
                     (let ((m (car l)))
                       (if (and (pair? m) (id? (car m)) (not (hashtable-contains? seen (car m))))
                           (let ((x (judge (cdr m))))
                             (if (fail? x)
                                 fail
                                 (begin (hashtable-set! seen (car m) #t)
                                        (loop (cdr l) (cons (cons (car m) x) acc)))))
                           fail))))))
          fail)))

  ;;; The common members (RFC 9553, 1.5)

  (define contexts (set-of "private" "work"))
  (define address-contexts (set-of "private" "work" "billing" "delivery"))
  (define pref (whole 1 100))

  ;;; The Contact table

  ;; partial-date? : Alist -> Boolean
  ;; RFC 9553's PartialDate: a month needs a year or a day, a day needs a
  ;; month, and what is given is a real date. 29 February with no year is
  ;; one: a date with no year is asked of 2000, a leap year.
  (define (partial-date? out)
    (let ((y (value-of out "year")) (m (value-of out "month")) (d (value-of out "day")))
      (cond (d (and m (real-date? (or y 2000) m d)))
            (m (and y #t))
            (else (and y #t)))))

  (define name-component
    (object "NameComponent"
            (list (prop "kind" (one-of "title" "given" "given2" "surname" "surname2"
                                         "credential" "generation"))
                  (prop "value" text))
            (needs "kind" "value")))

  (define name
    (object "Name"
            (list (prop "components" (list-of name-component))
                  (prop "isOrdered" flag #f))
            (needs "components")))

  (define org-unit
    (object "OrgUnit" (list (prop "name" text)) (needs "name")))

  (define organization
    (object "Organization"
            (list (prop "name" text)
                  (prop "units" (list-of org-unit))
                  (prop "contexts" contexts))
            (needs-one "name" "units")))

  (define title
    (object "Title"
            (list (prop "name" text)
                  (prop "kind" (one-of "title" "role") "title")
                  (prop "organizationId" an-id))
            (needs "name")))

  (define email
    (object "EmailAddress"
            (list (prop "address" email-address)
                  (prop "contexts" contexts)
                  (prop "pref" pref)
                  (prop "label" text))
            (needs "address")))

  (define phone
    (object "Phone"
            (list (prop "number" text)
                  (prop "features" (set-of "mobile" "voice" "text" "video" "main-number"
                                             "textphone" "fax" "pager"))
                  (prop "contexts" contexts)
                  (prop "pref" pref)
                  (prop "label" text))
            (needs "number")))

  (define address-component
    (object "AddressComponent"
            (list (prop "kind" (one-of "room" "apartment" "floor" "building" "number" "name"
                                         "block" "subdistrict" "district" "locality" "region"
                                         "postcode" "country" "direction" "landmark" "postOfficeBox"))
                  (prop "value" text))
            (needs "kind" "value")))

  (define address
    (object "Address"
            (list (prop "components" (list-of address-component))
                  (prop "isOrdered" flag #f)
                  (prop "countryCode" country-code)
                  (prop "full" lines)
                  (prop "contexts" address-contexts)
                  (prop "pref" pref))
            (needs-one "components" "countryCode" "full")))

  (define partial-date
    (object "PartialDate"
            (list (prop "year" (whole 1 9999))
                  (prop "month" (whole 1 12))
                  (prop "day" (whole 1 31)))
            partial-date?))

  (define anniversary
    (object "Anniversary"
            (list (prop "kind" (one-of "birth" "death" "wedding"))
                  (prop "date" partial-date))
            (needs "kind" "date")))

  (define link
    (object "Link"
            (list (prop "uri" a-uri)
                  (prop "kind" (one-of "contact"))
                  (prop "contexts" contexts)
                  (prop "pref" pref)
                  (prop "label" text))
            (needs "uri")))

  (define online-service
    (object "OnlineService"
            (list (prop "service" text)
                  (prop "uri" a-uri)
                  (prop "user" text)
                  (prop "contexts" contexts)
                  (prop "pref" pref)
                  (prop "label" text))
            (needs-one "uri" "user")))

  (define pronouns
    (object "Pronouns"
            (list (prop "pronouns" text)
                  (prop "contexts" contexts)
                  (prop "pref" pref))
            (needs "pronouns")))

  (define speak-to-as
    (object "SpeakToAs"
            (list (prop "grammaticalGender" (one-of "animate" "common" "feminine" "inanimate"
                                                      "masculine" "neuter"))
                  (prop "pronouns" (id-map pronouns)))
            (needs-one "grammaticalGender" "pronouns")))

  ;; titles-in-organizations? : Alist -> Boolean
  ;; Whether every title's organizationId is a key of this contact's
  ;; organizations, found by a hashtable of their keys.
  (define (titles-in-organizations? out)
    (let ((titles (value-of out "titles")))
      (or (not titles)
          (let ((keys (make-hashtable string-hash string=?)))
            (for-each (lambda (entry) (hashtable-set! keys (car entry) #t))
                      (or (value-of out "organizations") '()))
            (for-all (lambda (entry)
                       (let ((id (value-of (cdr entry) "organizationId")))
                         (or (not id) (hashtable-contains? keys id))))
                     titles)))))

  (define contact
    (object #f
            (list (prop "kind" (one-of "individual" "org" "location") "individual")
                  (prop "name" name)
                  (prop "organizations" (id-map organization))
                  (prop "titles" (id-map title))
                  (prop "emails" (id-map email))
                  (prop "phones" (id-map phone))
                  (prop "addresses" (id-map address))
                  (prop "anniversaries" (id-map anniversary))
                  (prop "links" (id-map link))
                  (prop "onlineServices" (id-map online-service))
                  (prop "speakToAs" speak-to-as))
            titles-in-organizations?))

  ;; parse-contact-props : Any -> (U Alist 'invalid)
  ;; From the JSON reader's value for a Contact's props (an object an alist
  ;; of (String . value), a name given twice kept; {} is '(); an array a
  ;; vector; true #t, false #f, null the symbol null), the value checked and
  ;; canonical, as the header says. '() for {}. 'invalid for anything else:
  ;; what is no object; a member not in the table, or of another object; a
  ;; value of the wrong type; a name or an Id given twice, at any depth; an
  ;; empty nested object, Id map, set or array; a set value not true; a
  ;; number not an exact integer in its range; @type at the top, or naming
  ;; another type; a mandatory member missing; a string that is empty, or
  ;; holds a control character (U+0000 to U+001F, U+007F to U+009F; an
  ;; address's full may hold U+000A) or a noncharacter, or is over 1,000
  ;; characters (an email's address 254); an
  ;; email address, uri, countryCode, PartialDate or Id the review's rules
  ;; refuse; an organizationId no key of organizations. Linear in X's size,
  ;; and never raises.
  (define (parse-contact-props x)
    (let ((r (contact x)))
      (if (fail? r) 'invalid r)))
)
