#!r6rs
;;; The props suite: slice 6's props' doorway, (techo props). All pure.
;;;
;;;   the request       request-props: what a create and a replace send, and
;;;                     P11's absent props; what parse-content would refuse
;;;   each kind         a Project's and a Journal's {}; a Note's at; a Task's
;;;                     four members on a create; a Contact's value, by
;;;                     (techo contact); a replace that names no kind
;;;   a Task's replace  the claims about status and closed, compared with the
;;;                     stored ones, the default filled in, exactly (P11, P14,
;;;                     "A Task's props, restated")
;;;   transitions       transition-props, every cell of the task table
;;;   restores          restore-props: P10
;;;   answers           stored-props->json: TODO filled in, nothing else
;;;   round trips       R2 for every kind and each status; R17
;;;   the cap           4,096 bytes of the canonical text as the writer
;;;                     writes it: multi-byte characters, escapes, the
;;;                     request's own text; 'too-large against 'invalid; the
;;;                     largest Task and Note
;;;   the rules         never raises (a hostile sweep); bounded (100,000
;;;                     members); no raise carries props
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (only (chezscheme) make-engine)
        (techo-testing)
        (jsonparse easy)
        (only (techo nodes) node-kinds)
        (techo props))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

;; raised-as : (-> Any) -> (U (List Symbol String (Listof Any)) 'no-raise (List 'other String))
;; An assertion violation as its who, its message and its irritants;
;; 'no-raise when nothing was raised; any other raise as (other text).
(define (raised-as thunk)
  (guard (e ((and (assertion-violation? e) (who-condition? e) (message-condition? e))
             (list (condition-who e) (condition-message e)
                   (if (irritants-condition? e) (condition-irritants e) '())))
            (#t (list 'other (describe e))))
    (thunk)
    'no-raise))

;; raised-text : (-> Any) -> (U String 'no-raise)     the raise as Chez displays it
(define (raised-text thunk)
  (guard (e (#t (describe e)))
    (thunk)
    'no-raise))

(define (string-index-of hay needle)
  (let ((n (string-length needle)) (h (string-length hay)))
    (let loop ((i 0))
      (cond ((> (+ i n) h) #f)
            ((string=? (substring hay i (+ i n)) needle) i)
            (else (loop (+ i 1)))))))

(define (written x) (call-with-string-output-port (lambda (p) (write x p))))

(define now 1764201600000)
(define two-53 9007199254740992)

;; The request's whole object, as parse-content accepts it: KIND #f leaves
;; kind out (a replace that names none), PROPS 'absent leaves props out.
(define (object kind props)
  (append (if kind (list (cons "kind" kind)) '())
          (list (cons "title" "t") (cons "body" "b") (cons "content_type" "text/plain"))
          (if (eq? props 'absent) '() (list (cons "props" props)))))

;; answer : Any -> Any     props-command's ('write . text) as the text; else as it is
(define (answer x)
  (if (and (pair? x) (eq? (car x) 'write)) (cdr x) x))

;; made : String Any -> (U String Symbol (List 'raised String))
;; A create of KIND with PROPS ('absent for none): request-props' refusal
;; before the job, or the stored text or refusal props-command answers in it.
(define (made kind props)
  (attempt
   (lambda ()
     (let ((r (request-props (object kind props) #t)))
       (if (symbol? r) r (answer (props-command kind (draft-for r kind) #f #t now)))))))

;; replaced : String (U String #f) Any String -> (U String Symbol (List 'raised String))
;; A replace of a node of STORED-KIND whose props are STORED, the request
;; naming NAMED (#f for none) with PROPS ('absent for none).
(define (replaced stored-kind named props stored)
  (attempt
   (lambda ()
     (let ((r (request-props (object named props) #f)))
       (if (memq r '(invalid too-large))
           r
           (answer (props-command stored-kind (draft-for r stored-kind) stored #f now)))))))

;; takers : Any -> Any     the kinds a replace naming none finds for PROPS, or its refusal
(define (takers props)
  (attempt (lambda ()
             (let ((r (request-props (object #f props) #f)))
               (if (symbol? r) r (map car r))))))

;; on-the-wire : Alist -> Any     what a client reads back: the answer's value written and parsed
(define (on-the-wire v) (string->json (json->string v)))

;; bytes-of : Any -> Natural     the bytes the writer writes for a value
(define (bytes-of v) (bytevector-length (json->bytevector v)))

(test-begin "props")

(test-equal "cap: 4,096 bytes" 4096 (attempt (lambda () props-cap)))

;;; The request (P11)

(test-equal "request: a create with no props is as {}, for every kind"
  '("{}" "{}" "{}" "{}" "{}")
  (map (lambda (k) (made k 'absent)) '("project" "journal" "note" "task" "contact")))

(test-equal "request: a replace with no props is absent, naming a kind or none"
  '(absent absent absent absent absent absent)
  (attempt (lambda ()
             (map (lambda (k) (request-props (object k 'absent) #f))
                  '("project" "journal" "note" "task" "contact" #f)))))

(test-equal "request: absent props keep the stored text, every kind's, a Task's whole"
  '("{}" "{}" "{\"at\":\"2026-12-01\"}" "{\"status\":\"DONE\",\"closed\":5,\"deadline\":\"2026-12-01\"}"
    "{\"kind\":\"org\"}")
  (list (replaced "project" #f 'absent "{}")
        (replaced "journal" "journal" 'absent "{}")
        (replaced "note" #f 'absent "{\"at\":\"2026-12-01\"}")
        (replaced "task" "task" 'absent "{\"status\":\"DONE\",\"closed\":5,\"deadline\":\"2026-12-01\"}")
        (replaced "contact" #f 'absent "{\"kind\":\"org\"}")))

(test-equal "request: what parse-content refuses is invalid here too, and does not raise"
  '(invalid invalid invalid invalid invalid invalid invalid invalid)
  (map (lambda (args) (attempt (lambda () (apply request-props args))))
       (list (list (object #f '()) #t)                    ; a create names its kind
             (list (object "folder" '()) #t)
             (list (object 'task '()) #f)
             (list (cons '(kind . "task") (object #f '())) #f)
             (list "props" #f)
             (list (vector (object "task" '())) #t)
             (list (cons '("props") 5) #f)                 ; an improper list
             (list (append (object "task" '()) '(("a" . 1) ("b" . 2) ("c" . 3))) #t))))

(test-equal "request: props that are no object are invalid, for every kind and for none"
  '(invalid invalid invalid invalid invalid invalid invalid)
  (map (lambda (p) (attempt (lambda () (request-props (object #f p) #f))))
       (list "{}" 0 (vector) 'null #t #f (vector '()))))

;;; A Project and a Journal: {} alone (P4)

(for-each
 (lambda (k)
   (test-equal (string-append k ": {} is \"{}\" on a create and a replace naming it")
     '("{}" "{}")
     (list (made k '()) (replaced k k '() "{}")))
   (test-equal (string-append k ": any member is invalid, before the job")
     '(invalid invalid invalid invalid invalid invalid invalid invalid)
     (map (lambda (p) (made k p))
          '((("a" . 1)) (("at" . "2026-12-01")) (("status" . "TODO")) (("kind" . "individual"))
            (("@type" . "Card")) (("version" . "1.0")) (("uid" . "x")) (("" . #f))))))
 '("project" "journal"))

;;; A Note: at, a When (P5, P6)

(test-equal "note: {} and an at of each of the three forms"
  '("{}" "{\"at\":\"2026-12-01\"}" "{\"at\":\"2026-12-01T15:00\"}" "{\"at\":\"2026-12-01T20:00:00Z\"}")
  (map (lambda (p) (made "note" p))
       '(() (("at" . "2026-12-01")) (("at" . "2026-12-01T15:00")) (("at" . "2026-12-01T20:00:00Z")))))

(test-equal "note: a replace stores what it sends, and {} clears at"
  '("{\"at\":\"2027-01-01\"}" "{}")
  (list (replaced "note" "note" '(("at" . "2027-01-01")) "{\"at\":\"2026-12-01\"}")
        (replaced "note" #f '() "{\"at\":\"2026-12-01\"}")))

(test-equal "note: what is no When, at twice, another member, and no Note's member are invalid"
  (map (lambda (x) 'invalid) '(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15))
  (map (lambda (p) (made "note" p))
       '((("at" . "2026-12-01T24:00")) (("at" . "1900-02-29")) (("at" . "+026-12-01"))
         (("at" . "2026-12-01 15:00")) (("at" . "2026-02-30")) (("at" . "")) (("at" . null))
         (("at" . 20261201)) (("at" . "2026-12-01") ("at" . "2026-12-01"))
         (("at" . "2026-12-01") ("x" . 1)) (("deadline" . "2026-12-01")) (("status" . "TODO"))
         (("@type" . "Card")) (("uid" . "x")) (("At" . "2026-12-01")))))

;;; A Task, made (P7, P14; "A Task's props, restated")

(test-equal "task create: none given is TODO, stored as {}; TODO given is not stored"
  '("{}" "{}" "{}")
  (list (made "task" 'absent) (made "task" '()) (made "task" '(("status" . "TODO")))))

(test-equal "task create: DONE or WONTDO with no closed is closed at the write's time"
  (list (string-append "{\"status\":\"DONE\",\"closed\":" (number->string now) "}")
        (string-append "{\"status\":\"WONTDO\",\"closed\":" (number->string now) "}"))
  (list (made "task" '(("status" . "DONE"))) (made "task" '(("status" . "WONTDO")))))

(test-equal "task create: an import's closed is kept when the status is not TODO (P14), 0 and 2^53 - 1 too"
  '("{\"status\":\"WONTDO\",\"closed\":5}" "{\"status\":\"DONE\",\"closed\":0}"
    "{\"status\":\"DONE\",\"closed\":9007199254740991}")
  (list (made "task" '(("status" . "WONTDO") ("closed" . 5)))
        (made "task" '(("status" . "DONE") ("closed" . 0)))
        (made "task" (list (cons "status" "DONE") (cons "closed" (- two-53 1))))))

(test-equal "task create: closed with TODO, given or by default, is invalid, before the job"
  '(invalid invalid invalid)
  (list (made "task" '(("status" . "TODO") ("closed" . 5)))
        (made "task" '(("closed" . 5)))
        (made "task" '(("closed" . 0) ("deadline" . "2026-12-01")))))

(test-equal "task create: the members in the plan's order, whatever order they were sent in"
  (list "{\"status\":\"DONE\",\"closed\":7,\"deadline\":\"2026-12-01\",\"scheduled\":\"2026-11-30T09:00\"}"
        "{\"deadline\":\"2026-12-01T20:00:00Z\",\"scheduled\":\"2026-11-30\"}")
  (list (made "task" '(("scheduled" . "2026-11-30T09:00") ("deadline" . "2026-12-01")
                       ("closed" . 7) ("status" . "DONE")))
        (made "task" '(("scheduled" . "2026-11-30") ("status" . "TODO")
                       ("deadline" . "2026-12-01T20:00:00Z")))))

(test-equal "task create: a status, a closed, a When of the wrong value is invalid"
  (map (lambda (x) 'invalid) '(1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18))
  (map (lambda (p) (made "task" p))
       (list '(("status" . "todo")) '(("status" . "Done")) '(("status" . "")) '(("status" . null))
             '(("status" . 1)) '(("status" . #f))
             '(("status" . "DONE") ("closed" . 1.7e12)) '(("status" . "DONE") ("closed" . 1.0))
             '(("status" . "DONE") ("closed" . -1)) '(("status" . "DONE") ("closed" . null))
             '(("status" . "DONE") ("closed" . "5")) '(("status" . "DONE") ("closed" . #t))
             (list (cons "status" "DONE") (cons "closed" two-53))
             '(("deadline" . "2026-12-01T24:00")) '(("deadline" . "1900-02-29"))
             '(("scheduled" . "+026-12-01")) '(("deadline" . null)) '(("scheduled" . 5)))))

(test-equal "task: a name twice, a Contact's member, another kind's, a Card's and a fifth member are invalid"
  (map (lambda (x) 'invalid) '(1 2 3 4 5 6 7 8 9 10 11 12))
  (map (lambda (p) (made "task" p))
       '((("status" . "DONE") ("status" . "DONE")) (("deadline" . "2026-12-01") ("deadline" . "2026-12-01"))
         (("emails" ("e1" ("address" . "a@b")))) (("kind" . "individual")) (("name" ("components" . #())))
         (("at" . "2026-12-01")) (("@type" . "Card")) (("version" . "1.0")) (("uid" . "x"))
         (("Status" . "DONE")) (("closed" . 1) ("status" . "DONE") ("deadline" . "2026-12-01")
                                ("scheduled" . "2026-12-01") ("x" . 1))
         (("status" . "DONE") ("closed" . 1) ("deadline" . "2026-12-01") ("scheduled" . "2026-12-01")
          ("status" . "DONE")))))

;;; A Task, replaced: the claims about status and closed (P11, "Answers the plan lacked")

(define done-5 "{\"status\":\"DONE\",\"closed\":5}")
(define done-5-d "{\"status\":\"DONE\",\"closed\":5,\"deadline\":\"2026-12-01\"}")

(test-equal "task replace: \"status\":\"TODO\" against a stored {} is taken, and {} is stored"
  '("{}" "{}")
  (list (replaced "task" "task" '(("status" . "TODO")) "{}")
        (replaced "task" #f '(("status" . "TODO")) "{}")))

(test-equal "task replace: claims equal to what is stored are taken, alone or together; the two kept"
  (list done-5 done-5 done-5 done-5)
  (list (replaced "task" "task" '(("status" . "DONE") ("closed" . 5)) done-5-d)
        (replaced "task" "task" '(("status" . "DONE")) done-5-d)
        (replaced "task" #f '(("closed" . 5)) done-5-d)
        (replaced "task" "task" '() done-5-d)))

(test-equal "task replace: any claim that differs is status_fixed, in the job"
  (map (lambda (x) 'refuse-status-fixed) '(1 2 3 4 5 6 7 8))
  (list (replaced "task" "task" '(("status" . "DONE")) "{}")
        (replaced "task" #f '(("status" . "WONTDO")) "{}")
        (replaced "task" "task" '(("closed" . 5)) "{}")
        (replaced "task" "task" '(("status" . "TODO") ("closed" . 5)) "{}")
        (replaced "task" "task" '(("status" . "WONTDO")) done-5)
        (replaced "task" "task" '(("status" . "TODO")) done-5)
        (replaced "task" #f '(("closed" . 6)) done-5)
        (replaced "task" "task" '(("status" . "DONE") ("closed" . 4)) done-5)))

(test-equal "task replace: closed is compared exactly: a claim of 5 is not a stored 5.0"
  '(refuse-status-fixed "{\"status\":\"DONE\",\"closed\":5.0}")
  (list (replaced "task" "task" '(("closed" . 5)) "{\"status\":\"DONE\",\"closed\":5.0}")
        (replaced "task" "task" '() "{\"status\":\"DONE\",\"closed\":5.0}")))

(test-equal "task replace: deadline and scheduled are what was sent; one left out is removed"
  '("{\"status\":\"DONE\",\"closed\":5,\"deadline\":\"2027-01-01\"}"
    "{\"status\":\"DONE\",\"closed\":5,\"scheduled\":\"2026-12-02T08:00\"}"
    "{\"deadline\":\"2026-12-03\",\"scheduled\":\"2026-12-02\"}")
  (list (replaced "task" "task" '(("deadline" . "2027-01-01")) done-5-d)
        (replaced "task" #f '(("scheduled" . "2026-12-02T08:00") ("status" . "DONE")) done-5-d)
        (replaced "task" "task" '(("scheduled" . "2026-12-02") ("deadline" . "2026-12-03"))
                  "{\"deadline\":\"2026-12-01\"}")))

(test-equal "task replace: closed with TODO is no 400 on a replace: it is compared, and differs"
  'refuse-status-fixed
  (replaced "task" "task" '(("status" . "TODO") ("closed" . 5)) done-5))

(test-equal "task replace: what fails as a Task's props is invalid before the job, whatever is stored"
  '(invalid invalid invalid)
  (list (replaced "task" "task" '(("status" . "done")) "{}")
        (replaced "note" "task" '(("at" . "2026-12-01")) "{}")
        (replaced "task" "task" '(("closed" . 1.0)) done-5)))

;;; A replace that names no kind (blocker 1): each kind's verdict before the job

(test-equal "no kind: {} is taken by all five, in the kinds' order"
  '("project" "journal" "note" "task" "contact")
  (takers '()))

(test-equal "no kind: the kinds props judges are (techo nodes)' five, in its order"
  (attempt (lambda () node-kinds))
  (takers '()))

(test-equal "no kind: at is a Note's alone; status, closed, deadline, scheduled a Task's; a Contact's members its own"
  '(("note") ("note") ("task") ("task") ("task") ("contact") ("contact") ("contact"))
  (map takers
       '((("at" . "2026-12-01")) (("at" . "2026-12-01T20:00:00Z")) (("status" . "TODO"))
         (("closed" . 5)) (("deadline" . "2026-12-01") ("scheduled" . "2026-12-02"))
         (("kind" . "org")) (("kind" . "individual")) (("emails" ("e1" ("address" . "a@b")))))))

(test-equal "no kind: what no kind takes is invalid"
  '(invalid invalid invalid invalid invalid)
  (map takers '((("a" . 1)) (("at" . "nope")) (("at" . "2026-12-01") ("status" . "TODO"))
                (("@type" . "Card")) (("status" . "DONE") ("emails" ("e1" ("address" . "a@b")))))))

(test-equal "no kind: props that suit only another kind are invalid in the job, for the stored kind"
  '(refuse-invalid-props refuse-invalid-props refuse-invalid-props refuse-invalid-props)
  (list (replaced "task" #f '(("at" . "2026-12-01")) "{}")
        (replaced "note" #f '(("status" . "TODO")) "{}")
        (replaced "project" #f '(("kind" . "org")) "{}")
        (replaced "contact" #f '(("deadline" . "2026-12-01")) "{}")))

(test-equal "no kind: the stored kind's Draft is stored: {} clears all but a Task's status and closed (R13)"
  (list "{}" "{}" "{}" done-5 "{}")
  (map (lambda (k s) (replaced k #f '() s))
       '("project" "journal" "note" "task" "contact")
       (list "{}" "{}" "{\"at\":\"2026-12-01\"}" done-5-d "{\"kind\":\"org\"}")))

;;; draft-for: the stored kind's Draft, for a job

(test-equal "draft-for: absent is absent; a kind with no Draft is #f"
  '(absent #f #f)
  (attempt (lambda ()
             (let ((r (request-props (object #f '(("at" . "2026-12-01"))) #f)))
               (list (draft-for 'absent "task") (draft-for r "task") (draft-for r "contact"))))))

(test-equal "draft-for: a refusal, or what is no kind, raises with no irritant"
  (map (lambda (x) '(draft-for "not request-props' Drafts and a kind" ())) '(1 2 3))
  (map (lambda (args) (raised-as (lambda () (apply draft-for args))))
       (list (list 'invalid "task") (list 'too-large "contact") (list 'absent "folder"))))

;;; A Contact: its rules are (techo contact)'s; here, what props make of them

(test-equal "contact: {} and an explicit default are {}; a kind given is kept"
  '("{}" "{}" "{\"kind\":\"org\"}")
  (list (made "contact" '()) (made "contact" '(("kind" . "individual")))
        (made "contact" '(("kind" . "org")))))

(define emails-a
  '(("emails" ("zz" ("address" . "z@b") ("label" . "work")) ("a1" ("address" . "a@b")))))
(define emails-b
  '(("emails" ("a1" ("address" . "a@b")) ("zz" ("label" . "work") ("address" . "z@b")))))

(test-equal "contact: R17, one text whatever order the Id map and its members were sent in"
  '("{\"emails\":{\"a1\":{\"address\":\"a@b\"},\"zz\":{\"address\":\"z@b\",\"label\":\"work\"}}}" #t #t)
  (let ((a (made "contact" emails-a)))
    (list a (equal? a (made "contact" emails-b))
          (equal? a (replaced "contact" #f emails-b "{}")))))

(test-equal "contact: a Card's members at the top, a Task's, a Note's, an Id twice, pref 1.0: invalid"
  '(invalid invalid invalid invalid invalid invalid invalid invalid)
  (map (lambda (p) (made "contact" p))
       '((("@type" . "Card")) (("version" . "1.0")) (("uid" . "x")) (("status" . "TODO"))
         (("at" . "2026-12-01")) (("emails" ("e1" ("address" . "a@b")) ("e1" ("address" . "c@d"))))
         (("emails" ("e1" ("address" . "a@b") ("pref" . 1.0))))
         (("kind" . "individual") ("kind" . "individual")))))

;;; Transitions (the task table's commands)

(define (moved stored next command)
  (attempt (lambda () (transition-props stored next command now))))
(define closed-now (number->string now))

(test-equal "transition: close sets closed to now; keep leaves it; open removes it; deadline and scheduled kept"
  (list (string-append "{\"status\":\"DONE\",\"closed\":" closed-now ",\"deadline\":\"2026-12-01\"}")
        (string-append "{\"status\":\"WONTDO\",\"closed\":" closed-now ",\"scheduled\":\"2026-12-02\"}")
        "{\"status\":\"WONTDO\",\"closed\":5,\"deadline\":\"2026-12-01\"}"
        "{\"deadline\":\"2026-12-01\"}"
        "{\"status\":\"DONE\",\"closed\":5}"
        "{\"scheduled\":\"2026-12-02\"}")
  (list (moved "{\"deadline\":\"2026-12-01\"}" 'DONE 'close)
        (moved "{\"scheduled\":\"2026-12-02\"}" 'WONTDO 'close)
        (moved done-5-d 'WONTDO 'keep)
        (moved done-5-d 'TODO 'open)
        (moved "{\"status\":\"WONTDO\",\"closed\":5}" 'DONE 'keep)
        (moved "{\"status\":\"WONTDO\",\"closed\":5,\"scheduled\":\"2026-12-02\"}" 'TODO 'open)))

(test-equal "transition: a Task stored {} is closed by done and by wontdo"
  (list (string-append "{\"status\":\"DONE\",\"closed\":" closed-now "}")
        (string-append "{\"status\":\"WONTDO\",\"closed\":" closed-now "}"))
  (list (moved "{}" 'DONE 'close) (moved "{}" 'WONTDO 'close)))

(test-equal "transition: a status and a command that do not go together, or of no known value, raise with no irritant"
  (map (lambda (x) '(transition-props "not a task's next status and command" ())) '(1 2 3 4 5 6))
  (map (lambda (args) (raised-as (lambda () (apply transition-props args))))
       (list (list done-5 'TODO 'keep now) (list done-5 'DONE 'open now) (list "{}" 'TODO 'close now)
             (list "{}" 'done 'close now) (list "{}" 'DONE 'refuse-wrong-status now)
             (list "{}" "DONE" 'close now))))

;;; Restores (P10)

(define (restored kind snapshot stored)
  (attempt (lambda () (restore-props kind snapshot stored))))

(test-equal "restore: a Task's snapshot gives deadline and scheduled; status and closed stay the node's"
  '("{\"status\":\"DONE\",\"closed\":5,\"deadline\":\"2026-01-01\",\"scheduled\":\"2026-01-02\"}"
    "{\"status\":\"DONE\",\"closed\":5}"
    "{}"
    "{\"deadline\":\"2026-01-01\"}")
  (list (restored "task" "{\"status\":\"WONTDO\",\"closed\":9,\"deadline\":\"2026-01-01\",\"scheduled\":\"2026-01-02\"}"
                  done-5-d)
        (restored "task" "{}" done-5-d)
        (restored "task" "{\"status\":\"DONE\",\"closed\":9}" "{}")
        (restored "task" "{\"status\":\"WONTDO\",\"closed\":9,\"deadline\":\"2026-01-01\"}" "{}")))

(test-equal "restore: another kind's snapshot is taken whole"
  '("{\"at\":\"2026-12-01\"}" "{}" "{\"kind\":\"org\"}" "{}" "{}")
  (list (restored "note" "{\"at\":\"2026-12-01\"}" "{}")
        (restored "note" "{}" "{\"at\":\"2026-12-01\"}")
        (restored "contact" "{\"kind\":\"org\"}" "{}")
        (restored "project" "{}" "{}")
        (restored "journal" "{}" "{}")))

;;; Answers: stored-props->json

(define (shown kind text) (attempt (lambda () (stored-props->json kind text))))

(test-equal "answer: a Task's status is filled in when absent, first; nothing else is"
  '((("status" . "TODO"))
    (("status" . "TODO") ("deadline" . "2026-12-01"))
    (("status" . "DONE") ("closed" . 5) ("deadline" . "2026-12-01")))
  (list (shown "task" "{}") (shown "task" "{\"deadline\":\"2026-12-01\"}") (shown "task" done-5-d)))

(test-equal "answer: another kind's props as stored; a Contact stored {} is {}"
  '(() () () (("at" . "2026-12-01")) () (("kind" . "org")))
  (list (shown "project" "{}") (shown "journal" "{}") (shown "note" "{}")
        (shown "note" "{\"at\":\"2026-12-01\"}") (shown "contact" "{}")
        (shown "contact" "{\"kind\":\"org\"}")))

;;; Round trips (R2): read back, sent again unchanged, the same bytes

(define emoji (integer->char #x1F600))
(define backslash #\\)

;; contact-of : (Listof String) -> Alist     a Contact of one email per label, ids e1, e2, ...
(define (contact-of labels)
  (list (cons "emails"
              (let loop ((ls labels) (i 1) (acc '()))
                (if (null? ls)
                    (reverse acc)
                    (loop (cdr ls) (+ i 1)
                          (cons (cons (string-append "e" (number->string i))
                                      (list (cons "address" "a@b") (cons "label" (car ls))))
                                acc)))))))

;; sized : Natural Char -> Alist
;; A Contact of five emails whose text, as the writer writes it, is exactly
;; N bytes: each label gets an equal share of the bytes (none is empty, a
;; Contact's string is never empty), made of C as far as its share goes, at
;; most 1,000 characters in all, the rest ASCII x's.
(define (sized n c)
  (let* ((k 5)
         (base (bytes-of (contact-of (list "" "" "" "" ""))))
         (w (- (bytes-of (vector (string c))) 4))
         (left (- n base))
         (q (div left k))
         (r (mod left k)))
    (let loop ((i 0) (acc '()))
      (if (= i k)
          (contact-of (reverse acc))
          (let* ((b (if (< i r) (+ q 1) q))
                 (m (div b w))
                 (pad (- b (* m w))))
            (if (or (< b 1) (> (+ m pad) 1000))
                (assertion-violation 'sized "no room for the bytes asked" n)
                (loop (+ i 1) (cons (string-append (make-string m c) (make-string pad #\x)) acc))))))))

(define corpus
  (list (list "project" '())
        (list "journal" '())
        (list "note" '())
        (list "note" '(("at" . "2026-12-01")))
        (list "note" '(("at" . "2026-12-01T15:00")))
        (list "note" '(("at" . "2026-12-01T20:00:00Z")))
        (list "task" '())
        (list "task" '(("status" . "TODO") ("deadline" . "2026-12-01")))
        (list "task" '(("status" . "DONE")))
        (list "task" '(("scheduled" . "2026-12-01T09:00") ("status" . "WONTDO") ("closed" . 1700000000000)))
        (list "task" '(("deadline" . "2026-12-24") ("scheduled" . "2026-12-01T20:00:00Z")))
        (list "contact" '())
        (list "contact" '(("kind" . "org")))
        (list "contact" emails-a)
        (list "contact" (list (cons "name" (list (cons "components"
                                                       (vector '(("kind" . "given") ("value" . "Ada"))
                                                               '(("kind" . "surname") ("value" . "Lovelace"))))
                                                 (cons "isOrdered" #t)))))
        (list "contact" (attempt (lambda () (sized 4096 emoji))))))

;; round-trip : String Any Boolean -> Any
;; The text a create stores, then a replace of what stored-props->json
;; answers for it, as a client reads it off the wire, naming the kind or
;; none: #t when the replace stores the same bytes, else what each gave.
(define (round-trip kind props named?)
  (let* ((first (made kind props))
         (back (attempt (lambda () (on-the-wire (stored-props->json kind first)))))
         (second (replaced kind (and named? kind) back first)))
    (if (and (string? first) (equal? first second)) #t (list first back second))))

(for-each
 (lambda (c)
   (for-each
    (lambda (named?)
      (test-equal (string-append "R2: " (car c) " " (written (cadr c)) (if named? ", named" ", no kind"))
        #t
        (round-trip (car c) (cadr c) named?)))
    '(#t #f)))
 corpus)

(test-equal "R2: a Task after each transition reads back and is sent back as it was stored"
  '(#t #t #t #t #t #t)
  (map (lambda (s)
         (let ((back (attempt (lambda () (on-the-wire (stored-props->json "task" s))))))
           (or (and (string? s) (equal? s (replaced "task" "task" back s))) (list s back))))
       (list (moved "{}" 'DONE 'close) (moved "{}" 'WONTDO 'close) (moved done-5-d 'WONTDO 'keep)
             (moved done-5-d 'TODO 'open) (moved "{\"status\":\"WONTDO\",\"closed\":5}" 'DONE 'keep)
             (moved "{\"status\":\"WONTDO\",\"closed\":5}" 'TODO 'open))))

;;; A Task stored {} (P9), through every function

(test-equal "a Task stored {}: read as TODO, replaced, transitioned, restored, sent back"
  (list '(("status" . "TODO")) "{}" "{}" "{}" "{\"deadline\":\"2026-12-01\"}"
        (string-append "{\"status\":\"DONE\",\"closed\":" closed-now "}")
        "{\"deadline\":\"2026-01-01\"}" #t)
  (list (shown "task" "{}")
        (replaced "task" "task" '(("status" . "TODO")) "{}")
        (replaced "task" #f '() "{}")
        (replaced "task" "task" 'absent "{}")
        (replaced "task" "task" '(("deadline" . "2026-12-01")) "{}")
        (moved "{}" 'DONE 'close)
        (restored "task" "{\"deadline\":\"2026-01-01\"}" "{}")
        (round-trip "task" '() #t)))

;;; The cap: 4,096 bytes of the canonical text, as the writer writes it (P2)

(test-equal "cap: the corpus' helper makes texts of exactly the bytes asked"
  '(4096 4097 4096 4097 4096 4097 4096 4097)
  (attempt (lambda ()
             (map (lambda (n c) (bytes-of (sized n c)))
                  '(4096 4097 4096 4097 4096 4097 4096 4097)
                  (list #\x #\x emoji emoji backslash backslash #\" #\")))))

;; capped : Natural Char -> (List (U Natural Symbol) (U Natural Symbol))
;; A Contact of N bytes made of C, made: the stored text's bytes or the
;; refusal, and the number of characters in its text as written.
(define (capped n c)
  (let ((r (made "contact" (attempt (lambda () (sized n c))))))
    (if (string? r)
        (list (bytevector-length (string->utf8 r)) 'stored)
        r)))

(test-equal "cap: 4,096 bytes of ASCII is taken; 4,097 is too large"
  '((4096 stored) too-large)
  (list (capped 4096 #\x) (capped 4097 #\x)))

(test-equal "cap: bytes, not characters: 4,096 bytes of four-byte characters is taken, 4,097 too large"
  '((4096 stored) too-large #t)
  (list (capped 4096 emoji) (capped 4097 emoji)
        (attempt (lambda () (< (string-length (json->string (sized 4097 emoji))) 1300)))))

(test-equal "cap: an escape counts as written: a quote or a backslash costs two bytes"
  '((4096 stored) too-large (4096 stored) too-large #t)
  (list (capped 4096 backslash) (capped 4097 backslash) (capped 4096 #\") (capped 4097 #\")
        (attempt (lambda () (< (string-length (apply string-append (map (lambda (e) (cdr (assoc "label" (cdr e))))
                                                                        (cdr (assoc "emails" (sized 4097 backslash))))))
                               2100)))))

(test-equal "cap: on the canonical text, not the request's: a default sent makes 4,116 bytes, stored 4,096"
  '(4116 (4096 stored))
  (let ((sent (attempt (lambda () (cons (cons "kind" "individual") (sized 4096 #\x))))))
    (list (attempt (lambda () (bytes-of sent)))
          (let ((r (made "contact" sent)))
            (if (string? r) (list (bytevector-length (string->utf8 r)) 'stored) r)))))

(test-equal "cap: a replace too, naming the kind or none"
  '(too-large too-large #t)
  (let ((big (attempt (lambda () (sized 4097 #\x)))))
    (list (replaced "contact" "contact" big "{}") (replaced "contact" #f big "{}")
          (string? (replaced "contact" #f (attempt (lambda () (sized 4096 #\x))) "{}")))))

(test-equal "cap: invalid comes before too large, however large"
  '(invalid invalid invalid invalid)
  (let ((big (attempt (lambda () (sized 4097 #\x)))))
    (list (made "contact" (cons '("version" . "1.0") big))
          (replaced "contact" #f (cons '("version" . "1.0") big) "{}")
          (made "task" big)
          (replaced "task" "task" big "{}"))))

(test-equal "cap: props-command refuses a Draft over the cap, and takes one at it"
  '(refuse-props-too-large 4096)
  (let ((text (lambda (n) (string-append "{\"at\":\"" (make-string (- n 9) #\x) "\"}"))))
    (list (attempt (lambda () (props-command "note" (text 4097) #f #t now)))
          (attempt (lambda () (string-length (answer (props-command "note" (text 4096) "{}" #f now))))))))

(test-equal "cap: the largest Task's props are 114 bytes and the largest Note's 29, far under the cap"
  '(114 29 #t)
  (let ((task (made "task" (list (cons "scheduled" "2026-12-01T20:00:00Z") (cons "status" "WONTDO")
                                 (cons "deadline" "2026-12-01T20:00:00Z") (cons "closed" (- two-53 1)))))
        (note (made "note" '(("at" . "2026-12-01T20:00:00Z")))))
    (list (if (string? task) (string-length task) task)
          (if (string? note) (string-length note) note)
          (and (string? task) (< (* 30 (string-length task)) props-cap)))))

;;; Bounded: a props of 100,000 members is refused after a few names

;; fuel : (-> Any) Natural -> (U (List 'done Any) 'expired)
;; THUNK's answer when it finishes within TICKS of Chez's engine timer, a
;; walk of 100,000 pairs costs 50,000 or more; else 'expired.
(define (fuel thunk ticks)
  ((make-engine thunk) ticks
   (lambda (left . vals) (cons 'done vals))
   (lambda (engine) 'expired)))

(define many (let loop ((i 0) (acc '()))
               (if (= i 100000) acc (loop (+ i 1) (cons (cons "status" "TODO") acc)))))
(define many-x (let loop ((i 0) (acc '()))
                 (if (= i 100000) acc (loop (+ i 1) (cons (cons (number->string i) i) acc)))))

(test-equal "bounded: 100,000 members are refused within 20,000 ticks, for each kind named and for none"
  (map (lambda (x) '(done invalid)) '(1 2 3 4 5 6 7 8 9 10 11 12))
  (apply append
         (map (lambda (props)
                (map (lambda (args) (fuel (lambda () (request-props (object (car args) props) (cadr args)))
                                          20000))
                     '(("task" #t) ("note" #t) ("project" #f) ("contact" #t) ("journal" #t) (#f #f))))
              (list many many-x))))

;;; Never raises: a hostile sweep

(define (make-lcg seed)
  (let ((state seed))
    (lambda (n)
      (set! state (mod (+ (* state 1103515245) 12345) 2147483648))
      (mod (div state 65536) n))))

(define fuzz-names '("status" "closed" "deadline" "scheduled" "at" "kind" "emails" "@type" "" "x"))
(define fuzz-atoms
  (list "TODO" "DONE" "WONTDO" "todo" "2026-12-01" "2026-12-01T15:00" "2026-12-01T20:00:00Z"
        "2026-02-30" "" "org" "individual" "a@b" 0 5 -1 1.0 1.7e12 two-53 'null #t #f '() (vector)
        'sym (string (integer->char 0)) (make-string 1001 #\x)))

(define (fuzz-value next depth)
  (case (next 6)
    ((0 1 2) (list-ref fuzz-atoms (next (length fuzz-atoms))))
    ((3) (if (> depth 0) (vector (fuzz-value next (- depth 1))) "flat"))
    ((4) (cons (fuzz-value next 0) (fuzz-value next 0)))
    (else (if (> depth 0) (fuzz-object next (- depth 1)) '()))))

(define (fuzz-object next depth)
  (let loop ((k (next 6)) (acc '()))
    (if (= k 0)
        acc
        (loop (- k 1)
              (cons (if (= 0 (next 12))
                        (fuzz-value next 0)
                        (cons (list-ref fuzz-names (next (length fuzz-names))) (fuzz-value next depth)))
                    acc)))))

;; well-formed? : Any Boolean -> Boolean
;; Whether R is one of request-props' answers: a refusal, absent on a
;; replace, or kinds in the kinds' order, each with a Draft props-command
;; takes without a raise.
(define (well-formed? r create?)
  (cond ((memq r '(invalid too-large)) #t)
        ((eq? r 'absent) (not create?))
        ((and (list? r) (pair? r))
         (and (for-all (lambda (p) (and (pair? p) (member (car p) '("project" "journal" "note" "task" "contact"))))
                       r)
              (let ((ks (map car r)))
                (equal? ks (filter (lambda (k) (member k ks)) '("project" "journal" "note" "task" "contact"))))
              (or (not create?) (= (length r) 1))
              (for-all (lambda (p)
                         (let ((a (guard (e (#t 'raised))
                                    (props-command (car p) (cdr p) (if create? #f "{}") create? now))))
                           (or (and (pair? a) (eq? (car a) 'write) (string? (cdr a)))
                               (memq a '(refuse-invalid-props refuse-props-too-large refuse-status-fixed)))))
                       r)))
        (else #f)))

(test-equal "never raises: 4,000 hostile objects, as the request or as its props"
  'ok
  (let ((next (make-lcg 20261127)))
    (let loop ((n 0) (taken 0))
      (if (= n 4000)
          (if (> taken 100) 'ok (list 'too-few-taken taken))
          (let* ((create? (= 0 (next 2)))
                 (kind (list-ref '(#f "task" "note" "project" "journal" "contact" "folder") (next 7)))
                 (x (case (next 6)
                      ((0) (fuzz-value next 2))
                      ((1) (fuzz-object next 2))
                      (else (object kind (fuzz-object next 2)))))
                 (r (guard (e (#t (list 'raised (describe e)))) (request-props x create?))))
            (if (well-formed? r create?)
                (loop (+ n 1) (if (pair? r) (+ taken 1) taken))
                (list 'bad x create? r)))))))

;;; No raise carries props (ADR-0013: a job's raise is logged whole)

(define secret "{\"deadline\":\"SECRET-PROPS\"")

(test-equal "no raise carries props: stored text that is not JSON raises with no irritant, in every reader"
  '((stored-props->json "stored props are not a JSON object" ())
    (stored-props->json "stored props are not a JSON object" ())
    (props-command "stored props are not a JSON object" ())
    (transition-props "stored props are not a JSON object" ())
    (restore-props "stored props are not a JSON object" ())
    (restore-props "stored props are not a JSON object" ()))
  (list (raised-as (lambda () (stored-props->json "task" secret)))
        (raised-as (lambda () (stored-props->json "contact" "[\"SECRET-PROPS\"]")))
        (raised-as (lambda () (props-command "task" (draft-for (request-props (object "task" '()) #f) "task")
                                             secret #f now)))
        (raised-as (lambda () (transition-props secret 'DONE 'close now)))
        (raised-as (lambda () (restore-props "task" secret "{}")))
        (raised-as (lambda () (restore-props "task" "{}" secret)))))

(test-equal "no raise carries props: each raises, and none of the raise's text is the props'"
  '(#t #t #t #t)
  (map (lambda (thunk) (let ((t (raised-text thunk))) (and (string? t) (not (string-index-of t "SECRET")))))
       (list (lambda () (stored-props->json "note" secret))
             (lambda () (transition-props secret 'DONE 'close now))
             (lambda () (restore-props "task" secret "{}"))
             (lambda () (props-command "task" (draft-for (request-props (object "task" '()) #f) "task")
                                       secret #f now)))))

(test-equal "props-command: a call that cannot happen raises with no irritant"
  (map (lambda (x) (list 'props-command x '()))
       '("a Draft is the kind's: a Task's for a Task, a text for another"
         "a Draft is the kind's: a Task's for a Task, a text for another"
         "a create's props are never absent"
         "a kind is one of the five"
         "a create has no stored props, and a replace has them"
         "a create has no stored props, and a replace has them"
         "now is whole milliseconds from 0 to 2^53 - 1"
         "now is whole milliseconds from 0 to 2^53 - 1"))
  (let ((task-draft (attempt (lambda () (draft-for (request-props (object "task" '()) #t) "task")))))
    (map (lambda (args) (raised-as (lambda () (apply props-command args))))
         (list (list "task" "{}" #f #t now) (list "note" task-draft #f #t now)
               (list "task" 'absent #f #t now) (list "folder" "{}" #f #t now)
               (list "note" "{}" "{}" #t now) (list "note" "{}" #f #f now)
               (list "note" "{}" #f #t 1.0) (list "task" task-draft #f #t two-53)))))

(test-equal "stored-props->json, restore-props: a kind not of the five raises with no irritant"
  '((stored-props->json "a kind is one of the five" ()) (restore-props "a kind is one of the five" ()))
  (list (raised-as (lambda () (stored-props->json "folder" "{}")))
        (raised-as (lambda () (restore-props "Task" "{}" "{}")))))

(test-end "props")

(exit (suite-exit-status runner))
