# Brief: chez-sodium, a small libsodium binding for Chez Scheme

Date: 2026-11-22
Status: draft for a separate project
For: Techo's accounts and API keys, and later its attachments
Read against: chez-sqlite3 at its local checkout (the pattern to copy), chez-libuv for
its FFI rules. libsodium's own behaviour below is from its documentation as remembered:
**check each signature and return code against `sodium.h` before binding it.**

## 1. Why

Techo needs four things Chez does not have:

1. a slow, salted password hash (argon2id);
2. random bytes from the system, for API keys;
3. a fast hash, to store API keys without storing the keys;
4. a comparison that does not leak where two byte strings differ.

libsodium has all four, is packaged everywhere, and is hard to misuse. No Chez binding
was found; the only Scheme one is a work in progress for CHICKEN.

## 2. Shape: copy chez-sqlite3

**No C shim. The system's libsodium is loaded when the program runs.** libsodium gives
every constant as a function (`crypto_pwhash_strbytes()` and the rest), so nothing needs
a header at build time. That is chez-sqlite3's shape, not chez-libuv's.

**The library is far smaller than chez-sqlite3.** libsodium's calls here are stateless:
bytes in, bytes out. There is no handle to own, no thread to belong to, no statement to
track.

## 3. The subset

A function is in only if Techo has a named use for it. Each one added is more to test
on every libsodium version.

### 3.1 Tier 1: Techo v1

| C function | Scheme verb | Techo's use |
|---|---|---|
| `sodium_init` | none; run at load | libsodium requires it before any other call |
| `sodium_version_string`, `sodium_library_version_major`, `_minor` | `sodium-version` | the load's floor check, and a report for bug reports |
| `crypto_pwhash_str` | `password-hash` | hash a password at account creation and at a password change |
| `crypto_pwhash_str_verify` | `password-verify` | check a login |
| `crypto_pwhash_str_needs_rehash` | `password-needs-rehash?` | re-hash at login when the limits were raised |
| `crypto_pwhash_strbytes`, `_opslimit_*`, `_memlimit_*`, `_passwd_min`, `_passwd_max` | named limits | sizes and the three presets: interactive, moderate, sensitive |
| `randombytes_buf` | `random-bytes` | make an API key |
| `crypto_generichash`, with its `_bytes*` and `_keybytes*` | `generic-hash` | store an API key as its BLAKE2b hash |
| `sodium_memcmp` | `bytes=?` | compare secrets in constant time |
| `sodium_memzero` | none; used inside | wipe the library's own copy of a password before freeing it |

Why these and not their neighbours:

- **`crypto_pwhash_str`, not `crypto_pwhash`.** The `_str` form picks the salt and
  writes the algorithm, salt and limits into one ASCII string. There is nothing for a
  caller to get wrong, and `needs-rehash` can read the limits back.
- **`crypto_generichash`, not SHA-256, for keys.** It is libsodium's recommended hash
  and takes an optional key. A fast hash is right for an API key, which is long and
  random; a slow one would tax every request.
- **`sodium_memzero` is internal.** The binding copies a password into foreign memory
  (§4). Wiping that copy is the binding's duty. A Scheme string cannot be wiped, and
  the documents should say so.

### 3.2 Tier 2: Techo's attachments, later

Specified now so the design leaves room; built when Techo needs it.

| C function | Scheme verb | Techo's use |
|---|---|---|
| `crypto_hash_sha256` | `sha256` | a blob's content address |
| `crypto_hash_sha256_init`, `_update`, `_final`, `_statebytes` | a streaming `sha256` | hash an upload without holding it all |
| `crypto_auth_hmacsha256_init`, `_update`, `_final`, `_statebytes` | `hmac-sha256` | sign S3 requests (AWS Signature Version 4) |

- The streaming HMAC is used, not the one-shot `crypto_auth_hmacsha256`: the one-shot
  takes a key of a fixed 32 bytes, and request signing uses keys of other lengths.
  Check this against the header.

### 3.3 Out

| Left out | Why |
|---|---|
| Secret-key and public-key encryption, signatures, key exchange, AEAD, streams | Techo encrypts nothing itself. TLS is the proxy's. |
| `crypto_pwhash` as a key-derivation function, scrypt | No use. |
| `sodium_malloc`, `sodium_mprotect_*`, `sodium_mlock` | Guarded memory needs a design of its own, and Scheme strings defeat it anyway. |
| Hex and base64 helpers | Plain Scheme does these. |
| `randombytes_uniform`, `randombytes_random` | No use; `random-bytes` covers keys. |
| Short hashes, one-time auth, `crypto_verify_*` | No use. |

## 4. The public API, as a sketch

```scheme
;; sodium-version : -> String

;; password-hash : String [Limits] -> String
;; password-verify : String String -> Boolean          ; hash, password
;; password-needs-rehash? : String [Limits] -> Boolean
;; Limits is (U 'interactive 'moderate 'sensitive (Pairof Nat Nat))   ; ops . memory bytes

;; random-bytes : Nat -> Bytevector
;; generic-hash : Bytevector [Nat] [Bytevector] -> Bytevector   ; input, size, key
;; bytes=? : Bytevector Bytevector -> Boolean
```

- A password is a string, hashed as its UTF-8 bytes, exactly as given. The binding does
  not normalise it. Techo decides whether to normalise before it calls.
- `password-verify` answers `#f` for a wrong password and for a malformed hash alike:
  libsodium does not tell them apart.
- `bytes=?` answers `#f` at once for different lengths. Only the lengths leak.
- Every exported procedure has a Typed Racket style signature comment, and
  `docs/reference.md` is held to them by a test, as chez-sqlite3's is.

## 5. Errors

Smaller than chez-sqlite3's tree, same shape and helpers.

```
&error
 └ &chez-sodium-error
    ├ &sodium-library-unavailable    reason path source detail candidates
    └ &sodium-failed                 the verb, and what libsodium answered
```

- Reasons for unavailable: `invalid-override`, `not-found`, `load-failed`,
  `below-floor`, `missing-api`, `init-failed`.
- `&sodium-failed` covers the one real runtime failure: `crypto_pwhash_str` answering
  -1, which means it could not get the memory its limit asks for.
- A caller's mistake is an assertion violation, raised before C is reached: a wrong
  type, a size out of range, a password with U+0000 if the header says the call stops
  at one (it takes a length, so it should not; check).
- Tests assert the reason symbol, never the message.
- No message ever holds a password or a hash. chez-sqlite3's `shown-value` does this.

## 6. FFI rules, inherited

These are the siblings' rules. Each was paid for with a bug; the record is named.

| Rule | Why | From |
|---|---|---|
| No Scheme object crosses. Every buffer is copied into a counted foreign block; every pointer is a `uptr`. | A collection can move a bytevector during a collect-safe call, and Chez accepts `u8*` there without a word. | chez-sqlite3 ADR-0011; chez-libuv `tests/test-source-rules.sps` rule 4 |
| A call that can block is `__collect_safe`. | A plain blocking call stops every other thread's collection. | chez-sqlite3 ADR-0011 |
| No `lock-object` for data. | Every raising path would need an unlock, and a missed one is invisible. | chez-sqlite3 ADR-0011, "Rejected" |
| Every value is range-checked before C. | Chez's `int` takes values C's does not, and `uptr` takes -1. | chez-sqlite3 `.plans/traps.md` |
| Nothing raises inside a critical section. | The block would leak, or be freed twice. | chez-sqlite3 global constraints |
| Only one library holds `foreign-procedure`; only one holds `foreign-alloc`. | So a check can read the seam. | chez-sqlite3 `make check-seam` |
| Every binding has a row in a convention table, and a test compares the two. | A binding with the wrong convention fails by name. | chez-sqlite3 `tests/test-conventions.sps` |
| The load runs once, and a failure is remembered and raised again. | Chez wedges on a library body that failed with a non-serious raise. | chez-sqlite3 `private/load-state.sls` |

**Which calls are collect-safe here:** `crypto_pwhash_str` and
`crypto_pwhash_str_verify`. Each runs for 100 ms or more by design. Techo's off-loop
hashing depends on this: [the chez-http-server proposal](chez-http-server-await-outside.md),
trap 1. Every other call in the subset returns in microseconds and stays plain.

## 7. What to reuse

From the FFI survey of chez-sqlite3 (`S/`) and chez-libuv.

### 7.1 Copy nearly as it is

| What | File in chez-sqlite3 |
|---|---|
| The Guix launcher and its checks | `scripts/guix-env`, `guix-env-enter`, `guix-env-selftest`, `require-tools`, `channels.scm` |
| Building and checking Chez in CI | `scripts/ci/build-chez.sh`, `check-chez.sh`, `floor.sh`, `check-action-pins.sh` |
| Fetching a locked Akku archive | `scripts/fetch-akku-lock` |
| The Makefile's skeleton | `help`, `check-help`, `deps`, `test`, `clean`, `check-clean`, `check-pins`, `check-guix`, `dev` |
| The suite runner's rules | `tests/check-suites.sps`, the shared exit form, the testing library |
| SRFI-64 as a pinned submodule | `.gitmodules`, `vendor/chez-srfi`, `make deps` |
| The memory gate | `make test-memory`, `check-memory-gate`, the planted overrun and leak |
| The docs site | `build-site.sps`, `site/*.sls`, `pages.yml` |
| Refusing an old or unthreaded Chez | `private/require-threaded.sls` (90 lines) |
| Remembering the first load failure | `private/load-state.sls` (70 lines) |
| Counted foreign blocks | `private/memory.sls` (97 lines), `private/counters.sls` |

### 7.2 Adapt

| What | Change |
|---|---|
| `private/discovery.sls` (220 lines) | The env var becomes `CHEZ_SODIUM_LIBRARY`. The sonames change, and **there are at least two**: this machine has `libsodium.so.23` (Ubuntu 24.04, libsodium 1.0.18), and newer releases use another. Try each in order. |
| `private/native.sls` | Keep `bind-required`, `bind-optional`, `call-with-bytes`, `foreign-bytes` and the ordered load. Replace the bindings. The load's steps become: choose, load, floor, `sodium_init`, bind. |
| `private/verify.sls` | The floor check reads `sodium_library_version_major` and `_minor`. |
| `private/conditions.sls` | The tree of §5. Keep the raise helpers and `shown-value`. |
| `tests/foreign-conventions.sls`, `check-seam.sps` | New rows and allow-lists. |
| `manifest.scm`, `packaging/debian-prereqs.txt` | `libsodium` for `sqlite`; `libsodium-dev` for `libsqlite3-dev`. |
| `packaging/floors.sexp`, `scripts/ci/floor.sh` | A `sodium` key. |
| `scripts/ci/build-sqlite.sh`, `check-sqlite.sh` | Become a libsodium build from its release tarball, with pinned hashes. |
| `.github/workflows/ci.yml` and its checker | Jobs `main`, `memory`, `nothreads`, `floor`, `current`, `site`. Linux only. |
| `Akku.manifest` | New name; dev dependencies only; no `scripts` clause, since nothing is built. |

### 7.3 Leave out

chez-sqlite3 carries these because a connection is long-lived shared state. libsodium
has none.

- Thread ownership and `&sqlite-wrong-thread`.
- The close latch and the interrupt exclusion.
- Statement tracking, caches and the statement state machine.
- The engine and critical-section sweeps, beyond the one rule in §6.
- The variadic-call check.
- Everything of chez-libuv's shim: the C file, the generated config, the relink guard.

### 7.4 One new helper

A password is copied into a foreign block, and that block must be wiped before it is
freed. A `call-with-secret-bytes` wraps `call-with-bytes` and calls `sodium_memzero` on
the way out, on every path.

## 8. Tests

Watch each one fail first, as Techo's `AGENTS.md` asks.

| What | How |
|---|---|
| The fast hash | BLAKE2b's published vectors (RFC 7693), copied from the RFC |
| Tier 2 hashes | NIST's SHA-256 vectors; RFC 4231 for HMAC-SHA256 |
| A password round trip | hash, verify true; a changed password verifies false |
| Reading another's hash | a hash string made by a small C program at test time verifies, as chez-sqlite3 uses C oracles |
| A malformed hash | verifies false, raises nothing |
| Needs rehash | false at the limits it was made with, true at higher ones |
| Random bytes | the length asked for; two calls differ; 0 bytes gives an empty bytevector |
| Constant-time compare | equal, unequal, different lengths, both empty |
| Collect-safe | one thread hashes at a high limit while another forces a collection; the collection ends before the hash returns |
| The load | each refusal reason, by a decoy library, as chez-sqlite3's `decoy-libsqlite3.c` does |
| Memory | the whole suite under Valgrind; a planted leak turns the gate red |
| The secret's copy | after a hash, the block that held the password reads as zeros before it is freed |

- **Password tests use libsodium's minimum limits**, read from `_opslimit_min` and
  `_memlimit_min`, so the suite stays fast, above all under Valgrind. Only the
  collect-safe test uses a high one.

**Versions to run on**

| libsodium | Where |
|---|---|
| the floor: 1.0.18 proposed | Ubuntu 24.04's package; this is `libsodium.so.23` |
| Guix's: 1.0.22 on this machine's Guix | the development container |
| the current release | built from source in CI |

Check that every Tier 1 function exists at the floor before fixing it.

## 9. Milestones

| # | Delivers | Unblocks |
|---|---|---|
| M0 | The repository, copied scaffolding, CI green on an empty suite | |
| M1 | Discovery, load, floor, `sodium_init`, `sodium-version`, the condition tree | |
| M2 | `random-bytes`, `generic-hash`, `bytes=?` | Techo's API keys |
| M3 | The three password verbs, collect-safe, with the secret wipe | Techo's accounts |
| M4 | Docs, the site, release 0.1.0 | Techo's auth slice |
| M5 | Tier 2: SHA-256 and HMAC-SHA256 | Techo's attachments |

## 10. Open

1. **Integer types.** libsodium takes `size_t` and `unsigned long long`. chez-sqlite3's
   convention table allows only `unsigned-64`. Proposed: Chez's `size_t` where C says
   `size_t`, `unsigned-64` for `unsigned long long`, and a new row in the allow-list.
2. **The floor.** 1.0.18 is proposed, as Ubuntu 24.04 ships it.
3. **The sonames** each supported release installs. Confirm before writing discovery.
4. **Whether to require a threaded Chez.** Proposed: yes, as the siblings do. The
   collect-safe calls only matter with threads, and the block counters use a mutex.
5. **The default limits** for `password-hash`. Proposed: `'interactive`, libsodium's
   own recommendation for a login.
6. **The names** of the verbs in §4.
7. Whether to publish on Akku at 0.1.0.
