((1 "techo's database" ("PRAGMA application_id = 1952801640"))
 (2 "accounts and api keys"
    ("CREATE TABLE accounts (
  id            BLOB    NOT NULL PRIMARY KEY CHECK (length(id) = 16),
  username      TEXT    NOT NULL UNIQUE CHECK (username GLOB '[a-z0-9]*' AND username NOT GLOB '*[^a-z0-9_-]*' AND length(username) <= 32),
  email         TEXT    NOT NULL UNIQUE CHECK (email NOT GLOB '*[A-Z]*'),
  password_hash TEXT    NOT NULL,
  created       INTEGER NOT NULL
) STRICT"
     "CREATE TABLE api_keys (
  id        BLOB    NOT NULL PRIMARY KEY CHECK (length(id) = 16),
  account   BLOB    NOT NULL REFERENCES accounts(id),
  name      TEXT    NOT NULL CHECK (length(name) BETWEEN 1 AND 64),
  key_hash  BLOB    NOT NULL UNIQUE CHECK (length(key_hash) = 32),
  created   INTEGER NOT NULL,
  last_used INTEGER,
  revoked   INTEGER
) STRICT"
     "CREATE INDEX api_keys_account ON api_keys(account, id)"))
 (3 "nodes, revisions and changes"
   ("CREATE TABLE nodes (
  num          INTEGER PRIMARY KEY,
  id           BLOB    NOT NULL UNIQUE CHECK (length(id) = 16),
  owner        BLOB    NOT NULL REFERENCES accounts(id),
  author       BLOB    NOT NULL REFERENCES accounts(id),
  kind         TEXT    NOT NULL CHECK (kind IN ('project','journal','note','task','contact')),
  title        TEXT    NOT NULL CHECK (length(title) <= 1000),
  content_type TEXT    NOT NULL CHECK (length(content_type) BETWEEN 1 AND 255),
  props        TEXT    NOT NULL CHECK (json_valid(props)),
  revision     INTEGER NOT NULL CHECK (revision >= 1),
  created      INTEGER NOT NULL,
  updated      INTEGER NOT NULL
) STRICT"
    "CREATE INDEX nodes_owner ON nodes(owner, id)"
    "CREATE TABLE revisions (
  node         BLOB    NOT NULL REFERENCES nodes(id),
  revision     INTEGER NOT NULL CHECK (revision >= 1),
  author       BLOB    NOT NULL REFERENCES accounts(id),
  title        TEXT    NOT NULL,
  content_type TEXT    NOT NULL,
  props        TEXT    NOT NULL CHECK (json_valid(props)),
  created      INTEGER NOT NULL,
  body         TEXT    NOT NULL,
  PRIMARY KEY (node, revision)
) STRICT"
    "CREATE TABLE changes (
  owner    BLOB    NOT NULL REFERENCES accounts(id),
  seq      INTEGER NOT NULL,
  node     BLOB    NOT NULL,
  revision INTEGER NOT NULL,
  op       TEXT    NOT NULL,
  created  INTEGER NOT NULL,
  PRIMARY KEY (owner, seq)
) STRICT, WITHOUT ROWID")))
