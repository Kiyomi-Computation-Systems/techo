

## Amendment, 2026-11-24: the Makefile also runs on macOS, for development

Status: accepted (owner, 2026-11-24: "the Makefile should support macOS for
development. We can periodically test on the mac by hand (do not setup a CI runner)")

- **Techo still runs on Linux only.** That is what ships and what CI tests.
- **The Makefile's everyday targets also work on macOS:** `submodules`, `deps`,
  `test`, `run`, `clean`, `help`. The owner tests there by hand, now and then.
- **No macOS CI runner,** as before.
- **What it does not cover:** the Guix container, `check-pins` and `fetch` (GNU
  `diff`), and chez-sodium's own search for libsodium, which is Linux only
  (its ADR-0010): on macOS `CHEZ_SODIUM_LIBRARY` names the library.
