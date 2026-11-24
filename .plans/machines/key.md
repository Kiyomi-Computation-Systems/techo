# The key machine

Generated from the table in `src/techo/keys.sls`. Do not edit.
Regenerate with `scripts/guix-env make machines`; a test fails when this file differs.

No state is an end, on purpose.

```mermaid
stateDiagram-v2
    none --> active: create
    none --> none: check, revoke, regenerate-other
    active --> active: check, regenerate-self, regenerate-other
    active --> revoked: revoke
    revoked --> revoked: check, revoke, regenerate-other
```
