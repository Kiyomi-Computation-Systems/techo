#!r6rs
;;; The address suite: L3's address keys and L4's client address. All pure.
;;; Every call is under `attempt`, so a raise is a value the expectation
;;; never is.
(import (rnrs)
        (srfi :64)
        (techo-testing)
        (techo address))

(define runner (test-runner-simple))
(test-runner-current runner)

;; attempt : (-> A) -> (U A (List 'raised String))
(define (attempt thunk)
  (guard (e (#t (list 'raised (describe e))))
    (thunk)))

(define (key s) (attempt (lambda () (address-key s))))
(define (entry s) (attempt (lambda () (entry->address s))))
(define (client n fields peer) (attempt (lambda () (client-address n fields peer))))

(test-begin "address")

;;; address-key: spelling -> key

(define key-table
  '(("1.2.3.4" "v4:1.2.3.4")
    ("0.0.0.0" "v4:0.0.0.0")
    ("255.255.255.255" "v4:255.255.255.255")
    ("127.0.0.1" "v4:127.0.0.1")
    ("10.0.0.0" "v4:10.0.0.0")
    ;; IPv4-mapped, however written
    ("::ffff:7f00:1" "v4:127.0.0.1")
    ("::FFFF:127.0.0.1" "v4:127.0.0.1")
    ("0:0:0:0:0:FFFF:127.0.0.1" "v4:127.0.0.1")
    ("0000:0000:0000:0000:0000:ffff:7f00:0001" "v4:127.0.0.1")
    ("::ffff:1.2.3.4" "v4:1.2.3.4")
    ("::ffff:102:304" "v4:1.2.3.4")
    ("::ffff:0:0" "v4:0.0.0.0")
    ;; other IPv6: first 64 bits
    ("::1" "v6:0000000000000000")
    ("::" "v6:0000000000000000")
    ("2001:db8::1" "v6:20010db800000000")
    ("2001:DB8::1" "v6:20010db800000000")
    ("2001:db8:0:0::1" "v6:20010db800000000")
    ("2001:db8:1:2:3:4:5:6" "v6:20010db800010002")
    ("2001:db8:1:2::" "v6:20010db800010002")
    ("fe80::1%eth0" "v6:fe80000000000000")
    ("fe80::1%25eth0" "v6:fe80000000000000")
    ("1:2:3:4:5:6:1.2.3.4" "v6:0001000200030004")
    ("::1.2.3.4" "v6:0000000000000000")
    ("64:ff9b::1.2.3.4" "v6:0064ff9b00000000")
    ("1::" "v6:0001000000000000")
    ;; not ::ffff:0:0/96
    ("::fffe:7f00:1" "v6:0000000000000000")
    ("1::ffff:7f00:1" "v6:0001000000000000")
    ("0:0:0:1:0:ffff:7f00:1" "v6:0000000000000001")
    ;; only the fifth group is not zero: a test of four groups would call
    ;; these IPv4
    ("::1:ffff:1.2.3.4" "v6:0000000000000000")
    ("0:0:0:0:1:ffff:102:304" "v6:0000000000000000")
    ;; bad
    ("" "unknown")
    ("127.1" "unknown")
    ("0177.0.0.1" "unknown")
    ("01.2.3.4" "unknown")
    ("1.2.3.256" "unknown")
    ("1.2.3" "unknown")
    ("1.2.3.4.5" "unknown")
    ("1.2.3." "unknown")
    (".1.2.3" "unknown")
    ("1..2.3" "unknown")
    ("1.2.3.0004" "unknown")
    ("1.2.3.-4" "unknown")
    ("1.2.3.+4" "unknown")
    ("1.2.3.4 " "unknown")
    (" 1.2.3.4" "unknown")
    ("1.2.3.4:80" "unknown")
    ("0x7f.0.0.1" "unknown")
    ("2130706433" "unknown")
    (":::" "unknown")
    (":" "unknown")
    ("1::2::3" "unknown")
    ("1:2:3:4:5:6:7:8:9" "unknown")
    ("1:2:3:4:5:6:7" "unknown")
    ("1:2:3:4:5:6:7:8::" "unknown")
    ("1:2:3:4:5:6:7::8" "unknown")
    ("12345::1" "unknown")
    ("::g" "unknown")
    (":1::2" "unknown")
    ("1::2:" "unknown")
    ("1:2:3:4:5:6:7:1.2.3.4" "unknown")
    ("::1.2.3" "unknown")
    ("::1.2.3.4:5" "unknown")
    ("1.2.3.4::" "unknown")
    ("[::1]" "unknown")
    ("localhost" "unknown")
    ("unknown" "unknown")))

(for-each
 (lambda (row)
   (test-equal (string-append "key: " (car row))
     (cadr row)
     (key (car row))))
 key-table)

(test-equal "key: #f is unknown" "unknown" (key #f))

(test-equal "key: ::ffff:7f00:1, ::FFFF:127.0.0.1 and 127.0.0.1 share one key"
  3
  (length (filter (lambda (k) (equal? k (key "127.0.0.1")))
                  (list (key "::ffff:7f00:1") (key "::FFFF:127.0.0.1") (key "127.0.0.1")))))

(test-assert "key: ::1 does not share 127.0.0.1's key"
  (not (equal? (key "::1") (key "127.0.0.1"))))

(test-equal "key: two addresses in one /64 share a key"
  (key "2001:db8:1:2::1")
  (key "2001:db8:1:2:ffff:ffff:ffff:ffff"))

(test-assert "key: addresses in different /64s differ"
  (not (equal? (key "2001:db8:1:2::1") (key "2001:db8:1:3::1"))))

(test-assert "key: an IPv4 key and an IPv6 key are never the same text"
  (not (equal? (key "1.2.3.4") (key "1:2:3:4::"))))

;;; entry->address

(define entry-table
  '(("1.2.3.4" "1.2.3.4")
    ("1.2.3.4:5678" "1.2.3.4")
    ("1.2.3.4:1" "1.2.3.4")
    ("2001:db8::1" "2001:db8::1")
    ("[2001:db8::1]" "2001:db8::1")
    ("[2001:db8::1]:443" "2001:db8::1")
    ("[::ffff:1.2.3.4]:80" "::ffff:1.2.3.4")
    ("::1" "::1")
    ;; not addresses
    ("" #f)
    ("unknown" #f)
    ("_hidden" #f)
    ("example.com" #f)
    ("example.com:80" #f)
    ("1.2.3.4:" #f)
    ("1.2.3.4:abc" #f)
    ("1.2.3.4:123456" #f)
    ("1.2.3.4:80:90" #f)
    ("[1.2.3.4]" #f)
    ("[2001:db8::1" #f)
    ("[2001:db8::1]:" #f)
    ("[2001:db8::1]x" #f)
    ("[2001:db8::1]:44x" #f)
    ("[]" #f)
    ("[unknown]" #f)
    ("127.1" #f)
    ("1.2.3.256:80" #f)
    ("0177.0.0.1" #f)))

(for-each
 (lambda (row)
   (test-equal (string-append "entry: [" (car row) "]")
     (cadr row)
     (entry (car row))))
 entry-table)

;;; client-address

(test-equal "client: 0 proxies is the peer"
  "9.9.9.9"
  (client 0 '("1.1.1.1") "9.9.9.9"))

(test-equal "client: 0 proxies and no peer is #f"
  #f
  (client 0 '("1.1.1.1") #f))

(test-equal "client: Q8, N=1 is the last entry whatever the client put before it"
  "1.1.1.1"
  (client 1 '("6.6.6.6, 9.9.9.9" "1.1.1.1") "5.5.5.5"))

(test-equal "client: Q8, N=1, one field, the last of its entries"
  "9.9.9.9"
  (client 1 '("6.6.6.6, 9.9.9.9") "5.5.5.5"))

(test-equal "client: N=2 is the one before the last"
  "9.9.9.9"
  (client 2 '("6.6.6.6, 9.9.9.9" "1.1.1.1") "5.5.5.5"))

(test-equal "client: N=3 across fields"
  "6.6.6.6"
  (client 3 '("6.6.6.6, 9.9.9.9" "1.1.1.1") "5.5.5.5"))

(test-equal "client: a list shorter than N is the peer"
  "5.5.5.5"
  (client 4 '("6.6.6.6, 9.9.9.9" "1.1.1.1") "5.5.5.5"))

(test-equal "client: no fields is the peer"
  "5.5.5.5"
  (client 1 '() "5.5.5.5"))

(test-equal "client: no fields and no peer is #f"
  #f
  (client 1 '() #f))

(test-equal "client: the entry is no address, so the peer"
  "5.5.5.5"
  (client 1 '("6.6.6.6, unknown") "5.5.5.5"))

(test-equal "client: a host name is the peer"
  "5.5.5.5"
  (client 1 '("example.com") "5.5.5.5"))

(test-equal "client: a port is stripped"
  "1.2.3.4"
  (client 1 '("6.6.6.6, 1.2.3.4:5678") "5.5.5.5"))

(test-equal "client: brackets are stripped"
  "2001:db8::1"
  (client 1 '("[2001:db8::1]") "5.5.5.5"))

(test-equal "client: brackets and a port are stripped"
  "2001:db8::1"
  (client 1 '("6.6.6.6,[2001:db8::1]:443") "5.5.5.5"))

(test-equal "client: empty entries are dropped"
  "6.6.6.6"
  (client 2 '(", 6.6.6.6,, ,1.1.1.1,") "5.5.5.5"))

(test-equal "client: spaces and tabs are trimmed"
  "1.1.1.1"
  (client 1 '("6.6.6.6 ,\t 1.1.1.1\t ") "5.5.5.5"))

(test-equal "client: an empty field adds nothing"
  "6.6.6.6"
  (client 1 '("6.6.6.6" "" " , ") "5.5.5.5"))

(test-equal "client: only empty entries is the peer"
  "5.5.5.5"
  (client 1 '(" , ," "") "5.5.5.5"))

(test-equal "client: the answer is the entry text, and address-key reads it"
  "v4:127.0.0.1"
  (attempt (lambda () (address-key (client-address 1 '("::ffff:7f00:1") "5.5.5.5")))))

(test-end "address")

(exit (suite-exit-status runner))
