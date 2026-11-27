#!r6rs
;;; (techo links): slice 5b's pure core. A link's types (K1); a path's
;;; type, and the list's ?type= and ?direction=; the list's cursor,
;;; <type>:<id>, read and written; and link-command, the one pure function
;;; by which a link's request is answered, from the two ends' states, the
;;; event and whether the link is there. It asks the lifecycle's table, in
;;; (techo nodes), of each end (ADR-0007, amended 2026-11-26). Pure: no
;;; database, no circuit, no clock.
;;;
;;; Nothing here raises with a request's text: the parsers never raise, and
;;; link-command's and link-cursor's own raises carry no irritant.
(library (techo links)
  (export link-types parse-link-type parse-type-param parse-direction
          parse-link-cursor link-cursor link-command)
  (import (rnrs)
          (only (techo nodes) parse-node-id node-id->string link-events lifecycle-step))

  ;;; The types (K1)

  ;; link-types : (Listof String)
  ;; The three, as K1 names them. The code's list is the truth: a new type
  ;; is a release, not a migration. A page sorts them by name: blocks,
  ;; mentions, related.
  (define link-types '("related" "mentions" "blocks"))

  ;; parse-link-type : Any -> (U String 'invalid)
  ;; A path's type: one of link-types, exactly, as itself. 'invalid for
  ;; anything else: another case, a space, "", what is no string. Never
  ;; raises.
  (define (parse-link-type x)
    (or (and (string? x) (find (lambda (t) (string=? t x)) link-types))
        'invalid))

  ;;; The list's query

  ;; parse-type-param : Any -> (U String #f 'invalid)
  ;; The list's ?type=, as query-one hands it over: #f (not given) is #f,
  ;; every type; one of link-types is itself. 'invalid for anything else:
  ;; "", another case, 'invalid (the parameter given twice), what is no
  ;; string. Never raises.
  (define (parse-type-param x)
    (if (not x) #f (parse-link-type x)))

  ;; parse-direction : Any -> (U 'out 'in 'invalid)
  ;; The list's ?direction=, as query-one hands it over: #f (not given) is
  ;; out; "out" and "in" are themselves. 'invalid for anything else: "",
  ;; another case, 'invalid (given twice), what is no string. Never raises.
  (define (parse-direction x)
    (cond ((not x) 'out)
          ((and (string? x) (string=? x "out")) 'out)
          ((and (string? x) (string=? x "in")) 'in)
          (else 'invalid)))

  ;;; The cursor: a page's next, <type>:<id>

  ;; The longest cursor: the longest type, a colon and an id's 36
  ;; characters. 45 for mentions.
  (define link-cursor-cap
    (+ (fold-left (lambda (n t) (max n (string-length t))) 0 link-types) 1 36))

  ;; colon-index : String -> (U Natural #f)     where its first colon is
  (define (colon-index s)
    (let ((n (string-length s)))
      (let loop ((i 0))
        (cond ((= i n) #f)
              ((char=? (string-ref s i) #\:) i)
              (else (loop (+ i 1)))))))

  ;; parse-link-cursor : Any -> (U (Pair String Bytevector) 'invalid)
  ;; A page's next, as after hands it back: split at the first colon, the
  ;; type before it one of link-types, exactly, and all after it a v7 id's
  ;; text as parse-node-id takes it, in either case. Answers (type . the
  ;; id's 16 bytes). 'invalid for anything else: no colon, a type not of
  ;; the list or in another case, an empty type or id, a v4 id, text after
  ;; the id, 'invalid (given twice), what is no string. A string longer
  ;; than the longest cursor, 45 characters, is refused before it is read
  ;; further. Never raises.
  (define (parse-link-cursor x)
    (if (and (string? x) (<= (string-length x) link-cursor-cap))
        (let ((colon (colon-index x)))
          (if colon
              (let ((type (parse-link-type (substring x 0 colon)))
                    (id (parse-node-id (substring x (+ colon 1) (string-length x)))))
                (if (or (eq? type 'invalid) (eq? id 'invalid))
                    'invalid
                    (cons type id)))
              'invalid))
        'invalid))

  ;; link-cursor : String Bytevector -> String
  ;; A page's next, from its last item's type and the other node's id:
  ;; <type>:<id>, the id as node-id->string writes it, lower case.
  ;; parse-link-cursor reads back every one written with a v7 id. An
  ;; assertion violation, with no irritant, for a type not of link-types;
  ;; node-id->string's for an id that is no 16 bytes.
  (define (link-cursor type id)
    (unless (and (string? type) (member type link-types))
      (assertion-violation 'link-cursor "not a link's type"))
    (string-append type ":" (node-id->string id)))

  ;;; link-command (slice 5b's review, blockers 3 and 5)

  ;; end-state? : Any -> Boolean     a live state's symbol, or #f for no node
  (define (end-state? x)
    (or (not x) (and (memq x '(active archived trashed)) #t)))

  ;; allows-link? : Symbol -> Boolean
  ;; Whether the lifecycle's table allows link in STATE: allow is #t,
  ;; refuse-wrong-state #f. An assertion violation, with no irritant, for
  ;; any other command: the table would answer what no link is.
  (define (allows-link? state) (allows? state 'link))

  ;; allows? : Symbol Symbol -> Boolean
  ;; The same of EVENT, link or unlink. An unlink asks it of the source
  ;; alone, so the table's unlink column is read, not only written down.
  (define (allows? state event)
    (let-values (((next command) (lifecycle-step state event)))
      (case command
        ((allow) #t)
        ((refuse-wrong-state) #f)
        (else (assertion-violation
               'link-command "the lifecycle's table answers a link's event with allow or refuse-wrong-state")))))

  ;; link-command : (U Symbol #f) (U Symbol #f) Symbol Boolean -> Symbol
  ;; A link's request: the source's state, #f when it is no node of the
  ;; account (missing, purged or another account's); the target's, the
  ;; same, for unlink not looked at (any value is ignored: a caller passes
  ;; #f); the event, link or unlink; and whether the link is there, as the
  ;; job read it before any write. The first that applies:
  ;;   1  no source                                      refuse-404
  ;;   2  link, and no target                            refuse-404
  ;;   3  the link is there                              keep for link,
  ;;                                                     unlink for unlink
  ;;                                                     (refuse-wrong-state should
  ;;                                                     the table refuse the
  ;;                                                     source's unlink: no state
  ;;                                                     does)
  ;;   4  unlink, and it is not there                    refuse-404
  ;;   5  lifecycle-step refuses link for the source,
  ;;      or for the target                              refuse-wrong-state
  ;;   6  otherwise                                      link
  ;; Both 404s come before any 409, and a link that is there is kept before
  ;; a state is asked: a PUT retried after an end was trashed is no
  ;; refusal. Commands: link keep unlink refuse-404 refuse-wrong-state.
  ;; An assertion violation, who 'link-command, with no irritant, for an
  ;; event not of link-events, a source's state or a link's target's state
  ;; not active, archived, trashed or #f, and a there? that is no boolean
  ;; (0 and '() are true in Scheme).
  (define (link-command source target event there?)
    (define (bad what) (assertion-violation 'link-command what))
    (unless (memq event link-events) (bad "not a link's event"))
    (unless (end-state? source)
      (bad "the source's state is active, archived, trashed or #f"))
    (when (and (eq? event 'link) (not (end-state? target)))
      (bad "a link's target's state is active, archived, trashed or #f"))
    (unless (boolean? there?) (bad "whether the link is there is a boolean"))
    (cond ((not source) 'refuse-404)
          ((and (eq? event 'link) (not target)) 'refuse-404)
          (there? (cond ((eq? event 'link) 'keep)
                        ((allows? source 'unlink) 'unlink)
                        (else 'refuse-wrong-state)))
          ((eq? event 'unlink) 'refuse-404)
          ((not (and (allows-link? source) (allows-link? target))) 'refuse-wrong-state)
          (else 'link)))
)
