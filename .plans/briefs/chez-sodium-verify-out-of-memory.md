# Brief: can `password-verify` tell "wrong password" from "could not check"?

Date: 2026-11-24
For: chez-sodium (`../chez-sodium`), before its M3 (the password verbs) is planned
Filed as: not filed as an issue; sent to chez-sodium's session on 2026-11-24.
Answered the same day: no. chez-sodium's M3 plan (§4.2, item 4) settles it: no
change in M3, because libsodium 1.0.18, its floor, reports short memory as a
mismatch. Techo plans on §4's fallback.
This is the snapshot handed over. Once chez-sodium takes it up, its own `.plans/` is
the truth. The application asking is Techo (slice 3, login).

Read against: chez-sodium's brief §4.2 and its ADR-0006, item 4, on `main` at 3a14085.

## Summary

A question, not a demand. chez-sodium has decided that `password-verify` answers `#f`
in three cases: a wrong password, a hash it cannot read, and no memory. Techo's login
would like the third told apart. If that cannot be done at a fair price, Techo has a
fallback and will use it.

## 1. Why it matters to Techo

Techo's login does two things with a `#f`:

1. It answers 401, "wrong email or password".
2. It counts the try. Five in 15 minutes lock that email out of logging in.

So on a server short of memory:

- a person with the right password is told it is wrong;
- five such tries lock them out, for a fault that is the server's;
- the operator sees failed logins in the log, not a memory problem.

A hash fails the other way round: `password-hash` raises `&sodium-failed`, and Techo
answers 503. Only the verify is silent.

Techo runs one hash at a time, 64 MiB at `'interactive`, so this is rare. It is still
the wrong answer when it happens.

## 2. What chez-sodium already found

- `crypto_pwhash_str_verify` answers -1 for all three cases.
- At libsodium 1.0.18, `errno` reads `EINVAL` either way (finding L-F2). So `errno`
  does not help.

Techo has not checked later libsodium versions. That may be worth one look.

## 3. What Techo would like

Any way for a caller to learn "the check could not be made". For example,
`password-verify` raising `&sodium-failed` in that case, as `password-hash` does.

Two ways it might be done. Both are chez-sodium's to weigh, and neither may be worth
it:

- **Verify without the `_str` call.** Read the salt and limits out of the stored
  string, run `crypto_pwhash`, and compare in constant time. A -1 from `crypto_pwhash`
  is then a failure, and a mismatch is a wrong password. The cost is real: more
  bindings, a base64 decoder, and a parser for a string the `_str` call was chosen to
  hide.
- **Ask again after a -1.** When the verify fails, try to get the memory the hash's
  own limits name. If that fails, call it a failure. It is a guess, and it can be
  wrong either way when memory changes between the two.

## 4. What Techo does if the answer is no

After a `#f`, Techo hashes a throwaway string at the same limits. If that raises
`&sodium-failed`, memory is short: Techo answers 503 and does not count the try.

- It needs nothing from chez-sodium.
- It is also a guess.
- It doubles the cost of a wrong password. The rate limit bounds that.
- It only fits hashes made at Techo's current limits. An older hash with other limits
  is not covered.

## 5. What Techo is not asking

- No change to `password-hash` or `password-needs-rehash?`.
- No change to the two other `#f` cases. A hash that cannot be read may stay a `#f`.
- No date. Techo's login waits on M3 as a whole, not on this.
