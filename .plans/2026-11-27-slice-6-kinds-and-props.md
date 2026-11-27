# Slice 6: kinds and their props; task transitions

Date: 2026-11-27
Status: the owner decided P1 to P9 on 2026-11-27 (below), and five more after
the review (its section, at the end). Reviewed: where the review and the text
above disagree, the review wins. The records are amended. Not built.
Records: ADR-0002 (the API), ADR-0003 (nodes and kinds), ADR-0004 (revisions),
ADR-0005 (the server never reads a body), ADR-0007 (machines). Read
[global-constraints.md](global-constraints.md) first, then the plans of slices
[4](2026-11-25-slice-4-nodes.md), [4b](2026-11-25-slice-4b-node-lifecycle.md)
and [5a](2026-11-26-slice-5a-tree.md).

## What this slice is for

Until now every node's `props` had to be `{}`. This slice gives each kind its
own:

- a Task has a status, a deadline and a scheduled time, and is finished,
  dropped or reopened by a command;
- a Contact has a name's parts, emails, phones, addresses and the like, in
  JSContact's shapes (RFC 9553);
- a Note may say when it is about;
- a Project and a Journal still have none.

## What the probes found (2026-11-27)

`build/probe-6/p.sps`, on a real file opened by `open-techo-db`: 20,000 Tasks,
every one with props of the size named. `state`, `revision` and `parent` sit
behind `props` in the row (traps.md).

| Props, every node | A page of 51 | A list of a rare state | A write of props |
|---|---|---|---|
| 60 bytes | 0.4 ms | 2 ms | 1.1 ms |
| 1 KiB | 1.9 ms | 7 ms | 1.2 ms |
| 2 KiB | 3.5 ms | 17 ms | |
| 4 KiB | 6.7 ms | 19 ms | 1.3 ms |
| 8 KiB | 13 ms | 32 ms | |
| 16 KiB | 26 ms | 57 ms | 1.8 ms |
| 64 KiB | 100 ms | 193 ms | 18.6 ms |

A straight line, with no cliff. One node's head costs under 0.03 ms at any
size. A filter through `json_extract` reads every row: 3 ms at 60 bytes, 167 ms
at 64 KiB.

## Decisions (the owner's, 2026-11-27)

| # | Question | Decided |
|---|---|---|
| P1 | One slice or two | One |
| P2 | A cap on props | 4 KiB (4,096 bytes of UTF-8) of the stored text, for every kind. Raised when real use asks: raising is always safe |
| P3 | Strictness | Each kind has a fixed set of members; another is a 400. The server stores one canonical form. **Members are only ever added, each optional, each with a default.** None is removed, renamed or made required. To be said in the guide, for those who write clients |
| P4 | Project, Journal | `{}` |
| P5 | A Note | an optional `at`, a When (P6). Never required, in a Journal or out |
| P6 | Dates and times in props | one type, **When**: a string in one of three forms, a date `2026-12-01`, a local time `2026-12-01T15:00`, a moment `2026-12-01T20:00:00Z`. The server checks it is real, stores it as given, and never converts or compares it. What is overdue is the client's to say |
| P7 | A Task's status | `TODO`, `DONE`, `WONTDO`, changed only by `POST /v1/nodes/{id}/done`, `/wontdo`, `/reopen`, each with `If-Match`. Every move between two different statuses is allowed. The server sets `closed` when a Task leaves `TODO` and clears it at a reopen. A transition writes a snapshot |
| P8 | A Contact | a strict subset of JSContact (RFC 9553), its names and shapes exactly: `kind`, `name`, `organizations`, `titles`, `emails`, `phones`, `addresses`, `anniversaries`, `links`, `onlineServices`, `speakToAs` |
| P9 | Tasks made before this slice | read as `TODO`. No migration; no snapshot is rewritten |

**P3's reason for "only added".** An old snapshot holds the old shape, and a
restore must still be taken. And an old client meeting a member it does not
know must be able to send it back untouched.

**P6's reasons.** A calendar day is no moment: "due 1 December" written as
midnight UTC is 30 November in New York. A local time is what org-mode has
always had, and it is shown as written on every device. A moment is for what
happens once, everywhere. The three are iCalendar's, told apart by their form:
10, 16 and 20 characters. **The forms are fixed now:** P3 lets a member be
added, not a new form of an old member's value. Left out: a local time in a
named zone (it needs a time zone database to check), and org's repeaters,
warning periods and ranges, which stay in the body.

**P8's cost.** JSContact is wordy: a list is a map keyed by a short id, a name
is a list of parts. A rich contact is about 1.8 KiB by my count (not measured):
a name, three emails, three phones, two addresses, an organisation, a title,
pronouns, two links, a birthday. A business with ten addresses will not fit.
**The real fix, if props must pass about 8 KiB,** is a migration that rebuilds
`nodes` with `props` last or moves it to its own table. Kept ready, not built.

## The design

### What changes in the API

| Route | Change |
|---|---|
| `PUT /v1/nodes/{id}` to make or replace | `props` is checked for the node's kind, and stored in canonical form |
| `POST /v1/nodes/{id}/done`, `/wontdo`, `/reopen` with `If-Match` | new: a Task's status. 200, the node without its body, the new `ETag` |
| every answer with a node or a snapshot | `props` as stored, with each kind's defaults filled in |

- **No migration.** The schema does not change.
- **Three codes more:** `props_too_large` (413), `not_a_task` (409),
  `wrong_status` (409).

### Canonical form

- The stored text has no white space, each object's members in the order this
  plan lists them, an Id map's keys in the order sent.
- A member whose value is its default is not stored (a Task's `TODO`), and is
  filled in when read. So a Task made before this slice, stored as `{}`, reads
  as `{"status":"TODO"}` (P9).
- An object that would be empty (`"contexts": {}`) is a 400: say nothing
  instead.
- The cap is on the stored text. The request's own cap (2 MiB) bounds what is
  parsed.
- JSContact's optional `@type` on a nested object is taken when it names the
  right type, and not stored.
- Every string in props: no U+0000; at most 1,000 characters unless a smaller
  limit is given.
- Parsing is linear in the request's size, and never raises.

### When

`parse-when : Any -> (U String 'invalid)`, pure.

| Form | Exactly | Checked |
|---|---|---|
| date | `YYYY-MM-DD` | a real day of the Gregorian calendar, years 0001 to 9999 |
| local | `YYYY-MM-DDTHH:MM` | a real day; 00:00 to 23:59 |
| moment | `YYYY-MM-DDTHH:MM:SSZ` | a real day; 00:00:00 to 23:59:59; no leap second, no fraction, no offset, upper case `T` and `Z` |

Anything else is `'invalid`: another length, a space, a lower-case letter.

### Each kind's props

**Project, Journal:** `{}`.

**Note:** `at`, a When. No default: absent is absent.

**Task:**

| Member | Value | Default | Who sets it |
|---|---|---|---|
| `status` | `TODO`, `DONE`, `WONTDO` | `TODO` | a create may give it; then only a command |
| `closed` | milliseconds, as every server time | none | the server alone |
| `deadline` | a When | none | the client |
| `scheduled` | a When | none | the client |

- **A create** may give any `status` (an import brings finished tasks). When
  it is not `TODO`, the server sets `closed` to the write's time. A `closed`
  sent on a create is a 400.
- **A replace** may send `status` and `closed`, and each must equal what is
  stored, else 409 `wrong_status`: a client that sends back what it read is
  not refused. Left out, each is kept.
- **A restore** copies the old snapshot's props whole, `status` and `closed`
  with them. It is the one other way a status changes. Documented.

**Contact:** the members below, each optional. Names and values are
JSContact's, case and all. `{}` is a valid Contact.

| Member | Shape | Checked |
|---|---|---|
| `kind` | `individual` (the default), `org`, `location` | |
| `name` | `{"components": [{"kind", "value"}], "isOrdered"}` | at least one component; kinds `title`, `given`, `given2`, `surname`, `surname2`, `credential`, `generation`; `isOrdered` a boolean, default false |
| `organizations` | Id map of `{"name", "units": [{"name"}], "contexts"}` | `name` or `units`; `units` not empty |
| `titles` | Id map of `{"name", "kind", "organizationId"}` | `kind` `title` (default) or `role`; `organizationId` a key of `organizations` |
| `emails` | Id map of `{"address", "contexts", "pref", "label"}` | `address` not empty, one `@`, no white space, at most 254 characters. Not parsed further |
| `phones` | Id map of `{"number", "features", "contexts", "pref", "label"}` | `features` a set of `mobile`, `voice`, `text`, `video`, `main-number`, `textphone`, `fax`, `pager` |
| `addresses` | Id map of `{"components": [{"kind", "value"}], "isOrdered", "countryCode", "full", "contexts", "pref"}` | at least one of `components`, `countryCode`, `full`; kinds `room`, `apartment`, `floor`, `building`, `number`, `name`, `block`, `subdistrict`, `district`, `locality`, `region`, `postcode`, `country`, `direction`, `landmark`, `postOfficeBox`; `countryCode` two upper-case letters |
| `anniversaries` | Id map of `{"kind", "date": {"year", "month", "day"}}` | `kind` `birth`, `death`, `wedding`; the date as JSContact's PartialDate: a month needs a year or a day, a day needs a month, and what is given is a real date |
| `links` | Id map of `{"uri", "kind", "contexts", "pref", "label"}` | `uri` not empty, no white space or control character; `kind` only `contact` |
| `onlineServices` | Id map of `{"service", "uri", "user", "contexts", "pref", "label"}` | `uri` or `user` |
| `speakToAs` | `{"grammaticalGender", "pronouns": Id map of {"pronouns", "contexts", "pref"}}` | one of the two; the gender one of `animate`, `common`, `feminine`, `inanimate`, `masculine`, `neuter` |

- **An Id** is 1 to 255 characters of `A-Z`, `a-z`, `0-9`, `-`, `_`. An Id
  map is not empty.
- **`contexts`** is a set (`{"work": true}`; every value `true`) of `private`
  and `work`; an address adds `billing` and `delivery`.
- **`pref`** is an integer 1 to 100. **`label`** is a string.
- **Left out of JSContact, each addable later (P3):** `nicknames`, `media`,
  `cryptoKeys`, `directories`, `calendars`, `schedulingAddresses`,
  `preferredLanguages`, `localizations`, `keywords`, `notes`, `personalInfo`,
  `relatedTo`, `members`; the kinds `group`, `device`, `application`; every
  `phonetic`, `sortAs`, `separator` and `defaultSeparator`; an address's
  `coordinates` and `timeZone`; an anniversary's `place`, `calendarScale` and
  timestamp form; a link's `mediaType`.
- **What Techo already has, and props do not repeat:** the Card's `uid` (the
  node's id), `created`, `updated`, and `name.full` (the node's title).

### The task machine

A table in a new pure `(techo tasks)`, as ADR-0007 has it.

| Status | `done` | `wontdo` | `reopen` |
|---|---|---|---|
| `TODO` | -> `DONE`, close | -> `WONTDO`, close | refuse-wrong-status |
| `DONE` | refuse-wrong-status | -> `WONTDO`, keep | -> `TODO`, open |
| `WONTDO` | -> `DONE`, keep | refuse-wrong-status | -> `TODO`, open |

- `close` sets `closed` to the write's time; `keep` leaves it; `open` removes
  it.
- The lifecycle's table gains nothing: a transition is its `write` event, so a
  trashed Task takes none (409 `wrong_state`) and an archived one does.
- **The order of a transition's checks,** by `node-command` and then the task
  table: 404; stale 412; the node's state 409 `wrong_state`; the kind 409
  `not_a_task`; the status 409 `wrong_status`.
- A transition is a write of content: revision up by one, a snapshot with the
  body copied, a change row whose op is the event's name (`done`, `wontdo`,
  `reopen`). It answers the node without its body.
- No request body. `If-None-Match` is a 400, as on every command.

### Where the code goes

- **`(techo when)`**, new, pure: `parse-when`.
- **`(techo contact)`**, new, pure: `parse-contact-props : Any -> (U Alist
  'invalid)`, the checked value in canonical order.
- **`(techo tasks)`**, new, pure: the table; `task-step`; `task-props-after :
  Alist Symbol Natural -> Alist`.
- **`(techo props)`**, new, pure: `parse-props : String Any (U Alist #f)
  Boolean Natural -> (U String 'invalid 'too-large 'wrong-status)`: the kind,
  the request's value, the stored props (for a replace), whether it is a
  create, now; the canonical text. `stored-props->json : String String ->
  Alist`: a kind and the stored text, with the defaults filled in.
  `props-cap`.
- **`(techo nodes)`:** `parse-content` hands `props` on as read; the judging
  moves to `parse-props`, called in the job where the stored props are known.
- **`(techo node-routes)`:** the three commands; `props->json` by
  `stored-props->json`; the three codes.
- **`(techo node-store)`:** nothing new. A transition reads the node with its
  body and calls `write-node!`, as a restore does.

## What must hold, and what would catch a break

| # | What holds | A mutant that must be caught |
|---|---|---|
| R1 | Every stored props text is valid for its node's kind, canonical, and at most 4,096 bytes | the cap checked on the request's text |
| R2 | What is read back, sent again unchanged, is accepted and stores the same bytes | a default written into the stored text |
| R3 | A member no kind has, a member of another kind, a value of the wrong type: 400, and nothing written | a Contact's member taken on a Task |
| R4 | A Task's status changes only by a command, a create or a restore | a replace's `status` taken |
| R5 | `closed` is there exactly when the status is not `TODO`, and is the time the Task last left `TODO` | `closed` reset on `DONE` to `WONTDO` |
| R6 | A transition bumps the revision by one, appends one snapshot with the same title, body and content type, and one change row named for the event | the body lost |
| R7 | The order: 404, 412, `wrong_state`, `not_a_task`, `wrong_status` | the status judged before the stale check |
| R8 | A Task stored as `{}` reads as `TODO`, and `done` works on it | the default not filled in on a snapshot |
| R9 | Every When stored is one of the three forms and a real date | 30 February taken |
| R10 | A props text of any size is judged in time linear in its size, and no raise carries any of it | a quadratic check of an Id map's keys |
| R11 | A purged row's props are `{}` and are never read | |
| R12 | The invariants of slices 4 to 5b still hold | (the model's own) |

## How it is checked

- **The pure parts:** `parse-when` over every form's edges and a sweep of real
  and unreal dates; each kind's parser over every member, each refusal, and
  round trips (R2); the task table exhaustively; the 4 KiB edge at 4,096 and
  4,097 bytes, with multi-byte characters.
- **The routes:** each row of the tables above through real requests.
- **The model:** it states the rules itself. Its generator makes props for
  each kind, good and bad, and runs transitions on Tasks in every status and
  state, on other kinds, and on Tasks stored as `{}`. After every request it
  checks R1, R5 on the whole database.
- **Integration:** a Task's life and a Contact's round trip against the
  running server.
- **A file made before this slice** is opened by the new code: its Tasks read
  as `TODO`.

## The work

0. **The records that bind the build** (me, in this plan's commit, once the
   plan is reviewed): ADR-0002, ADR-0003, ADR-0004, ADR-0007, the constraints.
1. **When and the Contact** (Opus): `when.sls`, `contact.sls`, their suites.
2. **The task machine and the props' doorway** (Opus): `tasks.sls`,
   `props.sls`, their suites; `nodes.sls`' `parse-content` and its tests; the
   three codes in `errors.sls`; a machine document for the task table. Beside
   task 1, against `parse-contact-props`' signature above.
3. **The routes** (Opus): `node-routes.sls`, `test-node-routes.sps`,
   `test-app.sps`. After 1 and 2.
4. **The model** (Opus) and **the integration tests** (Sonnet), side by side.
5. **The rest of the records** (me): the API guide, with P3's rule for client
   authors; the changelog; the README; the schema; the ledger.
6. **A read-only adversarial review of the build** (Opus), then its fixes.

Before any of it: **a read-only review of this plan** (Opus).

## Not in this slice

- A list by kind or by status (slice 7, with search).
- Anything the server does with a When: overdue, sorting, reminders.
- A local time in a named zone; repeaters and ranges.
- vCard in or out: a client converts, by RFC 9555.
- A Journal's rule about its Notes' `at` (P5: there is none).
- A table rebuild to put `props` last.

## The review of this plan (Opus, 2026-11-27)

Read-only, with probes under `build/review-6/`. Ten blockers. I reran its
probes of `node-command`, the JSON reader and `uri-string?`, and read the
lines cited for the rest.

### Five more decisions (the owner's, 2026-11-27, after the review)

| # | Question | Decided |
|---|---|---|
| P10 | Does a restore change a Task's status? | No. A restore brings back the old `deadline` and `scheduled` and keeps the present `status` and `closed`. P7 stands as said: only a command changes a status |
| P11 | A replace with no `props` | keeps the stored props. `{}` clears them. A Task's `status` and `closed` are kept either way |
| P12 | `jsonparse` and `chez-uri` as the server's own dependencies | yes, by an amendment to ADR-0001. Both are in the lock already, for circuit and the HTTP server |
| P13 | An address's `countryCode` | any two capital letters. Not checked against ISO's list, and the guide says so |
| P14 | An imported finished Task | a create may give `closed` (milliseconds) when its `status` is not `TODO`. After that only the server sets it |

### Blockers, and what they change

1. **Props are judged before the job, not in it.** Judging in the job would
   answer a bad and stale replace 412 where a test holds 400 with no write
   job, put the parsed JSON in a job (the routes' header forbids it), and walk
   up to 2 MiB on the writer's thread (19 ms, `walk.sps`). **So:** every check
   that needs no stored value runs in the Reader, after the key. A replace
   that names no kind is judged for every kind there; the job picks the stored
   kind's verdict. Only a Task's `status` and `closed` are compared in the
   job.
2. **The store gains one statement,** `node-props`. A replace and a restore
   of a Task need the stored props, and `node-head` reads none. A snapshot's
   answer needs its node's kind, to fill in `TODO`: `snapshot-work` reads
   `node-head` first, as `revisions-work` does.
3. **A transition is no event of `node-command`:** it raises for `done`. A
   second pure function, `task-command`, asks `node-command` as a `replace`
   (404, 412, `wrong_state`, in that order), then the kind, then the task
   table. `node-command` and `event-op` stay as they are.
4. **A restore that copied the status contradicted P7 and broke R5.** P10.
5. **"A strict subset of JSContact" was not true as written,** and a value's
   rule can never be tightened later: an old snapshot must still restore. The
   rules are pinned below.
6. **The canonical form was not one form.** The reader keeps a name given
   twice, at every depth, and keeps the order sent. **So:** every object is
   checked for a name twice; an Id map's keys are sorted; a set's members are
   in this plan's order; a number is an exact integer (`1.0` arrives as a
   flonum and is refused).
7. **A replace with no `props` was undecided,** and reading it as `{}` loses
   data. P11.
8. **Two libraries become the server's own.** P12.
9. **`wrong_status` had two meanings, and a code has one text.** A fourth
   code, `status_fixed` (409), is a replace's claim about `status` or
   `closed` that differs from what is stored.
10. **Files no task owned,** now owned (the work, below).

### The interface, pinned

**`(techo when)`**, pure, imports `(rnrs)`.

- `parse-when : Any -> (U String 'invalid)`: the string itself when its length
  is 10, 16 or 20 and its punctuation exact. A digit is U+0030 to U+0039 by
  code point: never `char-numeric?` (true of U+0661), never `string->number`
  (`"+12"` is 12, `"1e2"` is 100.0). Year 0001 to 9999, the Gregorian leap
  rule, hour 00 to 23, minute and second 00 to 59. Never raises.

**`(techo contact)`**, pure, imports `(rnrs)` and `(only (uri easy)
uri-string?)`.

- `parse-contact-props : Any -> (U Alist 'invalid)`: the checked value in
  canonical order. `@type` naming the right type is taken and dropped; an
  explicit default is taken and dropped. No cap here. Linear: an object's
  names are counted against its bound before any value is read; a name twice
  and an `organizationId` are found by a hashtable. Never raises.

**`(techo tasks)`**, pure, imports `(rnrs)`, `(techo machine)`, `(techo
nodes)`.

- `task-statuses` (`"TODO"`, `"DONE"`, `"WONTDO"`); `task-events` (`done`,
  `wontdo`, `reopen`); `task-rows`; `task-document`.
- `task-step : Symbol Symbol -> (values Symbol Symbol)`: the next status, and
  `close`, `keep`, `open` or `refuse-wrong-status`. The table has no end.
- `task-command : Found (U Symbol #f) (U String #f) (U Symbol #f) Symbol ->
  (values Symbol (U Symbol #f))`: what was found, the node's state, the stored
  kind, the stored status with its default filled in, the event. The first
  three answers are `(node-command found state 'replace 'ok #f)`'s; then a
  kind that is not `"task"` is `refuse-not-a-task`; then `task-step`.

**`(techo props)`**, pure, imports `(rnrs)`, `(jsonparse easy)`, `(techo
when)`, `(techo contact)`, `(techo tasks)`.

- `props-cap` is 4096, of the bytes the writer writes.
- A **Draft** is the canonical text, or for a Task a record of `status`,
  `closed`, `deadline`, `scheduled`, each as sent or absent.
- `request-props : Alist Boolean -> (U (Listof (Pair String Draft)) 'invalid
  'too-large 'absent)`: the request's object and whether it is a create. A
  Draft for the kind named, or for every kind that takes the value when a
  replace names none. `'absent` when a replace has no `props` (P11); a create
  with none is as `{}`.
- `props-command : String (U Draft 'absent #f) (U String #f) Boolean Natural
  -> (U (Pair 'write String) Symbol)`: the stored kind, its Draft, the stored
  text, whether a create, now. `('write . text)`, or `refuse-invalid-props`,
  `refuse-props-too-large`, `refuse-status-fixed`.
- `transition-props : String Symbol Symbol Natural -> String`: the stored
  text, the next status, `close`, `keep` or `open`, now.
- `restore-props : String String String -> String`: the kind, the snapshot's
  text, the stored text (P10).
- `stored-props->json : String String -> Alist`: a kind and a stored text. It
  fills a Task's `status` when absent, and nothing else: JSContact's defaults
  are the RFC's to imply. It raises, with no irritant, for text that is not
  JSON.

**`(techo nodes)`:** `parse-content` takes `props` absent or any JSON object,
and hands it on; any other value is `'invalid`. Nothing else changes.

**`(techo node-store)`:** `node-props : Tx Bytevector Bytevector -> (U String
#f)`, one statement, in `node-store-statements`.

**`(techo errors)`:** `props_too_large` 413; `not_a_task`, `wrong_status`,
`status_fixed`, each 409.

### The order of answers

A `PUT`:

1. the key's shape 401; the id 400; the precondition 428 or 400;
2. the key, in its read job, 401;
3. 415; the request over its cap 413; `invalid_json` 400;
4. the content 400, then the props 400;
5. the body over its cap 413 `payload_too_large`, then 413 `props_too_large`;
6. in the write job: 401, 404, 412, `wrong_state`, `kind_fixed`; then, for a
   replace that named no kind, the stored kind's 400 or 413; then
   `status_fixed`.

A transition: 401; the id 400; 428 or 400 (`If-None-Match` is a 400); in the
job 401, 404, 412, `wrong_state`, `not_a_task`, `wrong_status`. A refusal
reads no body.

### A Task's props, restated

| Request | `status` | `closed` |
|---|---|---|
| A create, none given | `TODO` | none |
| A create, `DONE` or `WONTDO` | as given | as given (P14), else the write's time |
| A create, `TODO` with a `closed` | | 400, before the job: a create names its kind |
| A replace | must equal the stored one, with its default, or be absent: else 409 `status_fixed` | the same |
| A transition | the table's | `close` sets the write's time, `keep` leaves it, `open` removes it |
| A restore | kept (P10) | kept |

**R5, restated:** `closed` is there exactly when the status is not `TODO`. It
is the time the Task last left `TODO`, or the time an import gave.

### The Contact's rules, pinned against RFC 9553

- **Every string:** no U+0000, and no noncharacter (U+FDD0 to U+FDEF, and the
  last two code points of each plane): JSContact is I-JSON.
- **Every number** is an exact integer.
- **Mandatory, where the object is there:** a name component's `kind` and
  `value`; an org unit's `name`; a title's `name`; an email's `address`; a
  phone's `number`; an anniversary's `kind` and `date`; a link's `uri`; a
  pronoun entry's `pronouns`.
- **`emails`' `address`:** atoms joined by single dots, an `@`, atoms joined
  by single dots; at most 254 characters. An atom has no control character,
  space, or any of `()<>[]:;@\,."`. So `a@b` is taken; `@`, `a@` and `a..b@c`
  are not. **Narrower than the RFC:** a quoted local part and an address
  literal are refused.
- **`uri`,** in `links` and `onlineServices`: what `uri-string?` takes. It
  needs a scheme and is ASCII: `hello` and `https://ex.com/é` are refused.
- **`countryCode`:** two capital letters (P13).
- **A PartialDate:** a year 1 to 9999; what is given must be a real date; 29
  February with no year is one.
- **`@type` at the top of props,** `version`, `uid`: 400. Props are no Card.
- **Techo refuses a member it does not know (P3),** where JSContact says to
  keep one. So Techo holds a subset of the data and is no JSContact processor.
  The guide says so.
- **To make a Card, a client adds** `"@type": "Card"`, `"version": "1.0"`, a
  `uid` (the node's id as `urn:uuid:`), and `name.full` from the title.

### Answers the plan lacked, now given

| Case | Answer |
|---|---|
| A replace sends `"status":"TODO"` and `{}` is stored | taken; `{}` stored |
| `closed: 1.7e12`, `pref: 1.0`, `closed: null` | 400 |
| A name twice in any object; an Id twice | 400 |
| A replace, no kind, props that suit only another kind | 400, in the job, after 404, 412 and `wrong_state` |
| A replace naming `task` on a Note | 400 before the job if the props fail as a Task's; else 409 `kind_fixed` |
| `done` on an archived Task | 200 |
| `done` on a trashed Note | `wrong_state` |
| `done` on an active Note | `not_a_task` |
| A body on a transition | not read |
| A node, a list item, a link's node or a snapshot of a Task stored `{}` | `{"status":"TODO"}` |
| A Contact stored `{}` | `{}` |
| A `{}` snapshot restored onto a `DONE` Task | `DONE` and `closed` kept |
| `2026-12-01T24:00`, `1900-02-29`, `+026-12-01` | 400 |
| 100,000 members in props | 400, after at most twelve names read |
| Stored props that are not JSON | 500, with none of it in the log |
| An object empty as sent, under the top (`"contexts": {}`) | 400 |

### What the plan said that was wrong

- "The store: nothing new"; "`node-command` and then the task table"; the op
  "by `event-op`".
- **A rich contact is 1,950 bytes with short ids and 2,460 with ids of 36
  characters,** not 1.8 KiB. Ten addresses fit alone (13 do); with the rest of
  that contact they are 4,331 bytes, over the cap.
- "The three are iCalendar's": its kinds, not its text.
- The probe's table left out the answer's own work on the loop's thread:
  3.4 ms for a page of 51 at 4 KiB, where today's is 0.06 ms.

### Measured by the review

- The reader keeps a name twice and the order sent; `1.0` is a flonum; `\/`
  is written `/`; other scripts are written raw; a control character costs
  six bytes. The writer's text passes `json_valid`.
- A 2 MiB value of 22,000 members: parse 22 ms, a linear walk 19 ms, the write
  11 ms. A quadratic check for a name twice: 1.3 s.
- A page of 51 Contacts at 4,012 bytes through `nodes-page`: 6.6 ms. A head
  0.011 ms; a head with props 0.13 ms.
- 39 emails, 30 phones or 13 addresses fit alone.

### The work, as reviewed

This replaces "The work" above.

0. **The records that bind the build** (me, in this plan's commit).
1. **When and the Contact** (Opus): `when.sls`, `contact.sls`,
   `test-when.sps`, `test-contact.sps`.
2. **The task machine and the props' doorway** (Opus): `tasks.sls`,
   `props.sls`, their suites; `parse-content` in `nodes.sls` and its cases in
   `test-nodes.sps`; `lifecycle-document`'s prose and `lifecycle.md`; the four
   codes in `errors.sls` and `test-errors.sps`; `task.md`, the Makefile's
   `machines` and `scripts/render-machines.sps`. Beside task 1, against the
   signatures above.
3. **The store and the routes** (Opus): `node-props` in `node-store.sls` and
   `test-node-store.sps`; `node-routes.sls`; `test-node-routes.sps` (the test
   that a replace with props is a 400; its helpers and Task fixtures; a Task
   seeded as `{}`); `test-app.sps`. After 1 and 2.
4. **The model** (Opus): its laws restated (below), props from a corpus
   written by hand as data. Beside it, **the integration tests** (Sonnet).
5. **The rest of the records** (me).
6. **A read-only adversarial review of the build** (Opus), then its fixes.

### What must hold, added, and the model's laws

- R13: a replace with no `props` changes none; one with `{}` clears all but a
  Task's `status` and `closed`.
- R14: a restore changes no status and no `closed`.
- R15: no check of props runs in a write job but the comparison of a Task's
  `status` and `closed`: a refused request with bad props makes no write job.
- R16: a refused transition reads no body.
- R17: a value is stored as one text whatever order its Id maps were sent in.
- The model: `content-ops` gains `done`, `wontdo`, `reopen`; `feed-state`
  keeps the state for the three; a transition changes only props; R1, R5 and
  R9 on every row and snapshot after every request.

**Mutants the first table would have let live:** `integer?` without `exact?`;
`char-numeric?` or `string->number` in `parse-when`; no check for a name twice
in a nested object; a quadratic one (95,000 keys must be judged in well under
a second); `organizationId` found by `assoc`; the cap counted in characters;
a status compared without its default; props judged in the job;
`not_a_task` before `wrong_state`; a raise that carries props; `@`, `hello` or
U+FFFE taken.

### Holes in the decisions, left as decided and to be documented

- **P3 covers values too:** a rule is never tightened, and a new member goes
  last in its object.
- **P7:** every transition copies the body into a snapshot, up to 1 MiB.
- **P8:** a round trip from a Card through Techo gains `name.full` from the
  title.
