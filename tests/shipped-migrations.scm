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
     "CREATE INDEX api_keys_account ON api_keys(account, id)")))
