# The migrate machines

Generated from the tables in `src/techo/migrations.sls`. Do not edit.
Regenerate with `scripts/guix-env make machines`; a test fails when this file differs.

## `techo migrate`: the run machine

```mermaid
stateDiagram-v2
    peek-opening --> peeking: opened
    peek-opening --> opening: missing
    peek-opening --> ended: failed
    peeking --> closing: current, refused, failed
    peeking --> reopening: work
    reopening --> opening: done, failed
    opening --> looking: opened
    opening --> ended: failed
    looking --> converting: unconverted
    looking --> locking: pending
    looking --> closing: current, refused, failed
    converting --> looking: converted
    converting --> pausing: busy-retry
    converting --> closing: busy-none, failed
    pausing --> looking: done
    pausing --> closing: failed
    locking --> relooking: locked
    locking --> closing: busy, failed
    relooking --> applying: pending
    relooking --> undoing-to-look: changed
    relooking --> undoing-to-fail: failed
    relooking --> closing: failed-ended
    applying --> applying: more
    applying --> checking: last
    applying --> closing: txn-ended, failed-ended
    applying --> undoing-to-fail: failed
    checking --> stamping: clean
    checking --> undoing-to-fail: violations, failed
    checking --> closing: failed-ended
    stamping --> committing: stamped
    stamping --> undoing-to-fail: failed
    stamping --> closing: failed-ended
    committing --> locking: below
    committing --> closing: latest, failed-ended
    committing --> undoing-to-fail: failed
    undoing-to-look --> looking: done
    undoing-to-look --> closing: failed
    undoing-to-fail --> closing: done, failed
    closing --> ended: done, failed
```

## `techo serve`: the check machine

```mermaid
stateDiagram-v2
    peek-opening --> peeking: opened
    peek-opening --> ended: missing, failed
    peeking --> closing: serve, fresh, behind, unconverted, ahead, foreign, failed
    closing --> ended: done, failed
```
