#!r6rs
;;; (techo version): the package's version, in one place.
(library (techo version)
  (export techo-version)
  (import (rnrs))

  ;; techo-version : String
  ;; The same string Akku.manifest gives the package.
  (define techo-version "0.0.0")
)
