#!r6rs
;;; (techo chars): the character rules a Contact's strings and a tag share
;;; (slice 7a). Pure.
;;;
;;; Each rule is a written list of code points, so that none can move with
;;; Chez's Unicode tables: a rule once shipped is never widened or
;;; tightened (slice 6's P3). allowed-char? and blank-char? are slice 6's,
;;; moved here from (techo contact) unchanged; space-char? and
;;; invisible-char? are the owner's H2 and H3 for a tag, invisible-char?
;;; widened by F2 and F3; private-use-char? (F6) and dash-char? (F5) are a
;;; tag's too.
;;;
;;; Two rules are Chez's tables on purpose, and only these two:
;;; unassigned-char? (F1) and mark-char? (F4). Unicode never unassigns a
;;; code point, so an upgrade of Chez can only make unassigned-char? false
;;; of more: a tag refused today may be taken later, and a tag taken holds
;;; only characters already assigned, which Unicode promises to normalise
;;; the same in every later version. A mark an upgrade assigns was
;;; unassigned before, so already refused.
;;; tests/test-chars.sps pins how many code points each answers true of.
(library (techo chars)
  (export allowed-char? blank-char? space-char? invisible-char?
          private-use-char? unassigned-char? mark-char? dash-char?)
  (import (rnrs))

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
  ;; U+200B to U+200D, U+2060 and U+FEFF. A Contact's rule: never widened.
  (define (blank-char? c)
    (let ((n (char->integer c)))
      (or (= n #x20) (= n #xA) (= n #xA0) (= n #x1680)
          (<= #x2000 n #x200D)
          (<= #x2028 n #x2029)
          (= n #x202F) (= n #x205F) (= n #x2060) (= n #x3000) (= n #xFEFF))))

  ;; space-char? : Char -> Boolean
  ;; What a tag trims from its ends, and turns to `-` inside (H2): U+0020,
  ;; U+00A0, U+1680, U+2000 to U+200A, U+202F, U+205F and U+3000. Unicode's
  ;; White_Space less every control and line break: a tab, a line feed,
  ;; U+0085, U+2028 and U+2029 are no space here. After NFKC only U+0020
  ;; and U+1680 of these can be left.
  (define (space-char? c)
    (let ((n (char->integer c)))
      (or (= n #x20) (= n #xA0) (= n #x1680)
          (<= #x2000 n #x200A)
          (= n #x202F) (= n #x205F) (= n #x3000))))

  ;; invisible-char? : Char -> Boolean
  ;; What a tag may not hold, 4,196 code points, written out:
  ;; - Unicode 17's Default_Ignorable_Code_Point (H3), 4,174: U+00AD,
  ;;   U+034F, U+061C, U+115F, U+1160, U+17B4, U+17B5, U+180B to U+180F,
  ;;   U+200B to U+200F, U+202A to U+202E, U+2060 to U+206F, U+3164,
  ;;   U+FE00 to U+FE0F, U+FEFF, U+FFA0, U+FFF0 to U+FFF8, U+1BCA0 to
  ;;   U+1BCA3, U+1D173 to U+1D17A, U+E0000 to U+E0FFF. So a variation
  ;;   selector, a joiner and a direction mark among them.
  ;; - 19 format characters that are none of those (F2): the interlinear
  ;;   annotation marks U+FFF9 to U+FFFB, and the Egyptian hieroglyph
  ;;   format controls U+13430 to U+1343F.
  ;; - 3 that look blank (F3): U+2800 (the blank Braille pattern), U+16FE4
  ;;   (the Khitan filler) and U+1D159 (the null notehead).
  (define (invisible-char? c)
    (let ((n (char->integer c)))
      (or (= n #xAD) (= n #x34F) (= n #x61C)
          (<= #x115F n #x1160)
          (<= #x17B4 n #x17B5)
          (<= #x180B n #x180F)
          (<= #x200B n #x200F)
          (<= #x202A n #x202E)
          (<= #x2060 n #x206F)
          (= n #x3164)
          (<= #xFE00 n #xFE0F)
          (= n #xFEFF) (= n #xFFA0)
          (<= #xFFF0 n #xFFF8)
          (<= #x1BCA0 n #x1BCA3)
          (<= #x1D173 n #x1D17A)
          (<= #xE0000 n #xE0FFF)
          ;; F2
          (<= #xFFF9 n #xFFFB)
          (<= #x13430 n #x1343F)
          ;; F3
          (= n #x2800) (= n #x16FE4) (= n #x1D159))))

  ;; private-use-char? : Char -> Boolean
  ;; A code point of the three Private Use areas (F6), 137,468, written
  ;; out: U+E000 to U+F8FF, U+F0000 to U+FFFFD, U+100000 to U+10FFFD.
  (define (private-use-char? c)
    (let ((n (char->integer c)))
      (or (<= #xE000 n #xF8FF)
          (<= #xF0000 n #xFFFFD)
          (<= #x100000 n #x10FFFD))))

  ;; unassigned-char? : Char -> Boolean
  ;; A code point Chez's tables give no character (F1): general category
  ;; Cn, the noncharacters among them. The one rule that moves with the
  ;; tables, on purpose: an upgrade can only assign, so only take more.
  ;; tests/test-chars.sps pins the count, 814,730 in Unicode 17.
  (define (unassigned-char? c)
    (eq? (char-general-category c) 'Cn))

  ;; mark-char? : Char -> Boolean
  ;; A combining mark, by Chez's tables (F4): general category Mn, Mc or
  ;; Me. A mark an upgrade assigns was unassigned-char? before.
  ;; tests/test-chars.sps pins the count, 2,543 in Unicode 17.
  (define (mark-char? c)
    (and (memq (char-general-category c) '(Mn Mc Me)) #t))

  ;; dash-char? : Char -> Boolean
  ;; A typographic dash, which a tag writes as `-` (F5), written out:
  ;; U+2010 to U+2015 (hyphen, non-breaking hyphen, figure dash, en dash,
  ;; em dash, horizontal bar) and U+2212 (minus). No other: U+2E3A, U+2E3B,
  ;; U+2043, U+301C and U+30FC are none, and U+00AD is invisible-char?.
  (define (dash-char? c)
    (let ((n (char->integer c)))
      (or (<= #x2010 n #x2015) (= n #x2212))))
)
