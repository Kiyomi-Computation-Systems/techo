#!r6rs
;;; (techo store): each SQL statement slice 3 needs, as a procedure of a Tx,
;;; the handle a job gets from (techo doorway). It runs inside a job, so it
;;; holds no connection, reads no clock and makes no id: ids, hashes and
;;; times arrive as arguments. It answers a row or #f and raises nothing of
;;; its own; whatever SQLite raises passes through (ADR-0012, ADR-0013).
;;; From (techo doorway) it takes only tx-execute!, tx-query and
;;; tx-query-row.
;;;
;;; Every query on api_keys but `key-by-hash` and `touch-key!` names the
;;; account (ADR-0003): another account's key is a key that is not there.
;;; `touch-key!` takes the key id the caller just found by its hash.
;;;
;;; Login (slice 3b) adds `account-by-username`, `set-password-hash!` (only
;;; while the stored hash is the one given) and `revoke-all-keys!`.
;;;
;;; Rows. An Account and a Key are R6RS records, made here only, from a
;;; row's columns in the table's order. A column that is NULL reads as #f.
;;;   Account = (id username email password-hash created)
;;;     id: Bytevector (16)  username, email, password-hash: String
;;;     created: Natural (whole milliseconds since 1970, UTC)
;;;   Key = (id account name hash created last-used revoked)
;;;     id, account: Bytevector (16)  hash: Bytevector (32)  name: String
;;;     created: Natural  last-used, revoked: (U Natural #f); revoked #f
;;;     means active.
(library (techo store)
  (export insert-account! account-by-id account-by-email account-by-username
          set-password-hash! revoke-all-keys!
          insert-key! key-by-hash key-of-account keys-page keys-page-sql
          revoke-key! replace-key-hash! touch-key! count-active-keys
          account? account-id account-username account-email
          account-password-hash account-created
          key? key-id key-account key-name key-hash key-created
          key-last-used key-revoked)
  (import (rnrs)
          (only (chez-sqlite3) sql-null?)
          (only (techo doorway) tx-execute! tx-query tx-query-row))

  ;;; Rows

  ;; account? : Any -> Boolean
  ;; account-id, account-password-hash : Account -> Bytevector / String
  ;; account-username, account-email : Account -> String
  ;; account-created : Account -> Natural
  (define-record-type account
    (fields (immutable id account-id)
            (immutable username account-username)
            (immutable email account-email)
            (immutable password-hash account-password-hash)
            (immutable created account-created)))

  ;; key? : Any -> Boolean
  ;; key-id, key-account, key-hash : Key -> Bytevector
  ;; key-name : Key -> String
  ;; key-created : Key -> Natural
  ;; key-last-used, key-revoked : Key -> (U Natural #f)
  (define-record-type key
    (fields (immutable id key-id)
            (immutable account key-account)
            (immutable name key-name)
            (immutable hash key-hash)
            (immutable created key-created)
            (immutable last-used key-last-used)
            (immutable revoked key-revoked)))

  ;; col : Any -> Any      NULL reads as #f
  (define (col v) (if (sql-null? v) #f v))

  ;; row->account : (U (Vectorof Any) #f) -> (U Account #f)
  (define (row->account r)
    (and r (make-account (col (vector-ref r 0)) (col (vector-ref r 1))
                         (col (vector-ref r 2)) (col (vector-ref r 3))
                         (col (vector-ref r 4)))))

  ;; row->key : (U (Vectorof Any) #f) -> (U Key #f)
  (define (row->key r)
    (and r (make-key (col (vector-ref r 0)) (col (vector-ref r 1))
                     (col (vector-ref r 2)) (col (vector-ref r 3))
                     (col (vector-ref r 4)) (col (vector-ref r 5))
                     (col (vector-ref r 6)))))

  (define account-columns "id, username, email, password_hash, created")
  (define key-columns "id, account, name, key_hash, created, last_used, revoked")

  ;;; Accounts

  ;; insert-account! : Tx Bytevector String String String Natural -> Void
  ;; id, username, email, password-hash, created.
  (define (insert-account! tx id username email password-hash created)
    (tx-execute! tx
      "INSERT INTO accounts(id, username, email, password_hash, created) VALUES (?, ?, ?, ?, ?)"
      id username email password-hash created))

  ;; account-by-id : Tx Bytevector -> (U Account #f)
  (define (account-by-id tx id)
    (row->account
     (tx-query-row tx (string-append "SELECT " account-columns
                                     " FROM accounts WHERE id = ?")
                   id)))

  ;; account-by-email : Tx String -> (U Account #f)
  (define (account-by-email tx email)
    (row->account
     (tx-query-row tx (string-append "SELECT " account-columns
                                     " FROM accounts WHERE email = ?")
                   email)))

  ;; account-by-username : Tx String -> (U Account #f)
  (define (account-by-username tx username)
    (row->account
     (tx-query-row tx (string-append "SELECT " account-columns
                                     " FROM accounts WHERE username = ?")
                   username)))

  ;; changes : Tx -> Natural
  ;; Rows the last statement of this transaction changed.
  (define (changes tx)
    (vector-ref (tx-query-row tx "SELECT changes()") 0))

  ;; set-password-hash! : Tx Bytevector String String -> Boolean
  ;; id, the hash the account must hold now, the new hash. #t when a row
  ;; changed; #f for an unknown id or a stored hash that is not the old one.
  (define (set-password-hash! tx id old-hash new-hash)
    (tx-execute! tx
      "UPDATE accounts SET password_hash = ? WHERE id = ? AND password_hash = ?"
      new-hash id old-hash)
    (> (changes tx) 0))

  ;;; Keys

  ;; insert-key! : Tx Bytevector Bytevector String Bytevector Natural -> Void
  ;; id, account, name, key-hash, created.
  (define (insert-key! tx id account name key-hash created)
    (tx-execute! tx
      "INSERT INTO api_keys(id, account, name, key_hash, created) VALUES (?, ?, ?, ?, ?)"
      id account name key-hash created))

  ;; key-by-hash : Tx Bytevector -> (U Key #f)
  ;; The one lookup that names no account: it finds the account. It finds a
  ;; revoked key too; the caller decides.
  (define (key-by-hash tx hash)
    (row->key
     (tx-query-row tx (string-append "SELECT " key-columns
                                     " FROM api_keys WHERE key_hash = ?")
                   hash)))

  ;; key-of-account : Tx Bytevector Bytevector -> (U Key #f)
  ;; account, key id: #f for another account's key.
  (define (key-of-account tx account id)
    (row->key
     (tx-query-row tx (string-append "SELECT " key-columns
                                     " FROM api_keys WHERE account = ? AND id = ?")
                   account id)))

  ;; keys-page-sql : Boolean -> String
  ;; The statement of `keys-page`, with an AFTER or without. Exported so that
  ;; a test can ask SQLite for its plan.
  (define (keys-page-sql after?)
    (string-append "SELECT " key-columns
                   " FROM api_keys WHERE account = ?"
                   (if after? " AND id > ?" "")
                   " ORDER BY id LIMIT ?"))

  ;; keys-page : Tx Bytevector (U Bytevector #f) Natural -> (Listof Key)
  ;; account, after, n: at most N keys of the account whose id is greater
  ;; than AFTER (all of them for #f), in id order. Read from the index
  ;; api_keys_account (account, id): no sort step.
  (define (keys-page tx account after n)
    (map row->key
         (if after
             (tx-query tx (keys-page-sql #t) account after n)
             (tx-query tx (keys-page-sql #f) account n))))

  ;; revoke-key! : Tx Bytevector Bytevector Natural -> Void
  ;; account, id, now. Only where revoked is null: a second revoke keeps the
  ;; first time.
  (define (revoke-key! tx account id now)
    (tx-execute! tx
      "UPDATE api_keys SET revoked = ? WHERE account = ? AND id = ? AND revoked IS NULL"
      now account id))

  ;; revoke-all-keys! : Tx Bytevector Natural -> Natural
  ;; account, now: revokes each key of the account not revoked yet, and
  ;; answers how many. Keys revoked before keep their time.
  (define (revoke-all-keys! tx account now)
    (tx-execute! tx
      "UPDATE api_keys SET revoked = ? WHERE account = ? AND revoked IS NULL"
      now account)
    (changes tx))

  ;; replace-key-hash! : Tx Bytevector Bytevector Bytevector -> Void
  ;; account, id, new hash.
  (define (replace-key-hash! tx account id new-hash)
    (tx-execute! tx
      "UPDATE api_keys SET key_hash = ? WHERE account = ? AND id = ?"
      new-hash account id))

  ;; touch-key! : Tx Bytevector Natural -> Void
  ;; key id, now: sets last_used. The id comes from `key-by-hash`.
  (define (touch-key! tx id now)
    (tx-execute! tx "UPDATE api_keys SET last_used = ? WHERE id = ?" now id))

  ;; count-active-keys : Tx Bytevector -> Natural
  ;; account.
  (define (count-active-keys tx account)
    (vector-ref
     (tx-query-row tx
       "SELECT count(*) FROM api_keys WHERE account = ? AND revoked IS NULL"
       account)
     0))
)
