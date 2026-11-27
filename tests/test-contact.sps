#!r6rs
;;; The contact suite: slice 6's Contact props, (techo contact). All pure.
;;;
;;;   the top           {} and kind; what is no member; what is no object
;;;   each member       name, organizations, titles, emails, phones,
;;;                     addresses, anniversaries, links, onlineServices,
;;;                     speakToAs: the shapes taken, as canonical text, and
;;;                     every refusal the plan and its review name
;;;   the common rules  Ids, contexts, features, pref, every string (U+0000,
;;;                     noncharacters, 1,000 characters), numbers exact
;;;   @type             right, wrong and in another case, on every object
;;;   twice             a name given twice in every object at every depth
;;;   canonical form    defaults dropped; a rich contact exactly; one value
;;;                     one text whatever the order sent (R17); idempotent
;;;   hostile shapes    every wrong type at the top and in every position,
;;;                     refused, and nothing raised
;;;   linear            95,000 entries judged quickly; 100,000 members refused
;;;                     after a bounded number of names, by time and by bytes
;;;
;;; Props are written here as JSON text with ' for ", read by (jsonparse
;;; easy), and an answer is compared as the JSON writer writes it, or whole.
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (rnrs mutable-pairs)
        (srfi :64)
        (only (chezscheme) real-time bytes-allocated bytes-deallocated current-time time-second
              time-nanosecond)
        (only (jsonparse easy) string->json json->string)
        (techo-testing)
        (techo contact))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define (written x) (call-with-string-output-port (lambda (p) (write x p))))

;; allocated : -> Natural     every byte allocated so far, collected or not
(define (allocated) (+ (bytes-allocated) (bytes-deallocated)))

;; q : String -> String     TEXT with each ' made ", so JSON can be written in a Scheme string
(define (q text)
  (list->string (map (lambda (c) (if (char=? c #\') #\" c)) (string->list text))))

;; j : String -> Any     the JSON reader's value of (q TEXT)
(define (j text) (string->json (q text)))

;; shown : Any -> Any     an answer as the JSON writer writes it; a symbol as itself
(define (shown r) (if (symbol? r) r (json->string r)))

;; judge : String -> (U String Symbol (List 'raised String))
;; parse-contact-props' answer to the props written as TEXT, shown.
(define (judge text)
  (attempt (lambda () (shown (parse-contact-props (j text))))))

;; judge-value : Any -> (U String Symbol (List 'raised String))     the same, of a value
(define (judge-value v)
  (attempt (lambda () (shown (parse-contact-props v)))))

;; takes : String (Listof (List String String String)) -> Unspecified
;; For each case, its name, the props sent and the canonical text expected.
(define (takes prefix cases)
  (for-each (lambda (c)
              (test-equal (string-append prefix ": takes " (car c))
                (q (caddr c))
                (judge (cadr c))))
            cases))

;; refuses : String (Listof (List String String)) -> Unspecified
;; For each case, its name and the props sent: each 'invalid.
(define (refuses prefix cases)
  (for-each (lambda (c)
              (test-equal (string-append prefix ": refuses " (car c))
                'invalid
                (judge (cadr c))))
            cases))

;; refuses-values : String (Listof (Pair String Any)) -> Unspecified     the same, of values
(define (refuses-values prefix cases)
  (for-each (lambda (c)
              (test-equal (string-append prefix ": refuses " (car c))
                'invalid
                (judge-value (cdr c))))
            cases))

;; One member's props, written around an object's text.
(define (in-email text) (string-append "{'emails':{'e1':" text "}}"))
(define (in-phone text) (string-append "{'phones':{'p1':" text "}}"))
(define (in-address text) (string-append "{'addresses':{'a1':" text "}}"))
(define (in-link text) (string-append "{'links':{'l1':" text "}}"))
(define (in-service text) (string-append "{'onlineServices':{'s1':" text "}}"))
(define (in-date text) (string-append "{'anniversaries':{'b':{'kind':'birth','date':" text "}}}"))

;; Props as values, for strings the JSON text above cannot hold.
(define (email-props address)
  (list (cons "emails" (list (cons "e1" (list (cons "address" address)))))))
(define (label-props label)
  (list (cons "emails" (list (cons "e1" (list (cons "address" "a@b") (cons "label" label)))))))
(define (link-props uri)
  (list (cons "links" (list (cons "l1" (list (cons "uri" uri)))))))

;; Every sample of props this suite takes, for the idempotence test.
(define taken-samples '())
(define (sample! text) (set! taken-samples (cons text taken-samples)) text)

(test-begin "contact")

;;; The top

(test-equal "top: {} is a valid Contact, and answers the empty object"
  '()
  (attempt (lambda () (parse-contact-props '()))))

(takes "kind"
  (list (list "org" (sample! "{'kind':'org'}") "{'kind':'org'}")
        (list "location" (sample! "{'kind':'location'}") "{'kind':'location'}")
        (list "individual, the default, dropped" "{'kind':'individual'}" "{}")))

(refuses "kind"
  (list (list "group, left out" "{'kind':'group'}")
        (list "device, left out" "{'kind':'device'}")
        (list "application, left out" "{'kind':'application'}")
        (list "another case" "{'kind':'Individual'}")
        (list "upper case" "{'kind':'ORG'}")
        (list "empty" "{'kind':''}")
        (list "a number" "{'kind':1}")
        (list "null" "{'kind':null}")
        (list "true" "{'kind':true}")
        (list "an array" "{'kind':['org']}")
        (list "an object" "{'kind':{'org':true}}")))

(refuses "top"
  (list (list "@type, even Card" "{'@type':'Card'}")
        (list "@type and a member" "{'@type':'Card','kind':'org'}")
        (list "version" "{'version':'1.0'}")
        (list "uid" "{'uid':'urn:uuid:0193b2c4-0000-7000-8000-000000000000'}")
        (list "created" "{'created':'2026-11-27T00:00:00Z'}")
        (list "nicknames, left out" "{'nicknames':{'k':{'name':'Ada'}}}")
        (list "notes, left out" "{'notes':{'n':{'note':'x'}}}")
        (list "keywords, left out" "{'keywords':{'x':true}}")
        (list "a Task's status" "{'status':'TODO'}")
        (list "a Note's at" "{'at':'2026-12-01'}")
        (list "Kind, another case" "{'Kind':'org'}")
        (list "fullName" "{'fullName':'Ada'}")
        (list "a member with an empty name" "{'':1}")))

(refuses-values "top"
  (list (cons "a string" "{}")
        (cons "a number" 0)
        (cons "an array" '#())
        (cons "an array of an object" (vector '(("kind" . "org"))))
        (cons "null" 'null)
        (cons "true" #t)
        (cons "false" #f)
        (cons "a list of strings" '("kind" "org"))
        (cons "a member named by a symbol" '((kind . "org")))
        (cons "an improper list" (cons '("kind" . "org") 5))
        (cons "a pair, not a list" (cons "kind" "org"))))

;;; name

(takes "name"
  (list (list "one component" (sample! "{'name':{'components':[{'kind':'given','value':'Ada'}]}}")
              "{'name':{'components':[{'kind':'given','value':'Ada'}]}}")
        (list "each of the seven kinds, in the order sent"
              (sample! (string-append
                        "{'name':{'components':[{'kind':'generation','value':'III'},"
                        "{'kind':'credential','value':'FRS'},{'kind':'surname2','value':'B'},"
                        "{'kind':'surname','value':'L'},{'kind':'given2','value':'K'},"
                        "{'kind':'given','value':'A'},{'kind':'title','value':'Dr.'}]}}"))
              (string-append
               "{'name':{'components':[{'kind':'generation','value':'III'},"
               "{'kind':'credential','value':'FRS'},{'kind':'surname2','value':'B'},"
               "{'kind':'surname','value':'L'},{'kind':'given2','value':'K'},"
               "{'kind':'given','value':'A'},{'kind':'title','value':'Dr.'}]}}"))
        (list "a component's members in the table's order, kind then value"
              "{'name':{'components':[{'value':'Ada','kind':'given'}]}}"
              "{'name':{'components':[{'kind':'given','value':'Ada'}]}}")
        (list "isOrdered true, kept, after components"
              "{'name':{'isOrdered':true,'components':[{'kind':'given','value':'Ada'}]}}"
              "{'name':{'components':[{'kind':'given','value':'Ada'}],'isOrdered':true}}")
        (list "isOrdered false, the default, dropped"
              "{'name':{'components':[{'kind':'given','value':'Ada'}],'isOrdered':false}}"
              "{'name':{'components':[{'kind':'given','value':'Ada'}]}}")))

(refuses "name"
  (list (list "an empty value" "{'name':{'components':[{'kind':'given','value':''}]}}")
        (list "{}" "{'name':{}}")
        (list "isOrdered alone" "{'name':{'isOrdered':true}}")
        (list "no components, only @type" "{'name':{'@type':'Name'}}")
        (list "components empty" "{'name':{'components':[]}}")
        (list "components an object" "{'name':{'components':{'kind':'given','value':'Ada'}}}")
        (list "a component that is a string" "{'name':{'components':['Ada']}}")
        (list "a component that is {}" "{'name':{'components':[{}]}}")
        (list "a separator, left out" "{'name':{'components':[{'kind':'separator','value':' '}]}}")
        (list "a kind of another case" "{'name':{'components':[{'kind':'Given','value':'Ada'}]}}")
        (list "a kind not of the list" "{'name':{'components':[{'kind':'middle','value':'K'}]}}")
        (list "a component with no kind" "{'name':{'components':[{'value':'Ada'}]}}")
        (list "a component with no value" "{'name':{'components':[{'kind':'given'}]}}")
        (list "a value that is a number" "{'name':{'components':[{'kind':'given','value':1}]}}")
        (list "a component's phonetic, left out"
              "{'name':{'components':[{'kind':'given','value':'Ada','phonetic':'a'}]}}")
        (list "full: the node's title holds it" "{'name':{'components':[{'kind':'given','value':'A'}],'full':'A'}}")
        (list "full alone" "{'name':{'full':'Ada Lovelace'}}")
        (list "sortAs, left out" "{'name':{'components':[{'kind':'given','value':'A'}],'sortAs':{'given':'A'}}}")
        (list "defaultSeparator, left out"
              "{'name':{'components':[{'kind':'given','value':'A'}],'isOrdered':true,'defaultSeparator':' '}}")
        (list "phoneticSystem, left out"
              "{'name':{'components':[{'kind':'given','value':'A'}],'phoneticSystem':'ipa'}}")
        (list "isOrdered a string" "{'name':{'components':[{'kind':'given','value':'A'}],'isOrdered':'true'}}")
        (list "isOrdered a number" "{'name':{'components':[{'kind':'given','value':'A'}],'isOrdered':1}}")
        (list "isOrdered null" "{'name':{'components':[{'kind':'given','value':'A'}],'isOrdered':null}}")
        (list "a string" "{'name':'Ada Lovelace'}")
        (list "an array" "{'name':[{'kind':'given','value':'A'}]}")))

;;; organizations and titles

(takes "organizations"
  (list (list "a name" (sample! "{'organizations':{'o1':{'name':'ABC, Inc.'}}}")
              "{'organizations':{'o1':{'name':'ABC, Inc.'}}}")
        (list "units alone" (sample! "{'organizations':{'o1':{'units':[{'name':'Marketing'}]}}}")
              "{'organizations':{'o1':{'units':[{'name':'Marketing'}]}}}")
        (list "name, units, contexts, in the table's order; units in the order sent"
              "{'organizations':{'o1':{'contexts':{'work':true},'units':[{'name':'North'},{'name':'Marketing'}],'name':'ABC'}}}"
              "{'organizations':{'o1':{'name':'ABC','units':[{'name':'North'},{'name':'Marketing'}],'contexts':{'work':true}}}}")))

(refuses "organizations"
  (list (list "an empty Id map" "{'organizations':{}}")
        (list "an empty organization" "{'organizations':{'o1':{}}}")
        (list "neither name nor units" "{'organizations':{'o1':{'contexts':{'work':true}}}}")
        (list "units empty" "{'organizations':{'o1':{'units':[]}}}")
        (list "units empty beside a name" "{'organizations':{'o1':{'name':'A','units':[]}}}")
        (list "a unit {}" "{'organizations':{'o1':{'units':[{}]}}}")
        (list "a unit with no name" "{'organizations':{'o1':{'units':[{'@type':'OrgUnit'}]}}}")
        (list "a unit's sortAs, left out" "{'organizations':{'o1':{'units':[{'name':'M','sortAs':'M'}]}}}")
        (list "sortAs, left out" "{'organizations':{'o1':{'name':'ABC','sortAs':'ABC'}}}")
        (list "a name that is a number" "{'organizations':{'o1':{'name':7}}}")
        (list "units an object" "{'organizations':{'o1':{'units':{'name':'M'}}}}")
        (list "a unit that is a string" "{'organizations':{'o1':{'units':['M']}}}")
        (list "an address's context" "{'organizations':{'o1':{'name':'A','contexts':{'billing':true}}}}")
        (list "an array" "{'organizations':[{'name':'A'}]}")))

(takes "titles"
  (list (list "a name" (sample! "{'titles':{'t1':{'name':'Research Scientist'}}}")
              "{'titles':{'t1':{'name':'Research Scientist'}}}")
        (list "kind role, kept" (sample! "{'titles':{'t1':{'name':'Lead','kind':'role'}}}")
              "{'titles':{'t1':{'name':'Lead','kind':'role'}}}")
        (list "kind title, the default, dropped" "{'titles':{'t1':{'kind':'title','name':'Lead'}}}"
              "{'titles':{'t1':{'name':'Lead'}}}")
        (list "organizationId naming one of this contact's organizations"
              (sample! "{'titles':{'k2':{'organizationId':'o2','kind':'role','name':'Project Leader'}},'organizations':{'o2':{'name':'ABC, Inc.'}}}")
              "{'organizations':{'o2':{'name':'ABC, Inc.'}},'titles':{'k2':{'name':'Project Leader','kind':'role','organizationId':'o2'}}}")
        (list "two titles in one organization of two"
              "{'organizations':{'b':{'name':'B'},'a':{'name':'A'}},'titles':{'y':{'name':'Y','organizationId':'b'},'x':{'name':'X','organizationId':'b'}}}"
              "{'organizations':{'a':{'name':'A'},'b':{'name':'B'}},'titles':{'x':{'name':'X','organizationId':'b'},'y':{'name':'Y','organizationId':'b'}}}")))

(refuses "titles"
  (list (list "an empty Id map" "{'titles':{}}")
        (list "no name" "{'titles':{'t1':{'kind':'role'}}}")
        (list "a kind of another case" "{'titles':{'t1':{'name':'L','kind':'Role'}}}")
        (list "a kind not of the list" "{'titles':{'t1':{'name':'L','kind':'job'}}}")
        (list "organizationId dangling" "{'organizations':{'o1':{'name':'A'}},'titles':{'t1':{'name':'L','organizationId':'o2'}}}")
        (list "organizationId with no organizations" "{'titles':{'t1':{'name':'L','organizationId':'o1'}}}")
        (list "organizationId another case of the key" "{'organizations':{'o1':{'name':'A'}},'titles':{'t1':{'name':'L','organizationId':'O1'}}}")
        (list "organizationId naming a title's key" "{'organizations':{'o1':{'name':'A'}},'titles':{'t1':{'name':'L','organizationId':'t1'}}}")
        (list "organizationId no Id" "{'organizations':{'o 1':{'name':'A'}},'titles':{'t1':{'name':'L','organizationId':'o 1'}}}")
        (list "organizationId a number" "{'organizations':{'1':{'name':'A'}},'titles':{'t1':{'name':'L','organizationId':1}}}")
        (list "contexts: no member of a Title" "{'titles':{'t1':{'name':'L','contexts':{'work':true}}}}")))

;;; emails, and the address rule

(takes "emails"
  (list (list "an address" (sample! "{'emails':{'e1':{'address':'jqpublic@xyz.example.com'}}}")
              "{'emails':{'e1':{'address':'jqpublic@xyz.example.com'}}}")
        (list "every member, in the table's order"
              "{'emails':{'e1':{'label':'home','pref':1,'contexts':{'work':true,'private':true},'address':'a@b'}}}"
              "{'emails':{'e1':{'address':'a@b','contexts':{'private':true,'work':true},'pref':1,'label':'home'}}}")
        (list "two, sorted by Id" "{'emails':{'zz':{'address':'z@z'},'a1':{'address':'a@a'}}}"
              "{'emails':{'a1':{'address':'a@a'},'zz':{'address':'z@z'}}}")))

(refuses "emails"
  (list (list "an empty Id map" "{'emails':{}}")
        (list "no address" "{'emails':{'e1':{'label':'x'}}}")
        (list "features: a phone's member" (in-email "{'address':'a@b','features':{'voice':true}}"))
        (list "number: a phone's member" (in-email "{'address':'a@b','number':'1'}"))
        (list "an address's context" (in-email "{'address':'a@b','contexts':{'billing':true}}"))
        (list "a label that is a number" (in-email "{'address':'a@b','label':1}"))
        (list "an address that is a number" (in-email "{'address':1}"))
        (list "an array of addresses" "{'emails':['a@b']}")))

;; email-cases : (Listof (List String String Boolean))
;; The review's rule: atoms joined by single dots, an @, atoms joined by
;; single dots; at most 254 characters. An atom holds only RFC 5322's
;; atext: ASCII letters, digits, and !#$%&'*+-/=?^_`{|}~ . Nothing past
;; ASCII is taken (JSContact's rule). Narrower than RFC 5322.
(define email-cases
  (list (list "a@b" "a@b" #t)
        (list "dots between atoms" "first.last@sub.example.com" #t)
        (list "every printable that is no special"
              (string-append "!#$%&" (string #\x27) "*+-/=?^_`{|}~@example.com") #t)
        (list "every ASCII letter and digit"
              "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@a0.Z9" #t)
        (list "a non-ASCII letter before the @, Latin" (string-append "\x00e9;lise@exemple.fr") #f)
        (list "a non-ASCII letter after the @, Latin" (string-append "elise@\x00e9;xemple.fr") #f)
        (list "non-ASCII letters, CJK" (string #\x7528 #\x6237 #\@ #\x4f8b #\x5b50 #\. #\x5e7f #\x544a) #f)
        (list "U+FF20, a full-width @, in the name" (string #\a (integer->char #xff20) #\b #\@ #\c) #f)
        (list "U+200B, a zero-width space" (string #\a (integer->char #x200b) #\@ #\b) #f)
        (list "U+0430, a Cyrillic a" (string (integer->char #x430) #\@ #\b) #f)
        (list "U+00A1, the first printable past ASCII" (string #\a (integer->char #xa1) #\@ #\b) #f)
        (list "U+10400, past the first plane" (string #\a (integer->char #x10400) #\@ #\b) #f)
        (list "254 characters" (string-append (make-string 64 #\a) "@" (make-string 189 #\b)) #t)
        (list "255 characters" (string-append (make-string 64 #\a) "@" (make-string 190 #\b)) #f)
        (list "@" "@" #f)
        (list "a@" "a@" #f)
        (list "@b" "@b" #f)
        (list "no @" "ab" #f)
        (list "empty" "" #f)
        (list "two @" "a@b@c" #f)
        (list "a..b@c" "a..b@c" #f)
        (list "a@b..c" "a@b..c" #f)
        (list ".a@b" ".a@b" #f)
        (list "a.@b" "a.@b" #f)
        (list "a@.b" "a@.b" #f)
        (list "a@b." "a@b." #f)
        (list "a quoted local part" "\"a b\"@c" #f)
        (list "a quoted local part with no space" "\"ab\"@c" #f)
        (list "an address literal" "a@[192.0.2.1]" #f)
        (list "a space" "a b@c" #f)
        (list "a space after" "a@b " #f)
        (list "a tab" "a\tb@c" #f)
        (list "a newline" "a@b\nc" #f)
        (list "U+0001" (string #\a (integer->char 1) #\@ #\b) #f)
        (list "U+007F" (string #\a (integer->char #x7f) #\@ #\b) #f)
        (list "U+0085, a C1 control" (string #\a (integer->char #x85) #\@ #\b) #f)
        (list "U+00A0, white space" (string #\a (integer->char #xa0) #\@ #\b) #f)
        (list "U+3000, white space" (string #\a (integer->char #x3000) #\@ #\b) #f)
        (list "(" "a(b@c" #f) (list ")" "a)b@c" #f) (list "<" "a<b@c" #f) (list ">" "a>b@c" #f)
        (list "[" "a[b@c" #f) (list "]" "a]b@c" #f) (list ":" "a:b@c" #f) (list ";" "a;b@c" #f)
        (list "a backslash" "a\\b@c" #f) (list "," "a,b@c" #f) (list "a quote" "a\"b@c" #f)
        (list "a display name" "Ada <a@b>" #f)
        (list "mailto:" "mailto:a@b" #f)))

(for-each
 (lambda (c)
   (test-equal (string-append "email address: " (if (caddr c) "takes " "refuses ") (car c))
     (if (caddr c) (email-props (cadr c)) 'invalid)
     (attempt (lambda () (parse-contact-props (email-props (cadr c)))))))
 email-cases)

;;; phones

(takes "phones"
  (list (list "a number" (sample! "{'phones':{'tel0':{'number':'tel:+1-555-555-5555;ext=5555'}}}")
              "{'phones':{'tel0':{'number':'tel:+1-555-555-5555;ext=5555'}}}")
        (list "free text" (in-phone "{'number':'+1 (555) 555-5555'}")
              "{'phones':{'p1':{'number':'+1 (555) 555-5555'}}}")
        (list "every member, in the table's order"
              (sample! (in-phone "{'label':'cell','pref':2,'contexts':{'private':true},'features':{'voice':true},'number':'1'}"))
              "{'phones':{'p1':{'number':'1','features':{'voice':true},'contexts':{'private':true},'pref':2,'label':'cell'}}}")
        (list "all eight features, in the plan's order"
              (in-phone "{'number':'1','features':{'pager':true,'fax':true,'textphone':true,'main-number':true,'video':true,'text':true,'voice':true,'mobile':true}}")
              "{'phones':{'p1':{'number':'1','features':{'mobile':true,'voice':true,'text':true,'video':true,'main-number':true,'textphone':true,'fax':true,'pager':true}}}}")))

(refuses "phones"
  (list (list "an empty Id map" "{'phones':{}}")
        (list "no number" (in-phone "{'features':{'voice':true}}"))
        (list "a number that is a number" (in-phone "{'number':5555}"))
        (list "features empty" (in-phone "{'number':'1','features':{}}"))
        (list "a feature false" (in-phone "{'number':'1','features':{'voice':false}}"))
        (list "a feature 'true'" (in-phone "{'number':'1','features':{'voice':'true'}}"))
        (list "a feature 1" (in-phone "{'number':'1','features':{'voice':1}}"))
        (list "a feature null" (in-phone "{'number':'1','features':{'voice':null}}"))
        (list "a feature of another case" (in-phone "{'number':'1','features':{'Voice':true}}"))
        (list "a feature not of the list" (in-phone "{'number':'1','features':{'sms':true}}"))
        (list "a feature twice" (in-phone "{'number':'1','features':{'fax':true,'fax':true}}"))
        (list "features an array" (in-phone "{'number':'1','features':['voice']}"))
        (list "a context as a feature" (in-phone "{'number':'1','features':{'work':true}}"))
        (list "a feature as a context" (in-phone "{'number':'1','contexts':{'voice':true}}"))
        (list "an address's context" (in-phone "{'number':'1','contexts':{'delivery':true}}"))
        (list "address: an email's member" (in-phone "{'number':'1','address':'a@b'}"))))

;;; addresses

(takes "addresses"
  (list (list "components alone"
              (sample! (in-address "{'components':[{'kind':'locality','value':'Reston'}]}"))
              "{'addresses':{'a1':{'components':[{'kind':'locality','value':'Reston'}]}}}")
        (list "countryCode alone" (sample! (in-address "{'countryCode':'US'}"))
              "{'addresses':{'a1':{'countryCode':'US'}}}")
        (list "full alone" (in-address "{'full':'54321 Oak St, Reston, VA 20190, USA'}")
              "{'addresses':{'a1':{'full':'54321 Oak St, Reston, VA 20190, USA'}}}")
        (list "every member, in the table's order"
              (sample! (in-address (string-append
                                    "{'pref':1,'contexts':{'delivery':true,'billing':true,'work':true,'private':true},"
                                    "'full':'54321 Oak St','countryCode':'US','isOrdered':true,"
                                    "'components':[{'value':'54321','kind':'number'},{'kind':'name','value':'Oak St'}]}")))
              (string-append
               "{'addresses':{'a1':{'components':[{'kind':'number','value':'54321'},{'kind':'name','value':'Oak St'}],"
               "'isOrdered':true,'countryCode':'US','full':'54321 Oak St',"
               "'contexts':{'private':true,'work':true,'billing':true,'delivery':true},'pref':1}}}"))
        (list "isOrdered false, the default, dropped" (in-address "{'countryCode':'US','isOrdered':false}")
              "{'addresses':{'a1':{'countryCode':'US'}}}")
        (list "every one of the sixteen kinds, in the order sent"
              (in-address (string-append
                           "{'components':[{'kind':'room','value':'1'},{'kind':'apartment','value':'2'},"
                           "{'kind':'floor','value':'3'},{'kind':'building','value':'4'},{'kind':'number','value':'5'},"
                           "{'kind':'name','value':'6'},{'kind':'block','value':'7'},{'kind':'subdistrict','value':'8'},"
                           "{'kind':'district','value':'9'},{'kind':'locality','value':'10'},{'kind':'region','value':'11'},"
                           "{'kind':'postcode','value':'12'},{'kind':'country','value':'13'},{'kind':'direction','value':'14'},"
                           "{'kind':'landmark','value':'15'},{'kind':'postOfficeBox','value':'16'}]}"))
              (string-append
               "{'addresses':{'a1':{'components':[{'kind':'room','value':'1'},{'kind':'apartment','value':'2'},"
               "{'kind':'floor','value':'3'},{'kind':'building','value':'4'},{'kind':'number','value':'5'},"
               "{'kind':'name','value':'6'},{'kind':'block','value':'7'},{'kind':'subdistrict','value':'8'},"
               "{'kind':'district','value':'9'},{'kind':'locality','value':'10'},{'kind':'region','value':'11'},"
               "{'kind':'postcode','value':'12'},{'kind':'country','value':'13'},{'kind':'direction','value':'14'},"
               "{'kind':'landmark','value':'15'},{'kind':'postOfficeBox','value':'16'}]}}}"))))

(refuses "addresses"
  (list (list "an empty Id map" "{'addresses':{}}")
        (list "an empty address" (in-address "{}"))
        (list "contexts alone" (in-address "{'contexts':{'work':true}}"))
        (list "pref alone" (in-address "{'pref':1}"))
        (list "isOrdered alone" (in-address "{'isOrdered':true}"))
        (list "components empty" (in-address "{'components':[]}"))
        (list "a separator, left out" (in-address "{'components':[{'kind':'separator','value':', '}]}"))
        (list "a kind of another case" (in-address "{'components':[{'kind':'Locality','value':'R'}]}"))
        (list "a kind of a name's" (in-address "{'components':[{'kind':'given','value':'R'}]}"))
        (list "a component with no value" (in-address "{'components':[{'kind':'locality'}]}"))
        (list "a component with no kind" (in-address "{'components':[{'value':'R'}]}"))
        (list "countryCode lower case" (in-address "{'countryCode':'us'}"))
        (list "countryCode mixed case" (in-address "{'countryCode':'Us'}"))
        (list "countryCode three letters" (in-address "{'countryCode':'USA'}"))
        (list "countryCode one letter" (in-address "{'countryCode':'U'}"))
        (list "countryCode empty" (in-address "{'countryCode':''}"))
        (list "countryCode a digit" (in-address "{'countryCode':'U1'}"))
        (list "countryCode a number" (in-address "{'countryCode':1}"))
        (list "label: no member of an Address" (in-address "{'countryCode':'US','label':'home'}"))
        (list "coordinates, left out" (in-address "{'coordinates':'geo:38.9,-77.4'}"))
        (list "timeZone, left out" (in-address "{'countryCode':'US','timeZone':'America/New_York'}"))
        (list "defaultSeparator, left out" (in-address "{'full':'x','defaultSeparator':', '}"))
        (list "a context not of the list" (in-address "{'countryCode':'US','contexts':{'home':true}}"))))

(test-equal "addresses: countryCode with a full-width capital, refused"
  'invalid
  (judge-value (list (cons "addresses" (list (cons "a1" (list (cons "countryCode" (string #\U (integer->char #xff33))))))))))

(test-equal "addresses: countryCode with an accented capital, refused"
  'invalid
  (judge-value (list (cons "addresses" (list (cons "a1" (list (cons "countryCode" (string #\U (integer->char #xc9))))))))))

;;; anniversaries, and the PartialDate

(takes "anniversaries"
  (list (list "a birthday, the date's members in the table's order"
              (sample! "{'anniversaries':{'k8':{'date':{'day':15,'month':4,'year':1953},'kind':'birth'}}}")
              "{'anniversaries':{'k8':{'kind':'birth','date':{'year':1953,'month':4,'day':15}}}}")
        (list "death" (in-date "{'year':2019}")
              "{'anniversaries':{'b':{'kind':'birth','date':{'year':2019}}}}")
        (list "wedding" "{'anniversaries':{'w':{'kind':'wedding','date':{'year':1835,'month':7,'day':8}}}}"
              "{'anniversaries':{'w':{'kind':'wedding','date':{'year':1835,'month':7,'day':8}}}}")
        (list "a year alone" (in-date "{'year':1815}")
              "{'anniversaries':{'b':{'kind':'birth','date':{'year':1815}}}}")
        (list "a month in a year" (in-date "{'month':12,'year':1815}")
              "{'anniversaries':{'b':{'kind':'birth','date':{'year':1815,'month':12}}}}")
        (list "a day in a month, no year" (sample! (in-date "{'month':12,'day':10}"))
              "{'anniversaries':{'b':{'kind':'birth','date':{'month':12,'day':10}}}}")
        (list "29 February, no year" (in-date "{'month':2,'day':29}")
              "{'anniversaries':{'b':{'kind':'birth','date':{'month':2,'day':29}}}}")
        (list "29 February 2024" (in-date "{'year':2024,'month':2,'day':29}")
              "{'anniversaries':{'b':{'kind':'birth','date':{'year':2024,'month':2,'day':29}}}}")
        (list "29 February 2000" (in-date "{'year':2000,'month':2,'day':29}")
              "{'anniversaries':{'b':{'kind':'birth','date':{'year':2000,'month':2,'day':29}}}}")
        (list "31 January, no year" (in-date "{'month':1,'day':31}")
              "{'anniversaries':{'b':{'kind':'birth','date':{'month':1,'day':31}}}}")
        (list "year 1 and year 9999" "{'anniversaries':{'a':{'kind':'birth','date':{'year':1}},'b':{'kind':'death','date':{'year':9999}}}}"
              "{'anniversaries':{'a':{'kind':'birth','date':{'year':1}},'b':{'kind':'death','date':{'year':9999}}}}")
        (list "@type on both, right, dropped"
              "{'anniversaries':{'b':{'@type':'Anniversary','kind':'birth','date':{'@type':'PartialDate','year':1815}}}}"
              "{'anniversaries':{'b':{'kind':'birth','date':{'year':1815}}}}")))

(test-equal "anniversaries: death, as a kind"
  (q "{'anniversaries':{'d':{'kind':'death','date':{'year':1852,'month':11,'day':27}}}}")
  (judge "{'anniversaries':{'d':{'kind':'death','date':{'year':1852,'month':11,'day':27}}}}"))

(refuses "anniversaries"
  (list (list "an empty Id map" "{'anniversaries':{}}")
        (list "no kind" "{'anniversaries':{'b':{'date':{'year':1815}}}}")
        (list "no date" "{'anniversaries':{'b':{'kind':'birth'}}}")
        (list "a kind of another case" "{'anniversaries':{'b':{'kind':'Birth','date':{'year':1815}}}}")
        (list "a kind not of the list" "{'anniversaries':{'b':{'kind':'anniversary','date':{'year':1815}}}}")
        (list "place, left out" "{'anniversaries':{'b':{'kind':'birth','date':{'year':1815},'place':{'full':'London'}}}}")
        (list "a date {}" (in-date "{}"))
        (list "a date of only @type" (in-date "{'@type':'PartialDate'}"))
        (list "a month alone" (in-date "{'month':12}"))
        (list "a day alone" (in-date "{'day':10}"))
        (list "a day in a year, no month" (in-date "{'year':1815,'day':10}"))
        (list "29 February 2023" (in-date "{'year':2023,'month':2,'day':29}"))
        (list "29 February 1900" (in-date "{'year':1900,'month':2,'day':29}"))
        (list "30 February, no year" (in-date "{'month':2,'day':30}"))
        (list "31 April, no year" (in-date "{'month':4,'day':31}"))
        (list "31 April 2026" (in-date "{'year':2026,'month':4,'day':31}"))
        (list "year 0" (in-date "{'year':0}"))
        (list "year 10000" (in-date "{'year':10000}"))
        (list "year -1" (in-date "{'year':-1}"))
        (list "month 0" (in-date "{'year':1815,'month':0}"))
        (list "month 13" (in-date "{'year':1815,'month':13}"))
        (list "day 0" (in-date "{'month':1,'day':0}"))
        (list "day 32" (in-date "{'month':1,'day':32}"))
        (list "a year 1815.0" (in-date "{'year':1815.0}"))
        (list "a month 12.0" (in-date "{'year':1815,'month':12.0}"))
        (list "a day 1e1" (in-date "{'month':12,'day':1e1}"))
        (list "a year that is a string" (in-date "{'year':'1815'}"))
        (list "a date that is a string" (in-date "'1815-12-10'"))
        (list "a Timestamp, left out" (in-date "{'@type':'Timestamp','utc':'2019-10-15T23:10:00Z'}"))
        (list "utc with no @type" (in-date "{'utc':'2019-10-15T23:10:00Z'}"))
        (list "calendarScale, left out" (in-date "{'year':1815,'calendarScale':'gregory'}"))))

;;; links, and uri

(takes "links"
  (list (list "a uri" (sample! "{'links':{'link3':{'uri':'mailto:contact@example.com'}}}")
              "{'links':{'link3':{'uri':'mailto:contact@example.com'}}}")
        (list "every member, in the table's order"
              (sample! (in-link "{'label':'web','pref':1,'contexts':{'private':true},'kind':'contact','uri':'https://ex.com/'}"))
              "{'links':{'l1':{'uri':'https://ex.com/','kind':'contact','contexts':{'private':true},'pref':1,'label':'web'}}}")))

;; The review's probe build/review-6/uri.sps, and what it printed.
(define uri-cases
  (list (cons "https://lovelace.example.org/" #t) (cons "mailto:ada@example.com" #t)
        (cons "xmpp:alice@example.com" #t) (cons "tel:+1-202-555-0143" #t)
        (cons "http://[::1]/" #t) (cons "a:" #t) (cons "urn:uuid:0193b2c4" #t)
        (cons "hello" #f) (cons "example.com/ada" #f) (cons "\x00e9;:x" #f)
        (cons "https://ex.com/\x00e9;" #f) (cons "a:[" #f) (cons "http://[::1" #f)
        (cons "a:b#c#d" #f) (cons "https://ex.com/a b" #f) (cons "" #f)
        (cons "https://ex.com/%7e" #t) (cons "https://ex.com/%zz" #f)
        ;; What chez-uri decides, held here so that an upgrade cannot move
        ;; it unseen: a rule once shipped is never tightened (P3).
        (cons "javascript:alert(1)" #t) (cons "file:///etc/passwd" #t)
        (cons "data:text/plain,hi" #t) (cons "about:blank" #t)
        (cons "HTTPS://EX.COM/" #t) (cons "a+b-c.d:x" #t)
        (cons "https://ex.com/?q=1#f" #t) (cons "https://ex.com/#" #t)
        (cons "https://user:pw@ex.com:8080/" #t) (cons "http://[v1.a]/" #t)
        (cons "https://ex.com/a%20b" #t)
        (cons "1a:b" #f) (cons ":x" #f) (cons "//ex.com/" #f)
        (cons "https://ex.com:port/" #f) (cons "https://\x4f8b;.jp/" #f)
        (cons "a:b c" #f) (cons "a:%" #f) (cons "https://ex.com/\\" #f)
        (cons "https://ex.com/<>" #f) (cons "https://ex.com/{}" #f)
        (cons "https://ex.com/|" #f) (cons "https://ex.com/^" #f)
        (cons "https://ex.com/`" #f)))

(for-each
 (lambda (c)
   (test-equal (string-append "links: uri " (written (car c)) (if (cdr c) " taken" " refused"))
     (if (cdr c) (link-props (car c)) 'invalid)
     (attempt (lambda () (parse-contact-props (link-props (car c)))))))
 uri-cases)

(test-equal "links: a uri of 1,000 characters taken, and of 1,001 refused, though it is a URI"
  (list #t 'invalid)
  (attempt (lambda ()
             (let ((uri (lambda (n) (string-append "https://ex.com/" (make-string (- n 15) #\a)))))
               (list (equal? (parse-contact-props (link-props (uri 1000))) (link-props (uri 1000)))
                     (parse-contact-props (link-props (uri 1001))))))))

(refuses "links"
  (list (list "an empty Id map" "{'links':{}}")
        (list "no uri" (in-link "{'kind':'contact'}"))
        (list "a kind of another case" (in-link "{'uri':'a:b','kind':'Contact'}"))
        (list "a kind not of the list" (in-link "{'uri':'a:b','kind':'website'}"))
        (list "mediaType, left out" (in-link "{'uri':'a:b','mediaType':'text/html'}"))
        (list "a uri that is a number" (in-link "{'uri':1}"))
        (list "user: an online service's member" (in-link "{'uri':'a:b','user':'ada'}"))))

;;; onlineServices

(takes "onlineServices"
  (list (list "a uri alone" (sample! "{'onlineServices':{'x1':{'uri':'xmpp:alice@example.com'}}}")
              "{'onlineServices':{'x1':{'uri':'xmpp:alice@example.com'}}}")
        (list "a user alone" (in-service "{'user':'@alice@example2.com'}")
              "{'onlineServices':{'s1':{'user':'@alice@example2.com'}}}")
        (list "every member, in the table's order"
              (sample! (in-service "{'label':'m','pref':3,'contexts':{'work':true},'user':'@a','uri':'https://example2.com/@alice','service':'Mastodon'}"))
              "{'onlineServices':{'s1':{'service':'Mastodon','uri':'https://example2.com/@alice','user':'@a','contexts':{'work':true},'pref':3,'label':'m'}}}")))

(refuses "onlineServices"
  (list (list "an empty Id map" "{'onlineServices':{}}")
        (list "a service alone" (in-service "{'service':'GitHub'}"))
        (list "a label alone" (in-service "{'label':'x'}"))
        (list "a uri that is none" (in-service "{'uri':'hello'}"))
        (list "a uri that is none, beside a user" (in-service "{'uri':'hello','user':'ada'}"))
        (list "kind: a link's member" (in-service "{'uri':'a:b','kind':'contact'}"))
        (list "a user that is a number" (in-service "{'user':1}"))))

;;; speakToAs

(takes "speakToAs"
  (list (list "a gender alone" (sample! "{'speakToAs':{'grammaticalGender':'neuter'}}")
              "{'speakToAs':{'grammaticalGender':'neuter'}}")
        (list "pronouns alone" (sample! "{'speakToAs':{'pronouns':{'k19':{'pronouns':'they/them'}}}}")
              "{'speakToAs':{'pronouns':{'k19':{'pronouns':'they/them'}}}}")
        (list "the RFC's example, in the table's order, sorted by Id"
              "{'speakToAs':{'pronouns':{'k32':{'pref':1,'pronouns':'xe/xir'},'k19':{'pronouns':'they/them','pref':2}},'grammaticalGender':'neuter'}}"
              "{'speakToAs':{'grammaticalGender':'neuter','pronouns':{'k19':{'pronouns':'they/them','pref':2},'k32':{'pronouns':'xe/xir','pref':1}}}}")
        (list "a pronoun's contexts"
              "{'speakToAs':{'pronouns':{'p':{'contexts':{'work':true},'pronouns':'she/her'}}}}"
              "{'speakToAs':{'pronouns':{'p':{'pronouns':'she/her','contexts':{'work':true}}}}}")
        (list "a pronoun entry with a context and a pref: pronouns, contexts, pref"
              "{'speakToAs':{'pronouns':{'p':{'pref':3,'contexts':{'private':true},'pronouns':'he/him'}}}}"
              "{'speakToAs':{'pronouns':{'p':{'pronouns':'he/him','contexts':{'private':true},'pref':3}}}}")))

(test-equal "speakToAs: each of the six genders"
  (map (lambda (g) (q (string-append "{'speakToAs':{'grammaticalGender':'" g "'}}")))
       '("animate" "common" "feminine" "inanimate" "masculine" "neuter"))
  (map (lambda (g) (judge (string-append "{'speakToAs':{'grammaticalGender':'" g "'}}")))
       '("animate" "common" "feminine" "inanimate" "masculine" "neuter")))

(refuses "speakToAs"
  (list (list "{}" "{'speakToAs':{}}")
        (list "only @type" "{'speakToAs':{'@type':'SpeakToAs'}}")
        (list "a gender of another case" "{'speakToAs':{'grammaticalGender':'Feminine'}}")
        (list "a gender not of the list" "{'speakToAs':{'grammaticalGender':'female'}}")
        (list "pronouns empty" "{'speakToAs':{'pronouns':{}}}")
        (list "a pronoun entry {}" "{'speakToAs':{'pronouns':{'k':{}}}}")
        (list "a pronoun entry with no pronouns" "{'speakToAs':{'pronouns':{'k':{'pref':1}}}}")
        (list "a pronoun's label: no member of Pronouns" "{'speakToAs':{'pronouns':{'k':{'pronouns':'she','label':'x'}}}}")
        (list "pronouns a string" "{'speakToAs':{'pronouns':'she/her'}}")
        (list "a gender that is a number" "{'speakToAs':{'grammaticalGender':1}}")
        (list "an array" "{'speakToAs':[{'grammaticalGender':'neuter'}]}")))

;;; The common rules: an Id

(define (id-props id) (list (cons "emails" (list (cons id '(("address" . "a@b")))))))

(test-equal "Id: one character, every class of character, and 255 characters, each taken"
  (map id-props (list "a" "AZaz09-_" (make-string 255 #\x)))
  (map (lambda (id) (attempt (lambda () (parse-contact-props (id-props id)))))
       (list "a" "AZaz09-_" (make-string 255 #\x))))

(refuses-values "Id"
  (list (cons "empty" (id-props ""))
        (cons "256 characters" (id-props (make-string 256 #\x)))
        (cons "a space" (id-props "a b"))
        (cons "a dot" (id-props "a.b"))
        (cons "a slash" (id-props "a/b"))
        (cons "a plus" (id-props "a+b"))
        (cons "base64's pad" (id-props "ab=="))
        (cons "@type" (id-props "@type"))
        (cons "a non-ASCII letter" (id-props "\x00e9;"))
        (cons "a full-width digit" (id-props (string (integer->char #xff11))))
        (cons "U+0000" (id-props (string #\a (integer->char 0))))
        (cons "a key that is a symbol" (list (cons "emails" (list (cons 'e1 '(("address" . "a@b")))))))
        (cons "an entry that is no pair" (list (cons "emails" (list "e1"))))
        (cons "an improper Id map" (list (cons "emails" (cons (cons "e1" '(("address" . "a@b"))) 'x))))))

;;; contexts

(takes "contexts"
  (list (list "private" (in-email "{'address':'a@b','contexts':{'private':true}}")
              "{'emails':{'e1':{'address':'a@b','contexts':{'private':true}}}}")
        (list "work then private, in the plan's order" (in-email "{'address':'a@b','contexts':{'work':true,'private':true}}")
              "{'emails':{'e1':{'address':'a@b','contexts':{'private':true,'work':true}}}}")
        (list "an address's four, in the plan's order"
              (in-address "{'full':'x','contexts':{'delivery':true,'work':true,'billing':true,'private':true}}")
              "{'addresses':{'a1':{'full':'x','contexts':{'private':true,'work':true,'billing':true,'delivery':true}}}}")
        (list "an address's billing alone" (in-address "{'full':'x','contexts':{'billing':true}}")
              "{'addresses':{'a1':{'full':'x','contexts':{'billing':true}}}}")))

(refuses "contexts"
  (list (list "empty" (in-email "{'address':'a@b','contexts':{}}"))
        (list "false" (in-email "{'address':'a@b','contexts':{'work':false}}"))
        (list "'true'" (in-email "{'address':'a@b','contexts':{'work':'true'}}"))
        (list "1" (in-email "{'address':'a@b','contexts':{'work':1}}"))
        (list "null" (in-email "{'address':'a@b','contexts':{'work':null}}"))
        (list "{}" (in-email "{'address':'a@b','contexts':{'work':{}}}"))
        (list "another case" (in-email "{'address':'a@b','contexts':{'Work':true}}"))
        (list "not of the list" (in-email "{'address':'a@b','contexts':{'home':true}}"))
        (list "work twice" (in-email "{'address':'a@b','contexts':{'work':true,'work':true}}"))
        (list "work twice, the second false" (in-email "{'address':'a@b','contexts':{'work':true,'work':false}}"))
        (list "an array" (in-email "{'address':'a@b','contexts':['work']}"))
        (list "a string" (in-email "{'address':'a@b','contexts':'work'}"))
        (list "billing on an email" (in-email "{'address':'a@b','contexts':{'billing':true}}"))
        (list "delivery on a link" (in-link "{'uri':'a:b','contexts':{'delivery':true}}"))
        (list "billing on an organization" "{'organizations':{'o':{'name':'A','contexts':{'billing':true}}}}")
        (list "delivery on a pronoun" "{'speakToAs':{'pronouns':{'k':{'pronouns':'she','contexts':{'delivery':true}}}}}")
        (list "an address's context twice" (in-address "{'full':'x','contexts':{'billing':true,'billing':true}}"))
        (list "five in an address's set" (in-address "{'full':'x','contexts':{'private':true,'work':true,'billing':true,'delivery':true,'home':true}}"))))

;;; pref, and every number exact

(takes "pref"
  (list (list "1" (in-email "{'address':'a@b','pref':1}") "{'emails':{'e1':{'address':'a@b','pref':1}}}")
        (list "100" (in-email "{'address':'a@b','pref':100}") "{'emails':{'e1':{'address':'a@b','pref':100}}}")))

(refuses "pref"
  (list (list "0" (in-email "{'address':'a@b','pref':0}"))
        (list "101" (in-email "{'address':'a@b','pref':101}"))
        (list "-1" (in-email "{'address':'a@b','pref':-1}"))
        (list "1.0" (in-email "{'address':'a@b','pref':1.0}"))
        (list "100.0" (in-email "{'address':'a@b','pref':100.0}"))
        (list "1e2" (in-email "{'address':'a@b','pref':1e2}"))
        (list "0.5" (in-email "{'address':'a@b','pref':0.5}"))
        (list "-0" (in-email "{'address':'a@b','pref':-0}"))
        (list "2^53" (in-email "{'address':'a@b','pref':9007199254740992}"))
        (list "10^30" (in-email "{'address':'a@b','pref':1000000000000000000000000000000}"))
        (list "'1'" (in-email "{'address':'a@b','pref':'1'}"))
        (list "null" (in-email "{'address':'a@b','pref':null}"))
        (list "true" (in-email "{'address':'a@b','pref':true}"))
        (list "on a phone, 0" (in-phone "{'number':'1','pref':0}"))
        (list "on an address, 101" (in-address "{'full':'x','pref':101}"))
        (list "on a link, 1.0" (in-link "{'uri':'a:b','pref':1.0}"))
        (list "on a service, 0" (in-service "{'user':'a','pref':0}"))
        (list "on a pronoun, 101" "{'speakToAs':{'pronouns':{'k':{'pronouns':'she','pref':101}}}}")))

(refuses-values "numbers"
  (list (cons "an exact fraction as pref" (list (cons "emails" (list (cons "e1" (list (cons "address" "a@b") (cons "pref" 1/2)))))))
        (cons "an inexact integer as pref" (list (cons "emails" (list (cons "e1" (list (cons "address" "a@b") (cons "pref" 2.)))))))
        (cons "+inf.0 as pref" (list (cons "emails" (list (cons "e1" (list (cons "address" "a@b") (cons "pref" +inf.0)))))))
        (cons "+nan.0 as a year" (list (cons "anniversaries" (list (cons "b" (list (cons "kind" "birth") (cons "date" (list (cons "year" +nan.0)))))))))))

;;; Every string: not empty, no control character (a line feed only in an address's full), no noncharacter, at most 1,000 characters

(test-equal "strings: a label of 1,000 characters taken, and of 1,001 refused"
  (list (label-props (make-string 1000 #\x)) 'invalid)
  (list (attempt (lambda () (parse-contact-props (label-props (make-string 1000 #\x)))))
        (attempt (lambda () (parse-contact-props (label-props (make-string 1001 #\x)))))))

(test-equal "strings: 1,000 characters of three bytes each taken: characters are counted, not bytes"
  (label-props (make-string 1000 (integer->char #x4e2d)))
  (attempt (lambda () (parse-contact-props (label-props (make-string 1000 (integer->char #x4e2d)))))))

(test-equal "strings: an empty label refused"
  'invalid
  (attempt (lambda () (parse-contact-props (label-props "")))))

(for-each
 (lambda (c)
   (test-equal (string-append "strings: refuses " (car c))
     'invalid
     (attempt (lambda () (parse-contact-props (label-props (string #\a (integer->char (cdr c)) #\b)))))))
 (list (cons "U+0000" 0) (cons "U+FDD0, the first of the block" #xfdd0)
       (cons "U+FDEF, the last of the block" #xfdef) (cons "U+FFFE" #xfffe) (cons "U+FFFF" #xffff)
       (cons "U+1FFFE" #x1fffe) (cons "U+1FFFF" #x1ffff) (cons "U+10FFFE" #x10fffe)
       (cons "U+10FFFF" #x10ffff) (cons "U+5FFFE" #x5fffe)))

(test-equal "strings: just beside each noncharacter is taken: U+FDCF U+FDF0 U+FFFD U+1FFFD U+20000 U+10FFFD"
  (map (lambda (n) (label-props (string #\a (integer->char n))))
       '(#xfdcf #xfdf0 #xfffd #x1fffd #x20000 #x10fffd))
  (map (lambda (n) (attempt (lambda () (parse-contact-props (label-props (string #\a (integer->char n)))))))
       '(#xfdcf #xfdf0 #xfffd #x1fffd #x20000 #x10fffd)))

;;; No empty string and no control character, in every string of every object

;; control-points : (Listof Natural)     the control characters tried: C0 (some), DEL, C1 (ends)
(define control-points '(1 9 10 13 #x1f #x7f #x80 #x9f))

;; A StringSite is (List String String String (String -> Alist)): its name, the
;; text before and after the character tried (so a uri or an email stays
;; otherwise right), and the props that hold a string at that member.
(define (in-name-component s)
  (list (cons "name" (list (cons "components"
                                 (vector (list (cons "kind" "given") (cons "value" s))))))))
(define (in-unit s)
  (list (cons "organizations" (list (cons "o1" (list (cons "units" (vector (list (cons "name" s))))))))))
(define (in-one type id members)
  (list (cons type (list (cons id members)))))

(define string-sites
  (list
   (list "name component value" "a" "b" in-name-component)
   (list "organization name" "a" "b" (lambda (s) (in-one "organizations" "o1" (list (cons "name" s)))))
   (list "org unit name" "a" "b" in-unit)
   (list "title name" "a" "b" (lambda (s) (in-one "titles" "t1" (list (cons "name" s)))))
   (list "email address" "a" "@b" (lambda (s) (in-one "emails" "e1" (list (cons "address" s)))))
   (list "email label" "a" "b" (lambda (s) (in-one "emails" "e1" (list (cons "address" "a@b") (cons "label" s)))))
   (list "phone number" "1" "2" (lambda (s) (in-one "phones" "p1" (list (cons "number" s)))))
   (list "phone label" "a" "b" (lambda (s) (in-one "phones" "p1" (list (cons "number" "1") (cons "label" s)))))
   (list "address component value" "a" "b"
         (lambda (s) (in-one "addresses" "a1"
                             (list (cons "components" (vector (list (cons "kind" "locality") (cons "value" s))))))))
   (list "address countryCode" "U" "S" (lambda (s) (in-one "addresses" "a1" (list (cons "countryCode" s)))))
   (list "address full" "a" "b" (lambda (s) (in-one "addresses" "a1" (list (cons "full" s)))))
   (list "link uri" "http://x/" "" (lambda (s) (in-one "links" "l1" (list (cons "uri" s)))))
   (list "link label" "a" "b" (lambda (s) (in-one "links" "l1" (list (cons "uri" "http://x") (cons "label" s)))))
   (list "service" "a" "b" (lambda (s) (in-one "onlineServices" "s1" (list (cons "service" s) (cons "user" "u")))))
   (list "service uri" "http://x/" "" (lambda (s) (in-one "onlineServices" "s1" (list (cons "uri" s)))))
   (list "service user" "a" "b" (lambda (s) (in-one "onlineServices" "s1" (list (cons "user" s)))))
   (list "service label" "a" "b" (lambda (s) (in-one "onlineServices" "s1" (list (cons "user" "u") (cons "label" s)))))
   (list "pronouns" "a" "b"
         (lambda (s) (list (cons "speakToAs"
                                 (list (cons "pronouns" (list (cons "p1" (list (cons "pronouns" s))))))))))))

(define (site-name site) (car site))
(define (site-before site) (cadr site))
(define (site-after site) (caddr site))
(define (site-props site s) ((cadddr site) s))
(define (site-with site mid) (string-append (site-before site) mid (site-after site)))

(test-equal "strings: every string site is itself taken when plain (the sites are sound)"
  '()
  (attempt
   (lambda ()
     (filter (lambda (site)
               (let ((p (site-props site (site-with site "x"))))
                 (not (equal? (parse-contact-props p) p))))
             (filter (lambda (site) (not (string=? (site-name site) "address countryCode"))) string-sites)))))

(test-equal "strings: countryCode US is taken"
  (in-one "addresses" "a1" (list (cons "countryCode" "US")))
  (attempt (lambda () (parse-contact-props (in-one "addresses" "a1" (list (cons "countryCode" "US")))))))

(for-each
 (lambda (site)
   (test-equal (string-append "strings: " (site-name site) ": an empty string refused")
     'invalid
     (attempt (lambda () (parse-contact-props (site-props site ""))))))
 string-sites)

(for-each
 (lambda (site)
   (for-each
    (lambda (n)
      (unless (and (string=? (site-name site) "address full") (= n 10))
        (test-equal (string-append "strings: " (site-name site) ": U+" (number->string n 16) " refused")
          (quote invalid)
          (attempt (lambda () (parse-contact-props
                               (site-props site (site-with site (string (integer->char n))))))))))
    control-points))
 string-sites)

(test-equal "strings: an address's full takes a line feed, and the line feed is kept"
  (in-one "addresses" "a1" (list (cons "full" (string #\a #\newline #\b))))
  (attempt (lambda () (parse-contact-props (in-one "addresses" "a1" (list (cons "full" (string #\a #\newline #\b))))))))

(test-equal "strings: an address's full takes several line feeds, together and at its ends"
  (map (lambda (s) (in-one "addresses" "a1" (list (cons "full" s))))
       (list (string #\newline #\a) (string #\newline #\a #\newline #\newline #\b #\newline)))
  (attempt (lambda ()
             (map (lambda (s) (parse-contact-props (in-one "addresses" "a1" (list (cons "full" s)))))
                  (list (string #\newline #\a) (string #\newline #\a #\newline #\newline #\b #\newline))))))

(test-equal "strings: an address's full with a line feed and any other control character is refused: tab, carriage return, and the rest"
  '()
  (attempt
   (lambda ()
     (filter (lambda (n)
               (not (eq? 'invalid
                         (parse-contact-props
                          (in-one "addresses" "a1"
                                  (list (cons "full" (string #\a #\newline (integer->char n) #\b))))))))
             (filter (lambda (n) (not (= n 10))) (cons 0 control-points))))))

(test-equal "strings: an address component's value takes no line feed"
  'invalid
  (attempt (lambda ()
             (parse-contact-props
              (in-one "addresses" "a1"
                      (list (cons "components"
                                  (vector (list (cons "kind" "locality")
                                                (cons "value" (string #\a #\newline #\b)))))))))))

(test-equal "strings: white space beside a letter is taken in a label: U+0020, U+00A0, U+00A1, and in a full"
  (append (map (lambda (n) (label-props (string #\a (integer->char n) #\b))) '(#x20 #xa0 #xa1))
          (list (in-one "addresses" "a1" (list (cons "full" (string #\a #\space (integer->char #xa0) #\b))))))
  (attempt
   (lambda ()
     (append (map (lambda (n) (parse-contact-props (label-props (string #\a (integer->char n) #\b)))) '(#x20 #xa0 #xa1))
             (list (parse-contact-props (in-one "addresses" "a1" (list (cons "full" (string #\a #\space (integer->char #xa0) #\b))))))))))

;;; No line or paragraph separator (U+2028, U+2029) in any string, an
;;; address's full among them: its only line break is the line feed.
(for-each
 (lambda (site)
   (for-each
    (lambda (n)
      (test-equal (string-append "strings: " (site-name site) ": U+" (number->string n 16) " refused")
        'invalid
        (attempt (lambda () (parse-contact-props
                             (site-props site (site-with site (string (integer->char n)))))))))
    '(#x2028 #x2029)))
 string-sites)

(test-equal "strings: an address's full with a line feed and a separator is refused"
  '(invalid invalid)
  (attempt
   (lambda ()
     (map (lambda (n) (parse-contact-props
                       (in-one "addresses" "a1" (list (cons "full" (string #\a #\newline (integer->char n) #\b))))))
          '(#x2028 #x2029)))))

;;; No blank string: a string holds at least one character that is neither
;;; white space nor zero-width. The list is fixed here, and is not Chez's.

;; blank-points : (Listof Natural)
;; Unicode's White_Space that is no control character, then the zero-width
;; characters.
(define blank-points
  '(#x20 #xa0 #x1680 #x2000 #x2001 #x2002 #x2003 #x2004 #x2005 #x2006 #x2007
    #x2008 #x2009 #x200a #x2028 #x2029 #x202f #x205f #x3000
    #x200b #x200c #x200d #x2060 #xfeff))

(define (blank-site-refused? site s)
  (eq? 'invalid (parse-contact-props (site-props site s))))

(for-each
 (lambda (site)
   (test-equal (string-append "strings: " (site-name site) ": a string of one space refused, and of three")
     '(#t #t)
     (attempt (lambda () (list (blank-site-refused? site " ") (blank-site-refused? site "   "))))))
 string-sites)

(for-each
 (lambda (n)
   (test-equal (string-append "strings: a label of U+" (number->string n 16) " alone refused, and beside a letter taken")
     (list 'invalid 'invalid (label-props (string (integer->char n) #\a)) (label-props (string #\a (integer->char n))))
     (attempt
      (lambda ()
        (list (parse-contact-props (label-props (string (integer->char n))))
              (parse-contact-props (label-props (string (integer->char n) #\space (integer->char n))))
              (parse-contact-props (label-props (string (integer->char n) #\a)))
              (parse-contact-props (label-props (string #\a (integer->char n)))))))))
 (filter (lambda (n) (not (memv n '(#x2028 #x2029)))) blank-points))

(test-equal "strings: a label of every blank character together, but the two separators, refused"
  'invalid
  (attempt (lambda () (parse-contact-props
                       (label-props (list->string
                                     (map integer->char
                                          (filter (lambda (n) (not (memv n '(#x2028 #x2029)))) blank-points))))))))

(test-equal "strings: the characters next to the blank ones are no blank: U+0021, U+00A1, U+1681, U+1FFF, U+200E, U+2027, U+202A, U+2030, U+2061, U+3001, U+FF00"
  (map (lambda (n) (label-props (string (integer->char n)))) '(#x21 #xa1 #x1681 #x1fff #x200e #x2027 #x202a #x2030 #x2061 #x3001 #xff00))
  (attempt
   (lambda ()
     (map (lambda (n) (parse-contact-props (label-props (string (integer->char n)))))
          '(#x21 #xa1 #x1681 #x1fff #x200e #x2027 #x202a #x2030 #x2061 #x3001 #xff00)))))

(test-equal "strings: an address's full of line feeds alone refused, and of line feeds and spaces"
  '(invalid invalid invalid)
  (attempt
   (lambda ()
     (map (lambda (s) (parse-contact-props (in-one "addresses" "a1" (list (cons "full" s)))))
          (list (string #\newline) (string #\newline #\newline) (string #\space #\newline #\space))))))


;;; The rich contact (the plan's P8): a name, three emails, three phones,
;;; two addresses, an organisation, a title, pronouns, two links, a birthday,
;;; and a service. Sent out of order, with defaults and @type given.

(define rich-text
  (string-append
   "{'speakToAs':{'pronouns':{'k1':{'pref':1,'pronouns':'she/her'}},'grammaticalGender':'feminine'},"
   "'links':{'l2':{'label':'notes','uri':'https://notes.example.org/ada'},"
   "'l1':{'pref':1,'kind':'contact','uri':'https://lovelace.example.org/'}},"
   "'anniversaries':{'b':{'date':{'@type':'PartialDate','day':10,'month':12,'year':1815},'kind':'birth'}},"
   "'addresses':{'work':{'contexts':{'work':true},'full':'Ockham Park, Surrey','countryCode':'GB','isOrdered':false},"
   "'home':{'pref':1,'contexts':{'delivery':true,'private':true},'countryCode':'GB','isOrdered':true,"
   "'components':[{'value':'12','kind':'number'},{'kind':'name','value':'St James Square'},"
   "{'kind':'locality','value':'London'},{'kind':'postcode','value':'SW1Y 4JH'}]}},"
   "'phones':{'p3':{'label':'fax','features':{'fax':true},'number':'+44 20 7946 0020'},"
   "'p1':{'pref':1,'contexts':{'private':true},'features':{'text':true,'voice':true,'mobile':true},'number':'tel:+44-20-7946-0018'},"
   "'p2':{'contexts':{'work':true},'features':{'voice':true},'number':'+44 20 7946 0019'}},"
   "'emails':{'e3':{'address':'ada+notes@example.org'},"
   "'e1':{'pref':1,'contexts':{'private':true},'address':'ada@example.com','@type':'EmailAddress'},"
   "'e2':{'label':'office','contexts':{'work':true},'address':'a.lovelace@engines.example'}},"
   "'titles':{'t1':{'organizationId':'o1','kind':'title','name':'Mathematician'}},"
   "'organizations':{'o1':{'contexts':{'work':true},'units':[{'name':'Research'},{'name':'Notes'}],'name':'Analytical Engines Ltd'}},"
   "'name':{'isOrdered':true,'components':[{'kind':'title','value':'Dr.'},{'kind':'given','value':'Ada'},"
   "{'kind':'given2','value':'King'},{'kind':'surname','value':'Lovelace'}],'@type':'Name'},"
   "'kind':'individual',"
   "'onlineServices':{'s1':{'uri':'https://example.social/@ada','user':'@ada@example.social','service':'Mastodon'}}}"))

(define rich-canonical
  (string-append
   "{'name':{'components':[{'kind':'title','value':'Dr.'},{'kind':'given','value':'Ada'},"
   "{'kind':'given2','value':'King'},{'kind':'surname','value':'Lovelace'}],'isOrdered':true},"
   "'organizations':{'o1':{'name':'Analytical Engines Ltd','units':[{'name':'Research'},{'name':'Notes'}],'contexts':{'work':true}}},"
   "'titles':{'t1':{'name':'Mathematician','organizationId':'o1'}},"
   "'emails':{'e1':{'address':'ada@example.com','contexts':{'private':true},'pref':1},"
   "'e2':{'address':'a.lovelace@engines.example','contexts':{'work':true},'label':'office'},"
   "'e3':{'address':'ada+notes@example.org'}},"
   "'phones':{'p1':{'number':'tel:+44-20-7946-0018','features':{'mobile':true,'voice':true,'text':true},'contexts':{'private':true},'pref':1},"
   "'p2':{'number':'+44 20 7946 0019','features':{'voice':true},'contexts':{'work':true}},"
   "'p3':{'number':'+44 20 7946 0020','features':{'fax':true},'label':'fax'}},"
   "'addresses':{'home':{'components':[{'kind':'number','value':'12'},{'kind':'name','value':'St James Square'},"
   "{'kind':'locality','value':'London'},{'kind':'postcode','value':'SW1Y 4JH'}],"
   "'isOrdered':true,'countryCode':'GB','contexts':{'private':true,'delivery':true},'pref':1},"
   "'work':{'countryCode':'GB','full':'Ockham Park, Surrey','contexts':{'work':true}}},"
   "'anniversaries':{'b':{'kind':'birth','date':{'year':1815,'month':12,'day':10}}},"
   "'links':{'l1':{'uri':'https://lovelace.example.org/','kind':'contact','pref':1},"
   "'l2':{'uri':'https://notes.example.org/ada','label':'notes'}},"
   "'onlineServices':{'s1':{'service':'Mastodon','uri':'https://example.social/@ada','user':'@ada@example.social'}},"
   "'speakToAs':{'grammaticalGender':'feminine','pronouns':{'k1':{'pronouns':'she/her','pref':1}}}}"))

(sample! rich-text)

(test-equal "canonical: the rich contact, every member in the table's order, Ids sorted, sets in the plan's order, defaults and @type dropped"
  (q rich-canonical)
  (judge rich-text))

(test-equal "canonical: the rich contact's canonical text, read and judged, is itself"
  (q rich-canonical)
  (judge rich-canonical))

(test-equal "canonical: as the reader's own representation: strings, exact integers, #t, alists and vectors"
  '(("name" ("components" . #((("kind" . "given") ("value" . "Ada")))) ("isOrdered" . #t))
    ("emails" ("e1" ("address" . "a@b") ("contexts" ("work" . #t)) ("pref" . 7))))
  (attempt (lambda ()
             (parse-contact-props
              (j "{'emails':{'e1':{'pref':7,'contexts':{'work':true},'address':'a@b'}},'name':{'isOrdered':true,'components':[{'value':'Ada','kind':'given'}]}}")))))

(test-equal "defaults: kind individual, isOrdered false on a name and an address, a title's kind title: each given and dropped"
  (q "{'name':{'components':[{'kind':'given','value':'A'}]},'titles':{'t':{'name':'T'}},'addresses':{'a':{'full':'x'}}}")
  (judge "{'kind':'individual','name':{'isOrdered':false,'components':[{'kind':'given','value':'A'}]},'titles':{'t':{'kind':'title','name':'T'}},'addresses':{'a':{'isOrdered':false,'full':'x'}}}"))

(test-equal "defaults: what is no default is kept: kind org, isOrdered true, a title's kind role"
  (q "{'kind':'org','name':{'components':[{'kind':'given','value':'A'}],'isOrdered':true},'titles':{'t':{'name':'T','kind':'role'}}}")
  (judge "{'titles':{'t':{'kind':'role','name':'T'}},'name':{'isOrdered':true,'components':[{'kind':'given','value':'A'}]},'kind':'org'}"))

;;; Paths into a value, for the sweeps

;; object? : Any -> Boolean     what the reader makes of a non-empty JSON object
(define (object? v) (and (pair? v) (pair? (car v)) (string? (caar v))))

;; positions : Any -> (Listof (Pair Path Any))
;; Every member at every depth of V, and every element of every array, each
;; with its path (a list of names and indexes) and its value, in the order
;; met.
(define (positions v)
  (let walk ((v v) (path '()) (acc '()))
    (cond ((object? v)
           (fold-left (lambda (acc m)
                        (let ((p (append path (list (car m)))))
                          (walk (cdr m) p (cons (cons p (cdr m)) acc))))
                      acc v))
          ((vector? v)
           (let loop ((i 0) (acc acc))
             (if (= i (vector-length v))
                 acc
                 (let ((p (append path (list i))))
                   (loop (+ i 1) (walk (vector-ref v i) p (cons (cons p (vector-ref v i)) acc)))))))
          (else acc))))

;; replace-at : Any Path Any -> Any     V with the value at PATH made NEW
(define (replace-at v path new)
  (cond ((null? path) new)
        ((string? (car path))
         (map (lambda (m) (if (string=? (car m) (car path)) (cons (car m) (replace-at (cdr m) (cdr path) new)) m))
              v))
        (else
         (let loop ((i (- (vector-length v) 1)) (acc '()))
           (if (< i 0)
               (list->vector acc)
               (loop (- i 1) (cons (if (= i (car path)) (replace-at (vector-ref v i) (cdr path) new) (vector-ref v i))
                                   acc)))))))

;; value-at : Any Path -> Any
(define (value-at v path)
  (cond ((null? path) v)
        ((string? (car path)) (value-at (cdr (assoc (car path) v)) (cdr path)))
        (else (value-at (vector-ref v (car path)) (cdr path)))))

;; last-name : Path -> (U String #f)     the path's last member name, if it ends in one
(define (last-name path)
  (let ((l (and (pair? path) (car (reverse path)))))
    (and (string? l) l)))

;; under-set? : Path -> Boolean     whether PATH names an entry of contexts or features
(define (under-set? path)
  (and (>= (length path) 2)
       (member (list-ref path (- (length path) 2)) '("contexts" "features"))
       #t))

;; type-of-path : Path -> (U String #f)
;; The JSContact type of the object at PATH, from the names along it: * is
;; any Id or index. #f for what is no typed object (an Id map, a set, a
;; string, the top).
(define type-patterns
  '((("name") . "Name") (("name" "components" *) . "NameComponent")
    (("organizations" *) . "Organization") (("organizations" * "units" *) . "OrgUnit")
    (("titles" *) . "Title") (("emails" *) . "EmailAddress") (("phones" *) . "Phone")
    (("addresses" *) . "Address") (("addresses" * "components" *) . "AddressComponent")
    (("anniversaries" *) . "Anniversary") (("anniversaries" * "date") . "PartialDate")
    (("links" *) . "Link") (("onlineServices" *) . "OnlineService")
    (("speakToAs") . "SpeakToAs") (("speakToAs" "pronouns" *) . "Pronouns")))

(define (matches? pattern path)
  (and (= (length pattern) (length path))
       (for-all (lambda (p x) (or (eq? p '*) (equal? p x))) pattern path)))

(define (type-of-path path)
  (let ((hit (find (lambda (tp) (matches? (car tp) path)) type-patterns)))
    (and hit (cdr hit))))

(define type-names (map cdr type-patterns))

;; with-member : Alist String Any -> Alist     OBJ with NAME's value VALUE, replaced or put last
(define (with-member obj name value)
  (if (assoc name obj)
      (map (lambda (m) (if (string=? (car m) name) (cons name value) m)) obj)
      (append obj (list (cons name value)))))

(define rich (attempt (lambda () (j rich-text))))
(define rich-answer (attempt (lambda () (parse-contact-props rich))))

;;; @type, on every object of the rich contact

(for-each
 (lambda (type)
   (test-equal (string-append "@type: " type ": taken and dropped where it is right; every other type, another case, Card, Resource, '', 1, null refused")
     '(#t ())
     (attempt
      (lambda ()
        (let* ((paths (map car (filter (lambda (p) (equal? (type-of-path (car p)) type)) (positions rich))))
               (wrong (append (filter (lambda (t) (not (string=? t type))) type-names)
                              (list (string-downcase type) (string-upcase type) "Card" "Resource" "" 1 'null)))
               (bad (fold-left
                     (lambda (bad path)
                       (let* ((obj (value-at rich path))
                              (right (parse-contact-props (replace-at rich path (with-member obj "@type" type))))
                              (bad (if (equal? right rich-answer) bad (cons (list path type right) bad))))
                         (fold-left (lambda (bad w)
                                      (let ((r (parse-contact-props (replace-at rich path (with-member obj "@type" w)))))
                                        (if (eq? r 'invalid) bad (cons (list path w r) bad))))
                                    bad wrong)))
                     '() paths)))
          (list (pair? paths) bad))))))
 type-names)

(test-equal "@type: given twice on one object, even right both times, refused"
  'invalid
  (judge "{'name':{'@type':'Name','components':[{'kind':'given','value':'A'}],'@type':'Name'}}"))

;;; A name given twice, in every object at every depth

(test-equal "twice: every object of the rich contact, the top, Id maps and sets too, with its first member given again last, refused"
  '(#t ())
  (attempt
   (lambda ()
     (let* ((objects (cons '() (map car (filter (lambda (p) (object? (cdr p))) (positions rich)))))
            (bad (fold-left (lambda (bad path)
                              (let* ((obj (value-at rich path))
                                     (r (parse-contact-props (replace-at rich path (append obj (list (car obj)))))))
                                (if (eq? r 'invalid) bad (cons (list path r) bad))))
                            '() objects)))
       (list (> (length objects) 40) bad)))))

(test-equal "twice: every object of the rich contact, with its first member given again first with another value, refused"
  '(#t ())
  (attempt
   (lambda ()
     (let* ((objects (cons '() (map car (filter (lambda (p) (object? (cdr p))) (positions rich)))))
            (bad (fold-left (lambda (bad path)
                              (let* ((obj (value-at rich path))
                                     (r (parse-contact-props
                                         (replace-at rich path (cons (cons (caar obj) 'null) obj)))))
                                (if (eq? r 'invalid) bad (cons (list path r) bad))))
                            '() objects)))
       (list (> (length objects) 40) bad)))))

(refuses "twice"
  (list (list "kind at the top" "{'kind':'org','kind':'org'}")
        (list "components in a name" "{'name':{'components':[{'kind':'given','value':'A'}],'components':[{'kind':'given','value':'A'}]}}")
        (list "value in a component" "{'name':{'components':[{'kind':'given','value':'A','value':'B'}]}}")
        (list "an Id in emails" "{'emails':{'e1':{'address':'a@b'},'e1':{'address':'c@d'}}}")
        (list "an Id, the same entry" "{'emails':{'e1':{'address':'a@b'},'e1':{'address':'a@b'}}}")
        (list "an Id, far apart" "{'emails':{'e1':{'address':'a@b'},'e2':{'address':'a@b'},'e3':{'address':'a@b'},'e1':{'address':'a@b'}}}")
        (list "address in an email" (in-email "{'address':'a@b','address':'a@b'}"))
        (list "year in a date" (in-date "{'year':1815,'year':1815}"))
        (list "name in a unit" "{'organizations':{'o':{'units':[{'name':'A','name':'A'}]}}}")
        (list "pronouns in a pronoun entry" "{'speakToAs':{'pronouns':{'k':{'pronouns':'a','pronouns':'a'}}}}")
        (list "grammaticalGender in speakToAs" "{'speakToAs':{'grammaticalGender':'neuter','grammaticalGender':'neuter'}}")
        (list "private in contexts" (in-email "{'address':'a@b','contexts':{'private':true,'private':true}}"))))

;;; One value, one text, whatever the order sent (R17); idempotent

;; reversed : Any -> Any     V with every object's members, at every depth, in reverse; arrays as they are
(define (reversed v)
  (cond ((object? v) (reverse (map (lambda (m) (cons (car m) (reversed (cdr m)))) v)))
        ((vector? v) (vector-map reversed v))
        (else v)))

;; rotated : Any -> Any     every object's first member moved last, at every depth
(define (rotated v)
  (cond ((object? v)
         (let ((ms (map (lambda (m) (cons (car m) (rotated (cdr m)))) v)))
           (append (cdr ms) (list (car ms)))))
        ((vector? v) (vector-map rotated v))
        (else v)))

(test-equal "R17: the rich contact sent with every object, Id map and set reversed, or rotated (each another input), answers the same value"
  '(#t #t #t #f #f)
  (attempt (lambda ()
             (let ((a (parse-contact-props rich)))
               (list (and (pair? a) #t)
                     (equal? (parse-contact-props (reversed rich)) a)
                     (equal? (parse-contact-props (rotated rich)) a)
                     (equal? (reversed rich) rich)
                     (equal? (rotated rich) rich))))))

(test-equal "R17: an array's order is kept: components sent reversed come back reversed"
  (q "{'name':{'components':[{'kind':'surname','value':'L'},{'kind':'given','value':'A'}]}}")
  (judge "{'name':{'components':[{'kind':'surname','value':'L'},{'kind':'given','value':'A'}]}}"))

(test-equal "R17: Id maps sorted by string<?: by code point, upper case before lower, 10 before 9"
  (q "{'emails':{'-':{'address':'a@b'},'10':{'address':'a@b'},'9':{'address':'a@b'},'A':{'address':'a@b'},'_':{'address':'a@b'},'a':{'address':'a@b'}}}")
  (judge "{'emails':{'a':{'address':'a@b'},'9':{'address':'a@b'},'_':{'address':'a@b'},'A':{'address':'a@b'},'10':{'address':'a@b'},'-':{'address':'a@b'}}}"))

(test-equal "idempotent: every sample taken in this suite, its answer judged again, answers itself"
  '(#t ())
  (attempt
   (lambda ()
     (let ((bad (fold-left (lambda (bad text)
                             (let* ((a (parse-contact-props (j text)))
                                    (b (if (eq? a 'invalid) 'first-refused (parse-contact-props a))))
                               (if (equal? a b) bad (cons (list text a b) bad))))
                           '() taken-samples)))
       (list (> (length taken-samples) 20) bad)))))

;;; Every string position of the rich contact, under the string rules

;; free-text-names : the members whose value is any string (no enum, address, uri or code)
(define free-text-names '("value" "name" "label" "number" "full" "service" "user" "pronouns"))

(test-equal "strings: every string in the rich contact, with U+0000, U+FDD0, U+FFFE, U+1FFFF, U+0001, tab, U+007F or U+009F added, refused"
  '(#t ())
  (attempt
   (lambda ()
     (let* ((paths (map car (filter (lambda (p) (string? (cdr p))) (positions rich))))
            (bad (fold-left
                  (lambda (bad path)
                    (fold-left (lambda (bad n)
                                 (let ((r (parse-contact-props
                                           (replace-at rich path (string-append (value-at rich path)
                                                                                (string (integer->char n)))))))
                                   (if (eq? r 'invalid) bad (cons (list path n r) bad))))
                               bad '(0 #xfdd0 #xfffe #x1ffff 1 9 #x7f #x9f)))
                  '() paths)))
       (list (> (length paths) 40) bad)))))

(test-equal "strings: every free-text string in the rich contact: 1,000 characters taken, 1,001 refused"
  '(#t ())
  (attempt
   (lambda ()
     (let* ((paths (map car (filter (lambda (p) (and (string? (cdr p)) (member (last-name (car p)) free-text-names)))
                                    (positions rich))))
            (bad (fold-left
                  (lambda (bad path)
                    (let ((long (parse-contact-props (replace-at rich path (make-string 1000 #\x))))
                          (over (parse-contact-props (replace-at rich path (make-string 1001 #\x)))))
                      (cond ((not (and (pair? long) (equal? (value-at long path) (make-string 1000 #\x))))
                             (cons (list path 1000 long) bad))
                            ((not (eq? over 'invalid)) (cons (list path 1001 over) bad))
                            (else bad))))
                  '() paths)))
       (list (> (length paths) 15) bad)))))

(test-equal "strings: every free-text string in the rich contact made empty is refused"
  '(#t ())
  (attempt
   (lambda ()
     (let* ((paths (map car (filter (lambda (p) (and (string? (cdr p)) (member (last-name (car p)) free-text-names)))
                                    (positions rich))))
            (bad (filter (lambda (path) (not (eq? 'invalid (parse-contact-props (replace-at rich path "")))))
                         paths)))
       (list (> (length paths) 15) bad)))))

;;; Hostile shapes: every wrong type, at the top and in every position

;; A hostile value, tagged with what it is; a position takes a tag only
;; where the value could be right there (a string where a string goes).
(define hostiles
  (list (cons 'integer 7) (cons 'integer 0) (cons 'integer -1) (cons 'integer (expt 10 30))
        (cons 'number 1.0) (cons 'number 0.5) (cons 'number -0.0) (cons 'number +inf.0) (cons 'number 1/2)
        (cons 'string "") (cons 'string "x") (cons 'string "a@b")
        (cons 'empty-array '#()) (cons 'bad-array (vector "x")) (cons 'bad-array (vector '()))
        (cons 'bad-array (vector 'null)) (cons 'bad-array (vector (vector)))
        (cons 'null 'null) (cons 'true #t) (cons 'false #f)
        (cons 'empty-object '()) (cons 'bad-object '(("x" . 1))) (cons 'bad-object '(("" . "")))
        (cons 'bad-object '(("@type" . "Card")))
        (cons 'other (cons '("name" . "x") 5)) (cons 'other '("name" "x")) (cons 'other '((name . "x")))
        (cons 'other 'name) (cons 'other #\a) (cons 'other (string->utf8 "x")) (cons 'other (list 1 2))
        (cons 'other (lambda () 'x)) (cons 'other (list (vector "kind" "org")))))

;; position-tags : Path Any -> (Listof Symbol)     the tags a position may take
(define (position-tags path v)
  (cond ((equal? (last-name path) "isOrdered") '(true false))
        ((string? v) '(string))
        ((and (integer? v) (exact? v)) '(integer))
        ((eq? v #t) '(true))
        (else '())))

;; hostile-sweep : (Path -> Boolean) -> (List Boolean (Listof Any))
;; Every hostile value at every position the predicate picks, where its tag
;; is not the position's: whether any was judged, and each that was not
;; refused, with its path, the value and the answer.
(define (hostile-sweep pick?)
  (let* ((ps (filter (lambda (p) (pick? (car p))) (positions rich)))
         (n 0)
         (bad (fold-left
               (lambda (bad p)
                 (let ((tags (position-tags (car p) (cdr p))))
                   (fold-left (lambda (bad h)
                                (if (memq (car h) tags)
                                    bad
                                    (let ((r (attempt (lambda () (parse-contact-props (replace-at rich (car p) (cdr h)))))))
                                      (set! n (+ n 1))
                                      (if (eq? r 'invalid) bad (cons (list (car p) (cdr h) r) bad)))))
                              bad hostiles)))
               '() ps)))
    (list (> n 0) bad)))

(test-equal "hostile: as the whole props, every shape refused but {}, and nothing raised"
  (map (lambda (h) (if (eq? (car h) 'empty-object) '() 'invalid)) hostiles)
  (map (lambda (h) (attempt (lambda () (parse-contact-props (cdr h))))) hostiles))

(for-each
 (lambda (member)
   (test-equal (string-append "hostile: every position under " member ", each wrong shape refused, and nothing raised")
     '(#t ())
     (attempt (lambda () (hostile-sweep (lambda (path) (equal? (car path) member)))))))
 '("kind" "name" "organizations" "titles" "emails" "phones" "addresses" "anniversaries" "links"
   "onlineServices" "speakToAs"))

(test-equal "hostile: a circular object at the top, and one as a member's value, refused, and nothing raised"
  '(invalid invalid invalid)
  (attempt (lambda ()
             (let ((top (list (cons "kind" "org")))
                   (map-of (list (cons "e1" '(("address" . "a@b")))))
                   (self (list (cons "name" #f))))
               (set-cdr! top top)
               (set-cdr! map-of map-of)
               (set-cdr! (car self) self)
               (list (parse-contact-props top)
                     (parse-contact-props (list (cons "emails" map-of)))
                     (parse-contact-props self))))))

;;; Linear (R10): an Id map of 95,000 entries; 100,000 members refused at once

;; entries : Natural (Natural -> String) Any -> Alist     N entries, keys made by KEY, all of VALUE, the last made first
(define (entries n key value)
  (let loop ((i 0) (acc '()))
    (if (= i n) acc (loop (+ i 1) (cons (cons (key i) value) acc)))))

;; iota-list : Natural -> (Listof Natural)     0 to N - 1
(define (iota-list n)
  (let loop ((i (- n 1)) (acc (quote ())))
    (if (< i 0) acc (loop (- i 1) (cons i acc)))))

(define (e-key i) (string-append "e" (number->string i)))

;; timed : (-> Any) -> (List Any Natural)     THUNK's answer and the milliseconds it took
(define (timed thunk)
  (let* ((t0 (real-time)) (r (thunk)) (t1 (real-time)))
    (list r (- t1 t0))))

;; 95,000 emails, sent last first: 2,553,902 bytes as JSON, past the request's
;; 2 MiB cap, so more than a request can bring.
(test-equal "linear: 95,000 emails judged in under 500 ms: 95,000 entries, sorted, e0 first and e9999 last"
  '(95000 "e0" "e9999" quick)
  (attempt (lambda ()
             (let* ((x (list (cons "emails" (entries 95000 e-key '(("address" . "a@b"))))))
                    (t (timed (lambda () (parse-contact-props x))))
                    (es (cdr (assoc "emails" (car t)))))
               (list (length es) (car (car es)) (car (car (reverse es)))
                     (if (< (cadr t) 500) 'quick (cadr t)))))))

(test-equal "linear: 95,000 emails with the first Id given again last, refused in under 500 ms"
  '(invalid quick)
  (attempt (lambda ()
             (let* ((x (list (cons "emails" (append (entries 95000 e-key '(("address" . "a@b")))
                                                    (list (cons "e94999" '(("address" . "a@b"))))))))
                    (t (timed (lambda () (parse-contact-props x)))))
               (list (car t) (if (< (cadr t) 500) 'quick (cadr t)))))))

;; 40,000 organizations and 40,000 titles, each title in its own
;; organization: found by a hashtable, not by a walk of the organizations.
(test-equal "linear: 40,000 titles, each naming one of 40,000 organizations, judged in under 500 ms"
  '(40000 40000 quick)
  (attempt (lambda ()
             (let* ((x (list (cons "titles" (map (lambda (i) (cons (e-key i) (list (cons "name" "T") (cons "organizationId" (e-key i)))))
                                                 (iota-list 40000)))
                             (cons "organizations" (entries 40000 e-key '(("name" . "O"))))))
                    (t (timed (lambda () (parse-contact-props x)))))
               (list (length (cdr (assoc "organizations" (car t)))) (length (cdr (assoc "titles" (car t))))
                     (if (< (cadr t) 500) 'quick (cadr t)))))))

;; members : Natural Alist -> Alist     HEAD, then members named x0, x1 and on up to N in all
(define (members n head)
  (append head (entries (- n (length head)) (lambda (i) (string-append "x" (number->string i))) 1)))

;; refused-at-once : (-> Any) -> (List Any (U 'quick Natural) (U 'small Natural))
;; MAKE builds the props first; only the judging is measured: its answer,
;; 'quick under 10 ms, and 'small under 16 KiB allocated.
(define (refused-at-once make)
  (attempt (lambda ()
             (let* ((x (make))
                    (a0 (allocated))
                    (t0 (real-time))
                    (r (parse-contact-props x))
                    (t1 (real-time))
                    (a1 (allocated)))
               (list r (if (< (- t1 t0) 10) 'quick (- t1 t0)) (if (< (- a1 a0) 16384) 'small (- a1 a0)))))))

;; eleven : Alist     the eleven members, named once each, as data: never judged by the tests that use it
(define eleven
  (cons (cons "kind" "org")
        (map (lambda (name) (cons name (quote null)))
             (quote ("name" "organizations" "titles" "emails" "phones" "addresses" "anniversaries" "links"
                     "onlineServices" "speakToAs")))))

(test-equal "bounded: 100,000 members at the top, the eleven first, refused at once, allocating next to nothing"
  '(invalid quick small)
  (refused-at-once (lambda () (members 100000 eleven))))

(test-equal "bounded: 100,000 members at the top, all named kind, refused at once, allocating next to nothing"
  '(invalid quick small)
  (refused-at-once (lambda () (entries 100000 (lambda (i) "kind") "org"))))

(test-equal "bounded: 100,000 members in an email, refused at once, allocating next to nothing"
  '(invalid quick small)
  (refused-at-once (lambda () (list (cons "emails" (list (cons "e1" (members 100000 '(("address" . "a@b"))))))))))

(test-equal "bounded: 100,000 members in a name, refused at once, allocating next to nothing"
  '(invalid quick small)
  (refused-at-once (lambda () (list (cons "name" (members 100000 '(("isOrdered" . #t))))))))

(test-equal "bounded: 100,000 members in a contexts set, refused at once, allocating next to nothing"
  '(invalid quick small)
  (refused-at-once (lambda () (list (cons "emails" (list (cons "e1" (list (cons "address" "a@b")
                                                                          (cons "contexts" (members 100000 '(("private" . #t) ("work" . #t))))))))))))

;; The names are counted before any value is read: a twelfth member is
;; found before the 95,000 emails, sent first, are judged.
(test-equal "bounded: twelve members, the first 95,000 emails, refused before any value is read"
  '(invalid quick small)
  (refused-at-once (lambda () (append (list (cons "emails" (entries 95000 e-key '(("address" . "a@b")))))
                                      (cdr eleven)
                                      (list (cons "x" 1))))))

(test-equal "bounded: the same twelve with the emails last, refused as quickly"
  '(invalid quick small)
  (refused-at-once (lambda () (append (cdr eleven) (list (cons "x" 1))
                                      (list (cons "emails" (entries 95000 e-key '(("address" . "a@b")))))))))

;; best-us : (-> Any) Natural -> Natural
;; The fewest microseconds THUNK took in K runs, on the monotonic clock: the
;; best of several is what a pause elsewhere cannot lengthen.
(define (best-us thunk k)
  (let ((now (lambda ()
               (let ((t (current-time 'time-monotonic)))
                 (+ (* (time-second t) 1000000) (div (time-nanosecond t) 1000))))))
    (let loop ((i 0) (best #f))
      (if (= i k)
          best
          (let* ((t0 (now)) (r (thunk)) (t1 (now)))
            (loop (+ i 1) (if (or (not best) (< (- t1 t0) best)) (- t1 t0) best)))))))

;; A walk of the whole list before its names are read (list?, length) takes
;; no bytes, so the bounds above cannot see it: at 1,000,000 members it took
;; 2.2 ms at best where the bounded refusal took under 1 us (measured here).
(test-equal "bounded: 1,000,000 members at the top refused in under 0.5 ms at the best of five: no walk of the whole list"
  '(invalid quick)
  (attempt (lambda ()
             (let* ((x (entries 1000000 (lambda (i) "kind") "org"))
                    (r (parse-contact-props x))
                    (us (best-us (lambda () (parse-contact-props x)) 5)))
               (list r (if (< us 500) 'quick us))))))

(test-end "contact")

(exit (suite-exit-status runner))
