#!r6rs
;;; The tags suite: slice 7a's tags, (techo tags). All pure.
;;;
;;;   the caps          50 a node, 64 folded, 256 sent, 500 a step, 10 a filter
;;;   the owner's       G3's examples and the plan's answers, each as the plan
;;;   examples          gives it
;;;   the corpus        what Chez's Unicode tables decide, pinned (as
;;;                     test-contact.sps pins chez-uri): an upgrade that
;;;                     moves the rule fails here
;;;   the boundaries    256 and 257 sent, 64 and 65 folded, the raw cap before
;;;                     any folding, white space, every control the plan
;;;                     names, every invisible, private use and dash range's
;;;                     ends and neighbours, an unassigned code point read
;;;                     before any folding, a mark first and after, an emoji
;;;                     with and without U+FE0F
;;;   the laws          L1 (folding a stored tag gives that tag) and the
;;;                     stored form, over every scalar value, every capital
;;;                     before each combining mark, and generated strings
;;;                     from every plane, with fixed seeds
;;;   request-tags      absent and none; the cap counted as sent, before any
;;;                     entry is read; sorted, distinct; every refusal
;;;   filter-tags       10 and 11 as sent; none
;;;   the commands      parse-rename-body and parse-remove-body
;;;   the snapshot      tags->json and json->tags, and what they raise
;;;   the rules         nothing else raises, whatever it is given; no raise
;;;                     carries a tag; no export is a name (rnrs) or
;;;                     (chezscheme) exports
;;;
;;; Everything that can raise is computed under `attempt`, and a raise comes
;;; out as a value the expectation never is.
(import (rnrs)
        (srfi :64)
        (only (chezscheme) real-time bytes-allocated bytes-deallocated library-exports)
        (only (jsonparse easy) json->string)
        (techo-testing)
        (techo chars)
        (techo tags))

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

(define (written x) (call-with-string-output-port (lambda (p) (write x p))))

;; lit : String -> String     S as a string literal, every character past ASCII as \x..;
(define (lit s)
  (string-append
   "\""
   (apply string-append
          (map (lambda (c)
                 (let ((n (char->integer c)))
                   (cond ((char=? c #\") "\\\"")
                         ((char=? c #\\) "\\\\")
                         ((<= #x20 n #x7E) (string c))
                         (else (string-append "\\x" (string-downcase (number->string n 16)) ";")))))
               (string->list s)))
   "\""))

;; shown : Any -> String     a tag or a refusal, for a test's name
(define (shown x) (if (string? x) (lit x) (written x)))

;; fold : Any -> (U String Symbol (List 'raised String))     normalise-tag, under attempt
(define (fold x) (attempt (lambda () (normalise-tag x))))

(define (chars . points) (list->string (map integer->char points)))

;; allocated : -> Natural     every byte allocated so far, collected or not
(define (allocated) (+ (bytes-allocated) (bytes-deallocated)))

;; refused-at-once : (-> Any) (Any -> Any) -> (List Any (U 'quick Natural) (U 'small Natural))
;; MAKE builds the argument first; only CALL is measured: its answer,
;; 'quick under 50 ms, and 'small under 1 KiB allocated. Folding even one
;; sent tag of 256 characters allocates 48 KiB.
(define (refused-at-once make call)
  (attempt (lambda ()
             (let* ((x (make))
                    (a0 (allocated))
                    (t0 (real-time))
                    (r (call x))
                    (t1 (real-time))
                    (a1 (allocated)))
               (list r
                     (if (< (- t1 t0) 50) 'quick (- t1 t0))
                     (if (< (- a1 a0) 1024) 'small (- a1 a0)))))))

;; make-rng : Natural -> (Natural -> Natural)
;; A xorshift generator from a fixed seed: each call a number below N.
(define (make-rng seed)
  (let ((x seed))
    (lambda (n)
      (set! x (bitwise-and (bitwise-xor x (bitwise-arithmetic-shift-left x 13)) #xFFFFFFFF))
      (set! x (bitwise-xor x (bitwise-arithmetic-shift-right x 17)))
      (set! x (bitwise-and (bitwise-xor x (bitwise-arithmetic-shift-left x 5)) #xFFFFFFFF))
      (mod x n))))

;; scalar? : Natural -> Boolean     a code point Chez can hold: no surrogate
(define (scalar? n) (and (<= 0 n #x10FFFF) (not (<= #xD800 n #xDFFF))))

;; iota : Natural -> (Listof Natural)     0 to N - 1
(define (iota n) (let loop ((i (- n 1)) (acc '())) (if (< i 0) acc (loop (- i 1) (cons i acc)))))

;; make-list* : Natural Any -> (Listof Any)     N of X
(define (make-list* n x) (let loop ((i 0) (acc '())) (if (= i n) acc (loop (+ i 1) (cons x acc)))))

(test-begin "tags")

;;; The caps

(test-equal "caps: 50 a node, 64 folded, 256 sent, 500 a step, 10 a filter"
  '(50 64 256 500 10)
  (attempt (lambda () (list tag-cap tag-length-cap tag-raw-cap tag-step-cap tag-filter-cap))))

;;; The owner's examples (G3) and the plan's answers

(for-each
 (lambda (c)
   (test-equal (string-append "examples: " (car c) ": " (shown (cadr c)) " is " (shown (caddr c)))
     (caddr c)
     (fold (cadr c))))
 (list (list "lower case" "Work" "work")
       (list "full width" (chars #xFF37 #xFF2F #xFF32 #xFF2B) "work")
       (list "kanji unchanged" (chars #x65E5 #x672C) (chars #x65E5 #x672C))
       (list "half-width katakana is full width" (chars #xFF92 #xFF93) (chars #x30E1 #x30E2))
       (list "E and a combining acute" (chars #x45 #x301) (chars #xE9))
       (list "a precomposed capital" (chars #xC9) (chars #xE9))
       (list "a space inside" "Work Space" "work-space")
       (list "spaces at the ends and two inside" " work  space " "work-space")
       (list "a hyphen sent is left" "work-space" "work-space")
       (list "a hyphen between spaces" "work - space" "work---space")
       (list "sharp s stays" "Stra\xDF;e" "stra\xDF;e")
       (list "SS stays" "STRASSE" "strasse")
       (list "hiragana stays" (chars #x3081 #x3082) (chars #x3081 #x3082))
       (list "katakana stays" (chars #x30E1 #x30E2) (chars #x30E1 #x30E2))
       (list "a parenthesised ideograph" (chars #x3231) (chars #x28 #x682A #x29))
       (list "a circled capital" (chars #x24B6) "a")
       (list "U+2010, a hyphen, is - (F5)" (chars #x61 #x2010 #x62) "a-b")
       (list "U+2212, a minus, is - (F5)" (chars #x61 #x2212 #x62) "a-b")
       (list "four of U+FDFA fold to 72 characters" (make-string 4 (integer->char #xFDFA)) 'invalid)))

(test-equal "examples: Stra\xDF;e and STRASSE are two tags, as are hiragana and katakana"
  '(#f #f)
  (attempt (lambda ()
             (list (string=? (normalise-tag "Stra\xDF;e") (normalise-tag "STRASSE"))
                   (string=? (normalise-tag (chars #x3081 #x3082)) (normalise-tag (chars #x30E1 #x30E2)))))))

;;; The corpus: what Chez 10.4.1's tables (Unicode 17.0) decide, each case
;;; folded by the whole rule. Held here so that an upgrade cannot move it
;;; unseen: a tag stored is never folded again (H4).

(define corpus
  '(;; ASCII
    ("Work" . "work") ("WORK" . "work") ("work" . "work") ("a-b" . "a-b") ("a_b" . "a_b")
    ("a/b" . "a/b") ("a%b" . "a%b") ("a&b" . "a&b") ("c++" . "c++") ("C#" . "c#")
    ("#tag" . "#tag") ("@me" . "@me") ("a.b" . "a.b") ("a:b" . "a:b") ("a\"b" . "a\"b")
    ("a\\b" . "a\\b") ("a'b" . "a'b") ("~" . "~") ("0" . "0") ("-" . "-") ("--" . "--")
    ("_" . "_") ("a b" . "a-b") ("a  b" . "a-b") (" a " . "a") ("a - b" . "a---b")
    ;; Latin-1
    ("\xc9;" . "\xe9;") ("\xe9;" . "\xe9;") ("\xd1;" . "\xf1;") ("\xc6;" . "\xe6;")
    ("\xd8;" . "\xf8;") ("\xde;" . "\xfe;") ("\xdf;" . "\xdf;") ("\xff;" . "\xff;")
    ("\x178;" . "\xff;") ("\xb5;" . "\x3bc;") ("\xaa;" . "a") ("\xba;" . "o") ("\xb9;" . "1")
    ("\xb2;" . "2") ("\xbc;" . "1\x2044;4") ("\xbd;" . "1\x2044;2")
    ;; a spacing accent is a space and a combining one: the space is
    ;; trimmed, and a tag may not begin with a mark (F4). Only the first
    ;; character: after an a, the space is a - and the mark is kept
    ("\xa8;" . invalid) ("\xaf;" . invalid) ("\xb4;" . invalid) ("\xb8;" . invalid)
    ("a\xb4;" . "a-\x301;") ("\xa0;a" . "a") ("a\xa0;b" . "a-b")
    ;; Latin Extended, and the digraphs' three cases
    ("\x100;" . "\x101;") ("\x1c4;" . "d\x17e;") ("\x1c5;" . "d\x17e;") ("\x1c6;" . "d\x17e;")
    ("\x1c8;" . "lj") ("\x1cb;" . "nj") ("\x1f1;" . "dz") ("\x1f2;" . "dz")
    ("\x130;" . "i\x307;") ("\x131;" . "\x131;") ("I\x307;" . "i\x307;") ("\x17f;" . "s")
    ("\x1e9e;" . "\xdf;") ("\x1e9b;" . "\x1e61;") ("\x13f;" . "l\xb7;") ("\x149;" . "\x2bc;n")
    ;; a combining mark after a capital: the second NFKC (traps.md)
    ("W\x30a;" . "\x1e98;") ("J\x30c;" . "\x1f0;") ("\x391;\x342;" . "\x1fb6;")
    ("Y\x30a;" . "\x1e99;") ("H\x331;" . "\x1e96;") ("T\x308;" . "\x1e97;")
    ("A\x30a;" . "\xe5;") ("\x399;\x308;\x301;" . "\x390;") ("\x3a5;\x313;" . "\x1f50;")
    ("E\x301;" . "\xe9;") ("e\x301;" . "\xe9;") ("A\x328;\x301;" . "\x105;\x301;")
    ("A\x301;\x328;" . "\x105;\x301;") ("\x130;\x301;" . "i\x307;\x301;")
    ("\x1f88;" . "\x1f80;") ("\x1fbc;" . "\x1fb3;") ("\x345;" . invalid) ("\x390;" . "\x390;")
    ;; Greek: final sigma, and the symbols
    ("\x3a3;\x391;\x3a3;" . "\x3c3;\x3b1;\x3c2;") ("\x3a3;" . "\x3c3;")
    ("\x391;\x3a3;" . "\x3b1;\x3c2;") ("\x391;\x3a3; \x392;\x3a3;" . "\x3b1;\x3c2;-\x3b2;\x3c2;")
    ("\x3a9;" . "\x3c9;") ("\x2126;" . "\x3c9;") ("\x3d0;" . "\x3b2;") ("\x3d5;" . "\x3c6;")
    ("\x3f0;" . "\x3ba;") ("\x3f1;" . "\x3c1;") ("\x3f2;" . "\x3c2;") ("\x3f4;" . "\x3b8;")
    ("\x3f9;" . "\x3c3;")
    ;; Cyrillic, Armenian, Georgian, Cherokee (whose lower case came later)
    ("\x416;" . "\x436;") ("\x401;" . "\x451;") ("\x400;" . "\x450;") ("\x4c1;" . "\x4c2;")
    ("\x531;" . "\x561;") ("\x587;" . "\x565;\x582;") ("\x1c90;" . "\x10d0;")
    ("\x10a0;" . "\x2d00;") ("\x13a0;" . "\xab70;") ("\xab70;" . "\xab70;")
    ("\x13f0;" . "\x13f8;") ("\x13f8;" . "\x13f8;")
    ;; capitals past the BMP: Deseret, Osage, Adlam, Vithkuqi, Garay (16.0),
    ;; Old Hungarian, Warang Citi, Medefaidrin
    ("\x10400;" . "\x10428;") ("\x104b0;" . "\x104d8;") ("\x1e900;" . "\x1e922;")
    ("\x10570;" . "\x10597;") ("\x10d50;" . "\x10d70;") ("\x10c80;" . "\x10cc0;")
    ("\x118a0;" . "\x118c0;") ("\x16e40;" . "\x16e60;")
    ;; letterlike symbols, numbers, enclosed forms, squared words, ligatures
    ("\x212a;" . "k") ("\x212b;" . "\xe5;") ("\x2132;" . "\x214e;") ("\x210c;" . "h")
    ("\x2115;" . "n") ("\x2135;" . "\x5d0;") ("\x2121;" . "tel") ("\x2122;" . "tm")
    ("\x2116;" . "no") ("\x2103;" . "\xb0;c") ("\x216b;" . "xii") ("\x217b;" . "xii")
    ("\x24b6;" . "a") ("\x24d0;" . "a") ("\x2460;" . "1") ("\x2474;" . "(1)") ("\x249c;" . "(a)")
    ("\x3231;" . "(\x682a;)") ("\x337f;" . "\x682a;\x5f0f;\x4f1a;\x793e;") ("\x338f;" . "kg")
    ("\x3392;" . "mhz") ("\x33c2;" . "a.m.") ("\xfb00;" . "ff") ("\xfb01;" . "fi")
    ("\xfb06;" . "st") ("\xfb13;" . "\x574;\x576;")
    ;; full and half width
    ("\xff37;\xff2f;\xff32;\xff2b;" . "work") ("\xff11;\xff12;\xff13;" . "123")
    ("\xff76;\xff9e;" . "\x30ac;") ("\xff8a;\xff9f;" . "\x30d1;") ("\xff92;\xff93;" . "\x30e1;\x30e2;")
    ("\xff70;" . "\x30fc;") ("\xffe5;" . "\xa5;") ("\xffe6;" . "\x20a9;") ("\xff61;" . "\x3002;")
    ("\xffa0;" . invalid) ("\xffa1;" . "\x1100;") ("\x3000;" . invalid) ("a\x3000;b" . "a-b")
    ("\xff03;" . "#") ("\xff0f;" . "/")
    ;; Hangul: jamo compose, compatibility jamo become conjoining ones, a
    ;; filler is invisible
    ("\xac00;" . "\xac00;") ("\x1100;\x1161;" . "\xac00;") ("\x1100;\x1161;\x11a8;" . "\xac01;")
    ("\xac00;\x11a8;" . "\xac01;") ("\x3131;" . "\x1100;") ("\x314f;" . "\x1161;")
    ("\x3131;\x314f;" . "\xac00;") ("\x3164;" . invalid) ("\x115f;" . invalid)
    ("\x1160;" . invalid) ("\x1100;\x1160;" . invalid) ("\x115f;\x1161;" . invalid)
    ;; Japanese
    ("\x3081;\x3082;" . "\x3081;\x3082;") ("\x30e1;\x30e2;" . "\x30e1;\x30e2;")
    ("\x304c;" . "\x304c;") ("\x304b;\x3099;" . "\x304c;") ("\x32ff;" . "\x4ee4;\x548c;")
    ("\x3300;" . "\x30a2;\x30d1;\x30fc;\x30c8;") ("\x65e5;\x672c;" . "\x65e5;\x672c;")
    ;; Arabic: U+FDFA grows 18 times, its spaces become -
    ("\xfdfa;" . "\x635;\x644;\x649;-\x627;\x644;\x644;\x647;-\x639;\x644;\x64a;\x647;-\x648;\x633;\x644;\x645;")
    ("\xfdfa;\xfdfa;\xfdfa;" . "\x635;\x644;\x649;-\x627;\x644;\x644;\x647;-\x639;\x644;\x64a;\x647;-\x648;\x633;\x644;\x645;\x635;\x644;\x649;-\x627;\x644;\x644;\x647;-\x639;\x644;\x64a;\x647;-\x648;\x633;\x644;\x645;\x635;\x644;\x649;-\x627;\x644;\x644;\x647;-\x639;\x644;\x64a;\x647;-\x648;\x633;\x644;\x645;")
    ("\xfdfa;\xfdfa;\xfdfa;\xfdfa;" . invalid) ("\xfefb;" . "\x644;\x627;")
    ("\xfdf2;" . "\x627;\x644;\x644;\x647;") ("\x61c;" . invalid)
    ;; mathematical letters, super- and subscripts
    ("\x1d400;" . "a") ("\x1d538;" . "a") ("\x1d7ce;" . "0") ("\x210e;" . "h")
    ("\x1d6a4;" . "\x131;") ("\x1d6a5;" . "\x237;") ("x\xb2;" . "x2") ("\x207f;" . "n")
    ("\x1d2c;" . "a") ("\x2090;" . "a") ("\x1d43;" . "a")
    ;; hyphens and spaces: every dash is - (F5)
    ("a\x2010;b" . "a-b") ("a\x2011;b" . "a-b") ("a\x2212;b" . "a-b")
    ("a\xfe63;b" . "a-b") ("a\xff0d;b" . "a-b") ("a\x2013;b" . "a-b") ("a\x1680;b" . "a-b")
    ("a\x2000;b" . "a-b") ("a\x200a;b" . "a-b") ("a\x202f;b" . "a-b") ("a\x205f;b" . "a-b")
    ("\x1680;a\x1680;" . "a")
    ;; emoji: a variation selector, a joiner and a tag sequence are invisible
    ("\x2764;" . "\x2764;") ("\x2764;\xfe0f;" . invalid) ("\x1f600;" . "\x1f600;")
    ("\x1f468;\x200d;\x1f469;" . invalid) ("\x1f1ef;\x1f1f5;" . "\x1f1ef;\x1f1f5;")
    ("\x1f44d;\x1f3fd;" . "\x1f44d;\x1f3fd;") ("#\xfe0f;\x20e3;" . invalid) ("#\x20e3;" . "#\x20e3;")
    ("\x1f3f4;\xe0067;\xe0062;\xe0065;\xe006e;\xe0067;\xe007f;" . invalid)
    ;; private use (F6), unassigned (F1) and noncharacters are refused;
    ;; U+30000 is assigned (CJK Extension G)
    ("\xe000;" . invalid) ("\xf0000;" . invalid) ("\x50000;" . invalid)
    ("\x30000;" . "\x30000;") ("\xe0100;" . invalid) ("\xfffe;" . invalid) ("\xfdd0;" . invalid)
    ("\x10ffff;" . invalid) ("\x10fffd;" . invalid) ("\xfffd;" . "\xfffd;") ("\x378;" . invalid)
    ;; controls and line breaks
    ("a\x9;b" . invalid) ("a\xa;b" . invalid) ("a\xd;b" . invalid) ("a\x85;b" . invalid)
    ("a\x2028;b" . invalid) ("a\x2029;b" . invalid) ("a\x7f;b" . invalid) ("a\x0;b" . invalid)
    ("a\x1b;b" . invalid)
    ;; format characters: Default_Ignorable ones refused, and U+FFF9 (F2)
    ("\xfff9;" . invalid) ("\x200b;" . invalid) ("\x2060;" . invalid) ("\x2064;" . invalid)
    ("\x2065;" . invalid) ("\xfeff;a" . invalid) ("a\x34f;" . invalid) ("a\x180e;b" . invalid)
    ("a\xad;b" . invalid) ("a\x200e;b" . invalid) ("a\x202e;b" . invalid)
    ;; F1: unassigned refused, alone and inside; what Unicode 17 assigned
    ;; (U+A7CE, a capital, and U+20C1) taken
    ("a\x378;b" . invalid) ("\x16fe5;" . invalid) ("\x20c2;" . invalid) ("\xa7ce;" . "\xa7cf;")
    ("\x20c1;" . "\x20c1;")
    ;; F2: the other format characters; F3: what looks blank
    ("a\xfff9;b" . invalid) ("a\xfffb;b" . invalid) ("\x13430;" . invalid) ("a\x1343f;" . invalid)
    ("\x2800;" . invalid) ("a\x2800;b" . invalid) ("\x16fe4;" . invalid) ("a\x1d159;" . invalid)
    ;; F4: no tag begins with a mark, as sent or once folded (U+FF9E is
    ;; U+3099); a mark after a letter, a space or a hyphen is kept
    ("\x301;" . invalid) ("\x301;a" . invalid) (" \x301;a" . invalid) ("\x1fed;" . invalid)
    ("\xff9e;" . invalid) ("\x309b;" . invalid) ("a\x309b;" . "a-\x3099;") ("\x903;" . invalid)
    ("\x915;\x903;" . "\x915;\x903;") ("\x20dd;" . invalid) ("a\x20dd;" . "a\x20dd;")
    ("-\x301;" . "-\x301;")
    ;; F5: each dash, and what NFKC makes one, is -; never trimmed, a run
    ;; never one; the wave dash, the long vowel mark, U+2E3A, U+2E3B and
    ;; U+2043 are no dash
    ("a\x2012;b" . "a-b") ("a\x2014;b" . "a-b") ("a\x2015;b" . "a-b") ("a\xfe58;b" . "a-b")
    ("A\x2014;B" . "a-b") ("\x2013;" . "-") ("a\x2013;\x2013;b" . "a--b")
    ("\x2013; a \x2013;" . "--a--") ("\x2212;5" . "-5") ("\xfe31;" . "-") ("\xfe32;" . "-")
    ("a\x2e3a;b" . "a\x2e3a;b") ("a\x2e3b;b" . "a\x2e3b;b") ("a\x2043;b" . "a\x2043;b")
    ("\x301c;" . "\x301c;") ("\x30fc;" . "\x30fc;")
    ;; F6: private use, each area; U+F900 is a CJK ideograph, no private use
    ("a\xf8ff;" . invalid) ("\xffffd;" . invalid) ("\x100000;" . invalid) ("\xf900;" . "\x8c48;")))

(test-equal "corpus: 290 cases, none of them twice"
  '(290 290)
  (attempt (lambda ()
             (list (length corpus)
                   (let loop ((l (list-sort (lambda (a b) (string<? (car a) (car b))) corpus)) (n 0))
                     (cond ((null? l) n)
                           ((and (pair? (cdr l)) (string=? (caar l) (caadr l))) (loop (cdr l) n))
                           (else (loop (cdr l) (+ n 1)))))))))

(for-each
 (lambda (c)
   (test-equal (string-append "corpus: " (lit (car c)) " is " (shown (cdr c)))
     (cdr c)
     (fold (car c))))
 corpus)

;;; The boundaries

(define (spaces n) (make-string n #\space))

(test-equal "raw cap: 256 characters sent are taken, and 257 refused, though both fold to a"
  '("a" invalid)
  (list (fold (string-append "a" (spaces 255))) (fold (string-append "a" (spaces 256)))))

(test-equal "raw cap: counted in characters, not bytes: 64 kanji and 192 spaces taken, and 193 refused"
  (list (make-string 64 (integer->char #x65E5)) 'invalid)
  (list (fold (string-append (make-string 64 (integer->char #x65E5)) (spaces 192)))
        (fold (string-append (make-string 64 (integer->char #x65E5)) (spaces 193)))))

(test-equal "raw cap: 300 of U+FDFA refused before it is folded, with nothing allocated"
  '(invalid quick small)
  (refused-at-once (lambda () (make-string 300 (integer->char #xFDFA))) normalise-tag))

(test-equal "raw cap: 2 MiB of U+FDFA refused at once (folding it takes seconds)"
  '(invalid quick small)
  (refused-at-once (lambda () (make-string 2097152 (integer->char #xFDFA))) normalise-tag))

(test-equal "raw cap: 4 of U+FDFA are under it, so folded and refused for their length, 72; 3 are 54, taken"
  '(invalid 54)
  (attempt (lambda ()
             (list (normalise-tag (make-string 4 (integer->char #xFDFA)))
                   (string-length (normalise-tag (make-string 3 (integer->char #xFDFA))))))))

(test-equal "length: 64 characters folded are taken, 65 refused"
  (list (make-string 64 #\a) 'invalid)
  (list (fold (make-string 64 #\a)) (fold (make-string 65 #\a))))

(test-equal "length: counted on the folded form: 32 of U+FB00 are 64 f, taken; with an a, 65, refused"
  (list (make-string 64 #\f) 'invalid)
  (list (fold (make-string 32 (integer->char #xFB00)))
        (fold (string-append (make-string 32 (integer->char #xFB00)) "a"))))

(test-equal "length: 21 of U+3231 and an a are 64, taken; 22 are 66, refused"
  '(64 invalid)
  (attempt (lambda ()
             (list (string-length (normalise-tag (string-append (make-string 21 (integer->char #x3231)) "a")))
                   (normalise-tag (make-string 22 (integer->char #x3231)))))))

(test-equal "length: a run of spaces counts as its one -: 32 a, 3 spaces, 31 a is 64, taken; 32 after, refused"
  (list (string-append (make-string 32 #\a) "-" (make-string 31 #\a)) 'invalid)
  (list (fold (string-append (make-string 32 #\a) "   " (make-string 31 #\a)))
        (fold (string-append (make-string 32 #\a) "   " (make-string 32 #\a)))))

(test-equal "length: 64 emoji, each one code point of four bytes, taken; 65 refused"
  (list (make-string 64 (integer->char #x1F600)) 'invalid)
  (list (fold (make-string 64 (integer->char #x1F600))) (fold (make-string 65 (integer->char #x1F600)))))

(test-equal "empty: \"\", spaces, U+3000 and a mix of spaces are refused; - alone is a tag"
  '(invalid invalid invalid invalid "-" "-")
  (map fold (list "" "   " (chars #x3000) (chars #x20 #xA0 #x1680 #x2003 #x3000) "-" " - ")))

(test-equal "spaces: each space-char? at either end is trimmed, and inside is one -"
  (map (lambda (n) (list "ab" "a-b" "a-b")) '(#x20 #xA0 #x1680 #x2000 #x2005 #x200A #x202F #x205F #x3000))
  (attempt (lambda ()
             (map (lambda (n)
                    (let ((s (string (integer->char n))))
                      (list (normalise-tag (string-append s s "ab" s))
                            (normalise-tag (string-append "a" s "b"))
                            (normalise-tag (string-append "a" s s (string #\space) s "b")))))
                  '(#x20 #xA0 #x1680 #x2000 #x2005 #x200A #x202F #x205F #x3000)))))

(test-equal "spaces: a hyphen beside a space is left, and the space still becomes one -"
  '("a--b" "a--b" "-a-" "a-" "--a")
  (map fold '("a- b" "a -b" "-a-" " a- " "- a")))

(test-equal "what is no string is refused"
  '(invalid invalid invalid invalid invalid invalid invalid invalid invalid)
  (map fold (list 'null 5 #f #t '() (vector "a") #\a 'work (list "a"))))

;; The plan's controls and line breaks: at the start, the end and inside;
;; a tab or a line break is no space, so it is never trimmed (H2).
(for-each
 (lambda (n)
   (test-equal (string-append "controls: U+" (number->string n 16) " refused at the start, the end and inside")
     '(invalid invalid invalid invalid)
     (map fold (list (chars n #x61) (chars #x61 n) (chars #x61 n #x62) (chars n)))))
 '(#x9 #xA #xD #x85 #x2028 #x2029 #x0 #x1F #x7F #x9F))

;; Each range of invisible-char?: its two ends after an a are refused; the
;; code point just outside each end is taken, as Chez folds it, but for
;; those another rule refuses (U+2029, a separator; U+FEFE, U+FF00,
;; U+FFEF, U+16FE5, U+1BCA4 and U+E1000, unassigned). U+2010 is a dash, so
;; a hyphen.
(define invisible-bounds
  ;; (from to before-folded after-folded)
  (list (list #xAD #xAD (chars #x61 #xAC) (chars #x61 #xAE))
        (list #x34F #x34F (chars #x61 #x34E) (chars #x61 #x350))
        (list #x61C #x61C (chars #x61 #x61B) (chars #x61 #x61D))
        (list #x115F #x1160 (chars #x61 #x115E) (chars #x61 #x1161))
        (list #x17B4 #x17B5 (chars #x61 #x17B3) (chars #x61 #x17B6))
        (list #x180B #x180F (chars #x61 #x180A) (chars #x61 #x1810))
        (list #x200B #x200F "a" "a-")
        (list #x202A #x202E 'invalid "a")
        (list #x2060 #x206F "a" "a0")
        (list #x3164 #x3164 (chars #x61 #x1175) (chars #x61 #x1114))
        (list #xFE00 #xFE0F (chars #x61 #xFDFF) "a,")
        (list #xFEFF #xFEFF 'invalid 'invalid)
        (list #xFFA0 #xFFA0 (chars #x61 #x309A) (chars #x61 #x1100))
        (list #xFFF0 #xFFFB 'invalid (chars #x61 #xFFFC))
        (list #x1BCA0 #x1BCA3 (chars #x61 #x1BC9F) 'invalid)
        (list #x1D173 #x1D17A (chars #x61 #x1D172) (chars #x61 #x1D17B))
        (list #xE0000 #xE0FFF 'invalid 'invalid)
        (list #x13430 #x1343F (chars #x61 #x1342F) (chars #x61 #x13440))
        (list #x2800 #x2800 (chars #x61 #x27FF) (chars #x61 #x2801))
        (list #x16FE4 #x16FE4 (chars #x61 #x16FE3) 'invalid)
        (list #x1D159 #x1D159 (chars #x61 #x1D158) (chars #x61 #x1D15A))))

(for-each
 (lambda (b)
   (let ((from (car b)) (to (cadr b)))
     (test-equal (string-append "invisible: U+" (number->string from 16) " and U+" (number->string to 16)
                                " refused; U+" (number->string (- from 1) 16) " and U+"
                                (number->string (+ to 1) 16) " are no invisible character")
       (list 'invalid 'invalid (caddr b) (cadddr b))
       (map fold (list (chars #x61 from) (chars #x61 to) (chars #x61 (- from 1)) (chars #x61 (+ to 1)))))))
 invisible-bounds)

(test-equal "invisible: every one of the 4,196, after an a, refused"
  '(4196 0)
  (attempt
   (lambda ()
     (let loop ((n 0) (refused 0) (taken 0))
       (cond ((> n #x10FFFF) (list refused taken))
             ((not (scalar? n)) (loop (+ n 1) refused taken))
             ((invisible-char? (integer->char n))
              (if (eq? (normalise-tag (chars #x61 n)) 'invalid)
                  (loop (+ n 1) (+ refused 1) taken)
                  (loop (+ n 1) refused (+ taken 1))))
             (else (loop (+ n 1) refused taken)))))))

;; private-use-char? and dash-char?, each range: (from to before-folded
;; after-folded), the ends after an a, then the points just outside. Most
;; of private use's neighbours another rule refuses: U+D7FF is unassigned,
;; U+EFFFF, U+FFFFE, U+FFFFF and U+10FFFE are noncharacters; U+F900 folds
;; to the ideograph U+8C48. Beside the dashes, U+200F is invisible.
(define private-use-bounds
  (list (list #xE000 #xF8FF 'invalid (chars #x61 #x8C48))
        (list #xF0000 #xFFFFD 'invalid 'invalid)
        (list #x100000 #x10FFFD 'invalid 'invalid)))

(for-each
 (lambda (b)
   (let ((from (car b)) (to (cadr b)))
     (test-equal (string-append "private use: U+" (number->string from 16) " and U+" (number->string to 16)
                                " refused, after an a; and the scalar values just outside")
       (list 'invalid 'invalid (caddr b) (cadddr b))
       (map fold (list (chars #x61 from) (chars #x61 to)
                       (chars #x61 (if (= from #xE000) #xD7FF (- from 1))) (chars #x61 (+ to 1)))))))
 private-use-bounds)

(test-equal "dashes: U+2010 to U+2015 and U+2212, inside, at the ends and alone, are -; U+200F, U+2016, U+2211, U+2213 beside them are not"
  (list (make-list* 7 '("a-b" "-a-" "-"))
        (list 'invalid (chars #x61 #x2016 #x62) (chars #x61 #x2211 #x62) (chars #x61 #x2213 #x62)))
  (attempt
   (lambda ()
     (list (map (lambda (n)
                  (map normalise-tag (list (chars #x61 n #x62) (chars n #x61 n) (chars n))))
                '(#x2010 #x2011 #x2012 #x2013 #x2014 #x2015 #x2212))
           (map (lambda (n) (normalise-tag (chars #x61 n #x62))) '(#x200F #x2016 #x2211 #x2213))))))

(test-equal "dashes: a dash is no space: a run of them is not one, and spaces beside them each still become one -"
  '("a---b" "a--b" "a---b" "--")
  (map fold (list (chars #x61 #x2013 #x2014 #x2212 #x62) (chars #x61 #x2010 #x2D #x62)
                  (chars #x61 #x20 #x2013 #x20 #x62) (chars #x20 #x2013 #x2014 #x20))))

;; F1: read as sent, before anything is folded.
(test-equal "unassigned: 255 of U+FDFA and then U+0378 are refused before they are folded, with nothing allocated (folding them allocates 48 KiB)"
  '(invalid quick small)
  (refused-at-once (lambda () (string-append (make-string 255 (integer->char #xFDFA)) (chars #x378)))
                   normalise-tag))

(test-equal "unassigned: refused alone, first, last and inside; what Unicode 17 assigned is taken"
  (list 'invalid 'invalid 'invalid 'invalid (chars #xA7CF) (chars #x61 #x20C1))
  (map fold (list (chars #x378) (chars #x378 #x61) (chars #x61 #x378) (chars #x61 #x378 #x62)
                  (chars #xA7CE) (chars #x61 #x20C1))))

;; F4: what the stored form begins with; nothing after its first.
(test-equal "marks: U+0301 alone, a spacing accent, a mark after a space refused; e and U+0301 is U+00E9; a mark after a letter or a hyphen is kept"
  (list 'invalid 'invalid 'invalid (chars #xE9) (chars #x61 #x2D #x301 #x62) (chars #x2D #x301))
  (map fold (list (chars #x301) (chars #xB4) (chars #x20 #x301 #x61) (chars #x65 #x301)
                  (chars #x61 #xB4 #x62) (chars #x2D #x301))))

(test-equal "marks: each of the 2,543 marks alone refused; after an a, all but the 264 that are invisible taken"
  '(2543 0 2279 264)
  (attempt
   (lambda ()
     (let loop ((n 0) (alone-refused 0) (alone-taken 0) (after-taken 0) (after-refused 0))
       (cond ((> n #x10FFFF) (list alone-refused alone-taken after-taken after-refused))
             ((not (scalar? n)) (loop (+ n 1) alone-refused alone-taken after-taken after-refused))
             ((mark-char? (integer->char n))
              (let ((alone (eq? (normalise-tag (chars n)) 'invalid))
                    (after (eq? (normalise-tag (chars #x61 n)) 'invalid)))
                (loop (+ n 1) (if alone (+ alone-refused 1) alone-refused) (if alone alone-taken (+ alone-taken 1))
                      (if after after-taken (+ after-taken 1)) (if after (+ after-refused 1) after-refused))))
             (else (loop (+ n 1) alone-refused alone-taken after-taken after-refused)))))))

(test-equal "marks: the marks refused after an a are exactly the invisible ones"
  '()
  (attempt
   (lambda ()
     (let loop ((n 0) (acc '()))
       (cond ((> n #x10FFFF) (reverse acc))
             ((or (not (scalar? n)) (not (mark-char? (integer->char n)))) (loop (+ n 1) acc))
             ((eq? (eq? (normalise-tag (chars #x61 n)) 'invalid) (invisible-char? (integer->char n))) (loop (+ n 1) acc))
             (else (loop (+ n 1) (if (< (length acc) 10) (cons (number->string n 16) acc) acc))))))))

(test-equal "emoji: a heart with U+FE0F refused, and without it taken; one joined by U+200D refused"
  (list 'invalid (chars #x2764) 'invalid (chars #x1F468 #x1F469))
  (map fold (list (chars #x2764 #xFE0F) (chars #x2764) (chars #x1F468 #x200D #x1F469) (chars #x1F468 #x1F469))))

;;; The laws: L1 and the stored form

;; stored-form? : String -> Boolean
;; What every tag normalise-tag answers must be: 1 to 64 characters, the
;; first no mark; no space-char?, dash-char?, control, invisible, private
;; use or unassigned character; unchanged by downcase and by NFKC; and L1,
;; folded again it is itself.
(define (stored-form? t)
  (and (string? t)
       (<= 1 (string-length t) 64)
       (not (mark-char? (string-ref t 0)))
       (for-all (lambda (c) (and (allowed-char? c #f) (not (space-char? c)) (not (invisible-char? c))
                                 (not (dash-char? c)) (not (private-use-char? c)) (not (unassigned-char? c))))
                (string->list t))
       (string=? (string-downcase t) t)
       (string=? (string-normalize-nfkc t) t)
       (equal? (normalise-tag t) t)))

;; sweep : (Natural -> (U String #f)) Natural -> (List Natural Natural (U 'ok (List 'broke String String)))
;; MAKE's strings for 0 to N - 1 (#f to skip one), each folded: how many
;; were taken and refused, and the first whose tag is no stored form.
(define (sweep make n)
  (attempt
   (lambda ()
     (let loop ((i 0) (taken 0) (refused 0))
       (if (= i n)
           (list taken refused 'ok)
           (let ((s (make i)))
             (if (not s)
                 (loop (+ i 1) taken refused)
                 (let ((t (normalise-tag s)))
                   (cond ((eq? t 'invalid) (loop (+ i 1) taken (+ refused 1)))
                         ((stored-form? t) (loop (+ i 1) (+ taken 1) refused))
                         (else (list taken refused (list 'broke (lit s) (shown t)))))))))))))

;; at-least : (List Natural Natural Any) Natural -> Any
;; The sweep's verdict, 'ok, when it took at least MIN; else what it found.
(define (at-least r min)
  (if (and (pair? r) (number? (car r)) (>= (car r) min) (eq? (caddr r) 'ok)) 'ok r))

;; Alone, a scalar value is refused by a rule said of it (listed?), or
;; because what it folds to begins with a mark (mark-first?): a mark, or
;; what NFKC makes a mark first, or a space and a mark (a spacing accent,
;; whose space is trimmed).
(define (listed? c)
  (or (not (allowed-char? c #f)) (invisible-char? c) (space-char? c) (unassigned-char? c)
      (private-use-char? c)))

(define (mark-first? c)
  (let ((s (string-normalize-nfkc (string c))))
    (or (mark-char? (string-ref s 0))
        (and (char=? (string-ref s 0) #\space) (> (string-length s) 1) (mark-char? (string-ref s 1))))))

(test-equal "L1: every scalar value alone, folded, is a stored form; 955,042 refused"
  '(157022 955042 ok)
  (sweep (lambda (n) (and (scalar? n) (string (integer->char n)))) #x110000))

;; The 2,333 are the 2,279 marks no rule lists, and 54 others: the
;; spacing accents (U+00B4, U+02D8, U+1FED, U+309B, U+FE70 and their
;; kind), U+0E33 and U+0EB3 (whose NFKC begins with a mark), U+FF9E and
;; U+FF9F (half-width sound marks, which NFKC makes U+3099 and U+309A).
(test-equal "alone: refused exactly when a rule's list or table says so of it (952,709), or it folds to a mark first (2,333)"
  '(() 952709 2333)
  (attempt
   (lambda ()
     (let loop ((n 0) (wrong '()) (listed 0) (marked 0))
       (cond ((> n #x10FFFF) (list (reverse wrong) listed marked))
             ((not (scalar? n)) (loop (+ n 1) wrong listed marked))
             (else
              (let* ((c (integer->char n))
                     (l (listed? c))
                     (m (and (not l) (mark-first? c)))
                     (refused (eq? (normalise-tag (string c)) 'invalid)))
                (loop (+ n 1)
                      (if (and (eq? refused (or l m)) #t) wrong
                          (if (< (length wrong) 10) (cons (number->string n 16) wrong) wrong))
                      (if l (+ listed 1) listed)
                      (if m (+ marked 1) marked)))))))))

;; Every character Chez lowercases, in the BMP and the SMP, and the
;; combining marks most likely to compose with one (but U+034F, which is
;; invisible).
(define capitals
  (let loop ((n #x1FFFF) (acc '()))
    (cond ((< n 0) acc)
          ((and (scalar? n)
                (let ((s (string (integer->char n)))) (not (string=? (string-downcase s) s))))
           (loop (- n 1) (cons (integer->char n) acc)))
          (else (loop (- n 1) acc)))))

(define (range-chars from to)
  (let loop ((n to) (acc '())) (if (< n from) acc (loop (- n 1) (cons (integer->char n) acc)))))

(define marks
  (filter
   (lambda (c) (not (char=? c (integer->char #x34F))))
   (append (range-chars #x300 #x36F) (range-chars #x483 #x489) (range-chars #x591 #x5BD)
           (range-chars #x1AB0 #x1ACE) (range-chars #x1DC0 #x1DFF) (range-chars #x20D0 #x20F0)
           (range-chars #xFE20 #xFE2F) (list (integer->char #x3099) (integer->char #x309A)))))

(test-equal "L1: the capitals and marks are many: over 1,400 capitals, over 300 marks"
  '(#t #t)
  (attempt (lambda () (list (> (length capitals) 1400) (> (length marks) 300)))))

(test-equal "L1: each capital before each mark, and before two, folded, is a stored form"
  'ok
  (let ((cv (list->vector capitals)) (mv (list->vector marks)))
    (let ((nc (vector-length cv)) (nm (vector-length mv)))
      (at-least
       (sweep (lambda (i)
                (let ((c (vector-ref cv (div i nm))) (m (vector-ref mv (mod i nm))))
                  (if (= 0 (mod i 7))
                      (string c m (vector-ref mv (mod (* i 31) nm)))
                      (string c m))))
              (* nc nm))
       (* nc nm)))))

;; The pool generated strings draw from most: what the review names (final
;; sigma, sharp s, dotted I, the Kelvin sign, combining marks after
;; capitals, Hangul jamo, half and full width forms) and what the rule
;; treats apart (spaces, hyphens, the invisible, U+FDFA).
(define pool
  (list->vector
   (append (map integer->char
                '(#x3A3 #x3C3 #x3C2 #xDF #x1E9E #x130 #x131 #x69 #x49 #x212A #x212B #x2126 #x57 #x4A
                  #x391 #x399 #x3A5 #x59 #x48 #x54 #x41 #x45 #x307 #x30A #x30C #x342 #x345 #x301
                  #x308 #x331 #x313 #x3F4 #x3F9 #x3F2 #x1C5 #x1C8 #x1CB #x1F2 #xFDFA #x2D #x5F
                  #x2010 #x2212 #xFE63 #xFF0D #x20 #xA0 #x1680 #x2000 #x200A #x202F #x205F #x3000
                  #xAD #x200B #x200D #xFE0F #x2060 #x3164 #xFFA0 #x115F #x1160 #x3099 #x309A
                  #xFB00 #xFB01 #xFB06 #x3231 #x24B6 #x1D2C #x2764 #x1F468 #x10400 #x1E900
                  ;; the owner's rulings: dashes and their neighbours (F5),
                  ;; the format and blank-looking (F2, F3), private use (F6),
                  ;; unassigned and newly assigned (F1), what folds to a
                  ;; mark first (F4)
                  #x2011 #x2012 #x2013 #x2014 #x2015 #xFE58 #xFE31 #xFE32 #x2E3A #x2E3B #x2043
                  #x301C #x30FC #xFFF9 #xFFFB #x13430 #x1343F #x2800 #x16FE4 #x1D159 #xE000
                  #xF8FF #xF0000 #x10FFFD #x378 #x16FE5 #x20C2 #xA7CE #x20C1 #xB4 #xA8 #x309B
                  #xFF9E #x903 #x20DD #x1FED))
           (range-chars #x1100 #x1112) (range-chars #x1161 #x1175) (range-chars #x11A8 #x11C2)
           (range-chars #x3131 #x318E) (range-chars #xFF01 #xFF5E) (range-chars #xFF61 #xFFDC)
           (range-chars #x300 #x36F) (range-chars #x391 #x3A9) (range-chars #x1F00 #x1FFC)
           (range-chars #x3041 #x3096) (range-chars #x30A1 #x30FA))))

;; random-string : (Natural -> Natural) -> String
;; 1 to 12 characters (one string in 20 up to 80): from the pool, three in
;; five; any BMP scalar value, one in five; and one in five from a plane
;; chosen first, so every plane is reached.
(define (random-string next)
  (let ((len (if (= 0 (next 20)) (+ 1 (next 80)) (+ 1 (next 12)))))
    (let loop ((i 0) (acc '()))
      (if (= i len)
          (list->string acc)
          (let ((pick (next 5)))
            (let ((c (cond ((< pick 3) (vector-ref pool (next (vector-length pool))))
                           ((= pick 3) (let ((n (next #x10000))) (and (scalar? n) (integer->char n))))
                           (else (let ((n (+ (* (next 17) #x10000) (next #x10000))))
                                   (and (scalar? n) (integer->char n)))))))
              (loop (+ i 1) (if c (cons c acc) acc))))))))

;; One character in five comes from any plane, and most of them are
;; unassigned (F1): 68,399 of the 300,000 are taken.
(test-equal "L1: 300,000 generated strings, folded, are stored forms; 60,000 or more taken (seed 20261127)"
  'ok
  (let ((next (make-rng 20261127)))
    (at-least (sweep (lambda (i) (random-string next)) 300000) 60000)))

(test-equal "L1: the generated strings reach every plane"
  '(0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16)
  (attempt
   (lambda ()
     (let ((next (make-rng 20261127)) (seen (make-vector 17 #f)))
       (let loop ((i 0))
         (when (< i 300000)
           (string-for-each (lambda (c) (vector-set! seen (div (char->integer c) #x10000) #t))
                            (random-string next))
           (loop (+ i 1))))
       (let loop ((p 16) (acc '()))
         (if (< p 0) acc (loop (- p 1) (if (vector-ref seen p) (cons p acc) acc))))))))

;;; request-tags

;; content : (U Any 'none) -> Alist     a create's or a replace's object, with TAGS unless 'none
(define (content tags)
  (append '(("title" . "t") ("body" . "b") ("content_type" . "text/plain"))
          (if (eq? tags 'none) '() (list (cons "tags" tags)))))

(define (requested tags create?) (attempt (lambda () (request-tags (content tags) create?))))

(test-equal "request: no tags is none on a create, and absent on a replace (G2)"
  '(() absent)
  (list (requested 'none #t) (requested 'none #f)))

(test-equal "request: [] is none, on a create and on a replace, which it clears"
  '(() ())
  (list (requested (vector) #t) (requested (vector) #f)))

(test-equal "request: [\"a\",\"A\"] is one tag; [\"Work\",\"work\"] is work"
  '(("a") ("work"))
  (list (requested (vector "a" "A") #t) (requested (vector "Work" "work") #f)))

(test-equal "request: the stored forms, sorted by code point, no two the same"
  (list (list "-" "a" "z" "\xE9;" (chars #x65E5 #x672C)) (list "a" "b") (list (chars #xFFFD) (chars #x1F600)))
  (list (requested (vector (chars #x65E5 #x672C) "\xC9;" "z" "-" "A" "Z" "a") #t)
        (requested (vector "b" "a" "B" "A" "b") #t)
        (requested (vector (chars #x1F600) (chars #xFFFD)) #t)))

(define (numbered n) (list->vector (map (lambda (i) (string-append "t" (number->string i))) (iota n))))

(test-equal "request: 50 entries taken, 51 refused"
  '(50 invalid)
  (attempt (lambda ()
             (list (length (request-tags (content (numbered 50)) #t))
                   (request-tags (content (numbered 51)) #t)))))

(test-equal "request: counted as sent: 51 entries that fold to one are refused; 50 are one tag"
  '(invalid ("a"))
  (list (requested (make-vector 51 "A") #t) (requested (make-vector 50 "A") #t)))

(test-equal "request: 100,000 entries refused before any is read"
  '(invalid quick small)
  (refused-at-once (lambda () (content (make-vector 100000 (string-append "a" (spaces 255)))))
                   (lambda (x) (request-tags x #t))))

(test-equal "request: every entry is read: a refused one last of 50 refuses them all"
  'invalid
  (requested (vector-map (lambda (t) (if (string=? t "t49") (chars #x61 #x9) t)) (numbered 50)) #t))

(for-each
 (lambda (c)
   (test-equal (string-append "request: refused, " (car c))
     '(invalid invalid)
     (list (requested (cadr c) #t) (requested (cadr c) #f))))
 (list (list "null" 'null) (list "a string" "work") (list "an empty object" '())
       (list "an object" '(("a" . 1))) (list "a number" 5) (list "true" #t) (list "false" #f)
       (list "a number in the list" (vector "a" 5)) (list "null in the list" (vector 'null))
       (list "an empty string" (vector "")) (list "spaces" (vector "   "))
       (list "an array in the list" (vector (vector "a"))) (list "an object in the list" (vector '()))
       (list "a tag over 64" (vector (make-string 65 #\a)))
       (list "a tag over 256 sent" (vector (string-append "a" (spaces 256))))
       (list "a tab" (vector "a\tb")) (list "U+FE0F" (vector (chars #x2764 #xFE0F)))
       (list "private use" (vector "a" (chars #xE000))) (list "unassigned" (vector (chars #x378) "a"))
       (list "a mark first" (vector (chars #x301)))))

(test-equal "request: what is no object of at most seven members, no name twice, is refused"
  '(invalid invalid invalid invalid invalid invalid invalid invalid)
  (map (lambda (args) (attempt (lambda () (apply request-tags args))))
       (list (list "tags" #t) (list (vector (content (vector "a"))) #t) (list 5 #f)
             (list (cons '("tags" . #("a")) 5) #t)
             (list (append (content (vector "a")) '(("tags" . #("b")))) #t)
             (list (cons '(tags . #("a")) (content 'none)) #t)
             (list (append (content (vector "a")) '(("kind" . "note") ("props") ("parent" . null) ("x" . 1)))
                   #t)
             (list (content (vector "a")) 'yes))))

(test-equal "request: a create's seven members and a replace's six are taken"
  '(("a") ("a"))
  (list (attempt (lambda ()
                   (request-tags (append '(("kind" . "note")) (content (vector "A")) '(("props") ("parent" . null)))
                                 #t)))
        (attempt (lambda () (request-tags (append '(("kind" . "note")) (content (vector "A")) '(("props"))) #f)))))

;;; filter-tags

(define (filtered x) (attempt (lambda () (filter-tags x))))
(define (sent n) (vector->list (numbered n)))

(test-equal "filter: none is ()"
  '()
  (filtered '()))

(test-equal "filter: 10 values taken, 11 refused, counted as sent"
  '(10 invalid invalid ("a"))
  (attempt (lambda ()
             (list (length (filter-tags (sent 10))) (filter-tags (sent 11))
                   (filter-tags (make-list* 11 "A")) (filter-tags (make-list* 10 "A"))))))

(test-equal "filter: each folded as a stored tag, sorted, no two the same"
  '(("work") ("a-b") ("c") ("a" "b"))
  (map filtered '(("Work" "work") ("a b") ("c  ") ("b" "A" "a"))))

(test-equal "filter: refused, an empty value, spaces, a value the rule refuses, what is no list of strings"
  '(invalid invalid invalid invalid invalid invalid invalid invalid)
  (map filtered (list '("") '("a" "   ") (list (chars #x61 #x200B)) "a" '(a) '("a" . "b") (vector "a") 'null)))

(test-equal "filter: 100,000 values refused before any is read"
  '(invalid quick small)
  (refused-at-once (lambda () (make-list* 100000 (string-append "a" (spaces 255)))) filter-tags))

;;; The commands' bodies

(define (renamed x) (attempt (lambda () (parse-rename-body x))))
(define (removed x) (attempt (lambda () (parse-remove-body x))))

(test-equal "rename: from and to, folded, in either order"
  '(("work" . "play") ("work" . "play") ("a-b" . "c"))
  (map renamed '((("from" . "Work") ("to" . "Play")) (("to" . "PLAY") ("from" . "work"))
                 (("from" . " a b ") ("to" . "C")))))

(for-each
 (lambda (c)
   (test-equal (string-append "rename: refused, " (car c))
     'invalid
     (renamed (cadr c))))
 (list (list "an extra member" '(("from" . "a") ("to" . "b") ("x" . 1)))
       (list "no to" '(("from" . "a"))) (list "no from" '(("to" . "b")))
       (list "another member for to" '(("from" . "a") ("To" . "b")))
       (list "from twice" '(("from" . "a") ("from" . "b"))) (list "{}" '())
       (list "from equal to to" '(("from" . "a") ("to" . "a")))
       (list "from equal to to once folded" '(("from" . "Work") ("to" . " WORK ")))
       (list "a from the rule refuses" (list (cons "from" "") (cons "to" "b")))
       (list "a to the rule refuses" (list (cons "from" "a") (cons "to" (make-string 65 #\b))))
       (list "a to that is no string" '(("from" . "a") ("to" . null)))
       (list "a from that is a list" (list (cons "from" (vector "a")) (cons "to" "b")))
       (list "an array" (vector '(("from" . "a") ("to" . "b")))) (list "a string" "a")
       (list "null" 'null) (list "a number" 5) (list "an improper list" (cons '("from" . "a") '("to" . "b")))))

(test-equal "remove: the tag, folded"
  '("work" "a-b")
  (map removed '((("tag" . "Work")) (("tag" . "a b")))))

(for-each
 (lambda (c)
   (test-equal (string-append "remove: refused, " (car c))
     'invalid
     (removed (cadr c))))
 (list (list "an extra member" '(("tag" . "a") ("x" . 1))) (list "{}" '())
       (list "another member" '(("from" . "a"))) (list "Tag, another case" '(("Tag" . "a")))
       (list "tag twice" '(("tag" . "a") ("tag" . "a"))) (list "a tag the rule refuses" '(("tag" . "")))
       (list "tag null" '(("tag" . null))) (list "an array" (vector "a")) (list "a string" "a")
       (list "a number" 5) (list "an improper list" (cons '("tag" . "a") 5))))

;;; The snapshot's text

(test-equal "json: none is [], and tags are an array, as the JSON writer writes it"
  (list "[]" "[\"a\",\"b\"]" (string-append "[\"\x65E5;\x672C;\",\"q\\\"b\",\"s\\\\l\",\"a/b\"]"))
  (attempt (lambda ()
             (list (tags->json '()) (tags->json '("a" "b"))
                   (tags->json (list (chars #x65E5 #x672C) "q\"b" "s\\l" "a/b"))))))

(test-equal "json: tags->json is json->string's text of the array, and json->tags reads it back, over generated tags"
  'ok
  (attempt
   (lambda ()
     (let ((next (make-rng 7)))
       (let loop ((i 0) (count 0))
         (if (= i 2000)
             (if (> count 10000) 'ok (list 'too-few-tags count))
             (let* ((kept (filter string? (map (lambda (k) (normalise-tag (random-string next)))
                                               (iota (next 51)))))
                    (tags (request-tags (content (list->vector kept)) #t))
                    (text (tags->json tags)))
               (if (and (string=? text (json->string (list->vector tags))) (equal? (json->tags text) tags))
                   (loop (+ i 1) (+ count (length tags)))
                   (list 'broke (map lit tags))))))))))

(test-equal "json: json->tags takes the tags as stored: never folded, sorted or made distinct again"
  '(() ("Work" "a" "a" " b "))
  (attempt (lambda () (list (json->tags "[]") (json->tags "[\"Work\",\"a\",\"a\",\" b \"]")))))

(test-equal "json: tags->json raises, with no irritant, for what is no list of strings"
  (make-list* 6 '(tags->json "tags are a list of strings" ()))
  (map (lambda (x) (raised-as (lambda () (tags->json x))))
       (list 'null "a" (list 5) (cons "a" "b") (vector "a") (list "a" 'b))))

(test-equal "json: json->tags raises, with no irritant, for what is no JSON array of strings"
  (make-list* 11 '(json->tags "stored tags are not a JSON array of strings" ()))
  (map (lambda (x) (raised-as (lambda () (json->tags x))))
       (list "{}" "\"secret\"" "[1]" "[\"secret\"" "" "null" "[\"a\"] x" "[[\"a\"]]" 5 #f '("a"))))

(test-equal "json: a sentinel: what is right raises nothing"
  '(no-raise no-raise)
  (list (raised-as (lambda () (tags->json '("a")))) (raised-as (lambda () (json->tags "[\"a\"]")))))

;;; The rules: nothing but the two raises; no raise carries a tag

;; fuzz : (Natural -> Natural) Natural -> Any     a value as the JSON reader makes one, or worse
(define (fuzz next depth)
  (case (next (if (> depth 0) 12 9))
    ((0) 'null) ((1) #t) ((2) #f) ((3) (- (next 2000) 1000)) ((4) 1.5)
    ((5) (random-string next)) ((6) (vector-ref (vector "" "   " "Work" "a b" (make-string 300 #\a)) (next 5)))
    ((7) (vector-ref (vector 'tags "tags" #\a 'invalid) (next 4)))
    ((8) (cons (random-string next) 5))
    ((9) (list->vector (map (lambda (i) (fuzz next (- depth 1))) (iota (next 6)))))
    ((10) (map (lambda (i) (cons (vector-ref (vector "tags" "from" "to" "tag" "x" "") (next 6))
                                 (fuzz next (- depth 1))))
               (iota (next 5))))
    (else (map (lambda (i) (fuzz next (- depth 1))) (iota (next 4))))))

(test-equal "rules: normalise-tag, request-tags, filter-tags and the bodies never raise, over 20,000 values"
  'ok
  (let ((next (make-rng 314159)))
    (let loop ((i 0))
      (if (= i 20000)
          'ok
          (let* ((x (fuzz next 3))
                 (create? (vector-ref (vector #t #f 'yes) (next 3)))
                 (r (guard (e (#t (list 'raised (describe e))))
                      (list (normalise-tag x) (request-tags x create?) (request-tags (content x) create?)
                            (filter-tags x) (parse-rename-body x) (parse-remove-body x)))))
            (if (and (pair? r) (eq? (car r) 'raised))
                (list 'raised (written x) r)
                (loop (+ i 1))))))))

(test-equal "names: no export is a name (rnrs) or (chezscheme) exports"
  '()
  (attempt (lambda ()
             (let ((taken (append (library-exports '(rnrs)) (library-exports '(chezscheme)))))
               (filter (lambda (name) (memq name taken)) (library-exports '(techo tags)))))))

(test-equal "names: exactly the pinned interface"
  '(filter-tags json->tags normalise-tag parse-remove-body parse-rename-body request-tags
    tag-cap tag-filter-cap tag-length-cap tag-raw-cap tag-step-cap tags->json)
  (attempt (lambda ()
             (list-sort (lambda (a b) (string<? (symbol->string a) (symbol->string b)))
                        (library-exports '(techo tags))))))

(test-end "tags")

(exit (suite-exit-status runner))
