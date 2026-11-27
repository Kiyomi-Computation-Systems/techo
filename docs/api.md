# The API

Every route is under `/v1`, speaks JSON, and needs an API key, except
`POST /v1/login`, which is how you get one. `GET /health` needs none.

An account is made at the command line, not over the API: see
[Make an account](running.md#make-an-account).

## Log in

An email and a password make a new API key.

```sh
curl -H 'Content-Type: application/json' \
  -d '{"email":"ada@example.com","password":"correct horse battery","name":"laptop"}' \
  http://127.0.0.1:8080/v1/login
```

```json
{"id":"0193a5c0-8000-7000-8000-000000000001","name":"laptop","created":1795515226123,"last_used":null,"revoked":null,"key":"techo_9f2c…"}
```

- It answers `201`, with `Cache-Control: no-store`.
- `name` is the key's name, 1 to 64 characters. It is needed.
- The email's ASCII letters are not case sensitive. The password is, all of it.
- **The key is shown once.** Keep it. Log in again for another.
- Every login makes a new key. Send it as the [Bearer key](#authenticate) below.

What can go wrong:

| Status | `code` | When |
|---|---|---|
| 400 | `invalid_json` | The body is not JSON. |
| 400 | `invalid_request` | Not an object; a field missing, given twice, or unknown; a value that is not text; a bad email or key name; a password over 1,024 bytes. |
| 401 | `invalid_credentials` | The email or the password is wrong. |
| 409 | `too_many_keys` | The password was right, but the account has 100 active keys. |
| 413 | `payload_too_large` | The body is over 16 KiB. |
| 415 | `unsupported_media_type` | `Content-Type` is not `application/json`. |
| 429 | `rate_limited` | Too many tries. `Retry-After` says how many seconds to wait. |
| 503 | `unavailable` | Busy: too many logins at once, or the server is short of memory. `Retry-After: 5`. |

**A wrong email and a wrong password get the same answer** on purpose: the same
status, body and headers. So nobody can use login to find out which emails have
accounts. Do not try to tell them apart.

**The limit:** 5 wrong tries for one email, and 20 tries from one address, in 15
minutes. The next try is a `429`, and `Retry-After` is a whole number of seconds,
at most `900`, until the window ends. A good login clears the email's count.
[Login limits](running.md#login-limits) says more.

**The 100-key cap:** an account may have 100 active keys. At the cap, a login with
the right password is a `409`. Revoke a key you do not use
(`POST /v1/keys/{id}/revoke`, with a key you still have), then log in again. With
no working key, `techo user password` revokes them all (see
[Make an account](running.md#make-an-account)).

## Authenticate

Send the key in a header:

```sh
curl -H 'Authorization: Bearer techo_0123…' http://127.0.0.1:8080/v1/account
```

- A key is `techo_` and 64 lowercase hex digits: 70 characters.
- It is **shown once**, when it is made. Techo keeps only a hash of it, so a lost
  key cannot be looked up. Regenerate it while it still works.
- No header, a key in the wrong shape, an unknown key and a revoked key all get
  the same `401`.

## The routes

### `GET /v1/account`

Who the key belongs to.

```sh
curl -H "Authorization: Bearer $KEY" http://127.0.0.1:8080/v1/account
```

```json
{"id":"0193a5c0-7b1e-7000-8000-0123456789ab","username":"ada","email":"ada@example.com","created":1795515226123}
```

### `GET /v1/keys`

The account's keys, in id order. Never a secret.

```sh
curl -H "Authorization: Bearer $KEY" 'http://127.0.0.1:8080/v1/keys?limit=2'
```

```json
{"items":[
  {"id":"0193a5c0-8000-7000-8000-000000000001","name":"laptop","created":1795515226123,"last_used":1795601626123,"revoked":null},
  {"id":"0193a5c0-8000-7000-8000-000000000002","name":"phone","created":1795515300000,"last_used":null,"revoked":null}],
 "next":"0193a5c0-8000-7000-8000-000000000002"}
```

### `POST /v1/keys/{id}/revoke`

Stops a key from working. It takes no body. It answers the key, with `revoked` set.
Revoking a key twice is fine: it answers the same. But a key that revoked *itself*
no longer works, so its second try is a `401`.

```sh
curl -X POST -H "Authorization: Bearer $KEY" \
  http://127.0.0.1:8080/v1/keys/0193a5c0-8000-7000-8000-000000000002/revoke
```

```json
{"id":"0193a5c0-8000-7000-8000-000000000002","name":"phone","created":1795515300000,"last_used":null,"revoked":1795602000000}
```

### `POST /v1/keys/{id}/regenerate`

Swaps a key's secret for a new one. The old secret stops working at once. It takes no
body. It answers the key and `key`, the new secret: **the only time you see it.** The
answer has `Cache-Control: no-store`.

**If the answer never arrives** (a timeout, a dropped connection), the old secret may
already be dead and the new one lost. Try the old secret once. If it gets a `401`,
that key is gone: revoke it from another key.

```sh
curl -X POST -H "Authorization: Bearer $KEY" \
  http://127.0.0.1:8080/v1/keys/0193a5c0-8000-7000-8000-000000000001/regenerate
```

```json
{"id":"0193a5c0-8000-7000-8000-000000000001","name":"laptop","created":1795515226123,"last_used":1795601626123,"revoked":null,"key":"techo_9f2c…"}
```

## Nodes

A node is one note: a title, a body of text, and what kind of note it is. Every
write is checked against the node's revision, and every write is kept until the node is deleted.

```json
{"id":"0193a5c0-9000-7000-8000-000000000001","kind":"note","state":"active",
 "parent":null,"title":"Shopping","body":"* apples\n* pears","content_type":"text/org","props":{},
 "revision":1,"created":1795515226123,"updated":1795515226123}
```

| Field | What it is |
|---|---|
| `id` | A UUID of **version 7**, which you make. Anything else is a `400`. |
| `kind` | `project`, `journal`, `note`, `task` or `contact`. Set when the node is made; it never changes. |
| `state` | `active`, `archived` or `trashed`. See [putting a node away](#putting-a-node-away). You never send it. |
| `parent` | The id of the Project or Journal it is in, or `null` at the top level. See [folders](#folders). You may give it when you make the node, and never in a replace. |
| `title` | Up to 1,000 characters. May be empty. |
| `body` | Text, up to 1 MiB (1,048,576 bytes of UTF-8). Techo never reads it. |
| `content_type` | What the body is, such as `text/org`: 1 to 255 printable ASCII characters (a space is fine, a tab is not) with a `/`. Techo stores it and does nothing with it. |
| `props` | Must be `{}` for now. You may leave it out. |
| `revision` | 1 when made, one more after every write and every change of state. |
| `created`, `updated` | [Times](#times). |

Neither the title nor the body may hold the character U+0000.

### The revision is the ETag

- Every answer that holds a node has `ETag: "7"`, the revision in quotes.
- **A write must say what it expects**, in a header:
  - `If-None-Match: *` to make a node: "only if this id is not used yet".
  - `If-Match: "7"` to change one: "only if it is still at revision 7".
- A write with neither is a `428`. A write that expected wrong is a `412`, and
  nothing is changed.
- **After a `412`, read the node**, merge your change into what you get, and write
  again with its revision. Techo never merges.
- **Build `If-Match` from the JSON's `revision`,** not by copying the `ETag`
  header: a proxy in between may change the header's text.
- `If-Match` is one revision in quotes and nothing else. `*`, a list, and a weak
  tag (`W/"7"`) are a `400`.

### `PUT /v1/nodes/{id}`: make a node

```sh
curl -X PUT -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -H 'If-None-Match: *' \
  -d '{"kind":"note","title":"Shopping","body":"* apples","content_type":"text/org"}' \
  http://127.0.0.1:8080/v1/nodes/0193a5c0-9000-7000-8000-000000000001
```

It answers `201`, the node, `ETag: "1"`, and `Location`.

Add `"parent":"<id>"` to make it inside a Project or a Journal. See
[folders](#folders).

**If the answer never arrives,** send it again. A `412` then means the first try
got through: read the node.

### `PUT /v1/nodes/{id}`: replace a node's content

The same route with `If-Match`. Send the whole content: `title`, `body` and
`content_type`. It answers `200`, the node, and the new `ETag`.

```sh
curl -X PUT -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -H 'If-Match: "1"' \
  -d '{"title":"Shopping","body":"* apples\n* pears","content_type":"text/org"}' \
  http://127.0.0.1:8080/v1/nodes/0193a5c0-9000-7000-8000-000000000001
```

- `kind` may be left out. Given, it must be the node's own, or it is a `409`.
- Send only the five content fields. `id`, `revision` and the times are a `400`
  in a request.
- The same content sent twice makes two revisions.

### `GET /v1/nodes/{id}`

The node, with its `ETag`.

### `GET /v1/nodes`

Your **active** nodes, in id order, **without their bodies**. [Paged](#paging).

- `?state=archived` or `?state=trashed` lists those instead. One state a call.
- `?state=active` is the default. Any other value is a `400`.
- `?parent=<id>` lists one node's children, and `?parent=null` the top level.
  Without it the list is flat: every node, wherever it is. See
  [folders](#folders).

### `GET /v1/nodes/{id}/revisions`

Every write of content the node has had, newest first, without bodies:
`revision`, `title`, `content_type`, `props`, `created`. [Paged](#paging), but
`after` and `next` are revision numbers here.

**The numbers can skip.** A change of state takes a revision number and keeps no
copy. A node at revision 2 that is archived is at revision 3 and still lists
2, 1. Write it again and it lists 4, 2, 1. Revision 3 is a `404`.

### `GET /v1/nodes/{id}/revisions/{n}`

One old revision, whole, with its `body`.

### `POST /v1/nodes/{id}/revisions/{n}/restore`

Makes a **new** revision with revision `n`'s title, body, content type and props.
Nothing old is changed. It needs `If-Match`, takes no body, and answers `200`,
the node, and the new `ETag`.

```sh
curl -X POST -H "Authorization: Bearer $KEY" -H 'If-Match: "2"' \
  http://127.0.0.1:8080/v1/nodes/0193a5c0-9000-7000-8000-000000000001/revisions/1/restore
```

### Putting a node away

A node is `active`, `archived` or `trashed`.

| Route | From | To |
|---|---|---|
| `POST /v1/nodes/{id}/archive` | active | archived |
| `POST /v1/nodes/{id}/unarchive` | archived | active |
| `POST /v1/nodes/{id}/trash` | active or archived | trashed |
| `POST /v1/nodes/{id}/untrash` | trashed | active |
| `DELETE /v1/nodes/{id}` | trashed | gone, for good |

```sh
curl -X POST -H "Authorization: Bearer $KEY" -H 'If-Match: "3"' \
  http://127.0.0.1:8080/v1/nodes/0193a5c0-9000-7000-8000-000000000001/trash
```

- **All five need `If-Match`** and take no body.
- The four `POST`s answer `200`, the node **without its body**, and the new
  `ETag`. The revision goes up by one, so your next write needs the new one.
  `updated` changes too.
- Any other move is a `409` `wrong_state`: archiving a trashed node, deleting one
  that is not trashed.
- **An archived node is an ordinary node** that the default list leaves out. You
  can still read and write it, and it stays archived.
- **A trashed node cannot be written.** A replace or a restore is a `409`. Untrash
  it first. Untrash always gives an active node, even if it was archived before.
- If your revision is stale you get the `412` first. Read the node: its `state`
  tells you the rest.

**`DELETE` removes the node and every revision of it.** It answers `204` and
nothing else. It cannot be undone.

- Afterwards every route answers `404` for that id, and making a node with it
  is a `412`, for everyone. Use a new id.
- A node with a very large history takes a moment to delete: about half a
  second for 200 MiB. Other writes wait meanwhile.
- It does not reach your backups. Its times, and the fact that it existed, stay
  in the database.
- The text is wiped from the database file at once. A copy can stay in the
  `-wal` file beside it until the next write.

**If an answer never arrives,** send it again. For the four `POST`s a `412` then
means the first try may have got through: read the node. For the `DELETE` a
`404` means it is done.

### Folders

A **Project** or a **Journal** can hold other nodes. Nothing else can.

| Parent | May hold |
|---|---|
| Project | any kind, other Projects too |
| Journal | Notes only |
| Note, Task, Contact | nothing |

A node has one parent, or none: then it is at the top level. Its `parent` field
says which. Techo keeps no order among a parent's children. Sort them yourself.

**Make a node in a folder** by giving `parent` when you make it.

**Move a node:**

```sh
curl -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -H 'If-Match: "3"' -d '{"parent":"0193a5c0-9000-7000-8000-000000000002"}' \
  http://127.0.0.1:8080/v1/nodes/0193a5c0-9000-7000-8000-000000000001/move
```

- The body is exactly `{"parent": "<id>"}`, or `{"parent": null}` for the top
  level.
- The body may be 16 KiB at most.
- It answers `200`, the node without its body, and the new `ETag`. The revision
  goes up by one, as for any change, even when the parent is the one it had.
- A move keeps no copy in the node's revisions. **Restoring an old revision does
  not move a node back.** Move it back yourself.
- **If the answer never arrives,** send it again. A `412` then means the first
  try may have got through: read the node.

**List a folder:** `GET /v1/nodes?parent=<id>`. It shows active children. Ask
again with `?state=archived` and `?state=trashed` to see them all.

**What a parent must be,** or the answer is a `409` `invalid_parent`:

- a Project or Journal of yours that may hold this kind;
- not in the trash;
- not too deep: a parent may have at most 63 folders above it.

A parent that is someone else's gets the same answer as one that does not
exist.

**A folder 64 levels down can hold nothing.** Moving a whole folder under a deep
one can push what is inside it further down than that. Those nodes are fine,
but nothing can be made in them or moved into them. The answer does not say
which reason applied: count the parents above it if you need to know.

**A node cannot go inside itself,** or inside anything under it. That is a `409`
`would_loop`. (More than 64 levels under it, the answer is `invalid_parent`
instead: too deep is found first.)

#### Trashing a folder does not trash what is in it

**Trash and archive change that one node only.** Everything inside it, at every
level, keeps its own state.

What that means for a client:

- The nodes inside still show in the flat list, and under `?parent=<id>`. They
  are `active`, so they are **not** in `?state=trashed`.
- A client that walks down from the top level never reaches them: the default
  list leaves the trashed folder out. So they are in no view you get by
  walking.
- **If you show a flat list, hide every node that has a trashed folder anywhere
  above it.** Follow `parent` upward to find out. Techo does not do this for
  you.
- Untrashing the folder brings everything back as it was, because nothing
  inside was changed.
- You may trash the nodes inside as well, one by one. Then untrashing the
  folder does not untrash them: each is its own node.

What Techo checks, and what it does not:

- Nothing can be made **directly** in a trashed folder or moved directly into
  it, and a trashed node cannot be moved. Untrash it first. Things can be moved
  **out**.
- Only the folder you name is looked at. A folder that is active but sits
  inside a trashed one still takes new nodes.

#### Deleting a folder

`DELETE` is refused with a `409` `has_children` while the node holds anything,
in any state. Empty it first:

```sh
curl -X POST -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -H 'If-Match: "5"' -d '{"parent":null}' \
  http://127.0.0.1:8080/v1/nodes/0193a5c0-9000-7000-8000-000000000002/move-children
```

`move-children` moves a node's children to another parent in one go.

- `If-Match` is the **folder's** revision, which does not change.
- It answers `{"moved": 12, "left": 3}`, with no `ETag`.
- It moves at most 1,000 a call. **Call it until `moved` is `0`.**
- `left` counts what is still inside. Once `moved` is `0`, those are trashed, or
  of a kind the new parent cannot hold. Deal with each: untrash it and move it,
  move it somewhere that can hold it, or delete it. A trashed folder among them
  must be emptied itself before it can be deleted.
- **Sending it twice is safe.** The second call moves whatever is inside by
  then, which may include a node someone moved in meanwhile.
- **Each child it moves gets a new revision,** without being asked for its old
  one. No content is lost, but a write you had ready for one of them will get a
  `412`: read it again.
- The new parent cannot be the folder itself or anything inside it.

There is no way yet to delete a folder and everything in it in one request.

### What can go wrong with a node

| Status | `code` | When |
|---|---|---|
| 400 | `invalid_json` | The body is there and is not JSON. |
| 400 | `invalid_request` | Anything else wrong with the request. The list is below. |
| 404 | `not_found` | No such node or revision. **Another account's node looks the same,** and so does a deleted one. |
| 409 | `kind_fixed` | A replace named another kind. |
| 409 | `wrong_state` | The node's state does not allow this. See [putting a node away](#putting-a-node-away). |
| 409 | `invalid_parent` | The parent cannot hold this node. See [folders](#folders). |
| 409 | `would_loop` | The move would put a node under itself. |
| 409 | `has_children` | A `DELETE` of a node that still has children. |
| 412 | `precondition_failed` | The node is not at the revision you gave, or the id you want to make is in use. |
| 413 | `payload_too_large` | The body is over 1 MiB, or the whole request is over 2 MiB. A move's request is over 16 KiB. |
| 415 | `unsupported_media_type` | `Content-Type` is not `application/json`. |
| 428 | `precondition_required` | A write with neither `If-Match` nor `If-None-Match`. |

A `400` `invalid_request` is one of:

- a bad id, revision, `limit`, `after`, `state` or `parent`;
- a bad `If-Match` or `If-None-Match`: both at once, `If-None-Match` that is not
  `*`, or `If-None-Match` on a restore, a change of state, a move or a `DELETE`;
- no body, or a body that is not one JSON object;
- a field missing, unknown, given twice or of the wrong type;
- a `kind` that is not one of the five, or `props` that is not `{}`;
- a title or content type past its limit, or U+0000 in the title or body.

Other things to know:

- **A bad key is a `401` before the body is looked at.** So fix the key first: a
  `PUT` with a bad key and a bad body answers `401`, not `400` or `413`.

- **Send text as UTF-8, not as `\u` escapes.** The whole request may be 2 MiB. A
  client that escapes every non-ASCII character can pass that with a body well
  under 1 MiB.
- **A large write must arrive within 10 seconds,** or it is a `504`.
- An id is unique across all accounts. Making a node with an id someone else
  holds is a `412`, and reading it is a `404`.

## A key's fields

| Field | What it is |
|---|---|
| `id` | The key's id: a UUID. Not the secret. |
| `name` | The device it was made for. |
| `created` | When it was made. |
| `last_used` | The last time this key **changed** something, to the day. `null` if it never has. |
| `revoked` | When it was revoked. `null` while it works. |

**`last_used` counts writes, not reads.** A key that only reads shows `null`, however
often it is used. Reads do not write to the database, so Techo cannot note them: a
device that only reads will look unused.

## Revoke or regenerate

| | Your own key | Another key of your account | Another account's key |
|---|---|---|---|
| revoke | yes | yes | `404` |
| regenerate | yes | `403` | `404` |

Another account's key looks like no key: `404`. Revoke a lost device's key from any
other key. To replace a key's secret, use that key.

## Paging

`GET /v1/keys`, `GET /v1/nodes` and a node's revisions take:

- `limit`: how many, 1 or more. Default `50`. Over `100` counts as `100`. Anything
  else is a `400`.
- `after`: an id. The page starts after it. Use the last answer's `next`.

`next` is the id to pass as `after`, or `null` on the last page. For a node's
revisions both are revision numbers, and the page starts below `after`.

## Times

A time is whole milliseconds since 1970, UTC: `1795515226123`.

## Errors

An error is [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem details,
`Content-Type: application/problem+json`:

```json
{"type":"about:blank","title":"Not Found","status":404,"code":"not_found","detail":"There is no such thing here."}
```

| Member | What it is |
|---|---|
| `type` | Always `about:blank`. |
| `title` | The status's standard name. |
| `status` | The HTTP status again. |
| `code` | Techo's own word. **Switch on this.** |
| `detail` | A plain sentence. Show it to a person, do not parse it. |

| `code` | Status | Meaning |
|---|---|---|
| `invalid_json` | 400 | The request body is not valid JSON. |
| `invalid_request` | 400 | The request is not valid. |
| `unauthorized` | 401 | A valid API key is needed. Has `WWW-Authenticate: Bearer`. |
| `invalid_credentials` | 401 | The email or password is wrong. Login only. |
| `forbidden` | 403 | A key can only regenerate itself. |
| `not_found` | 404 | There is no such thing here. |
| `method_not_allowed` | 405 | That method is not allowed here. Has `Allow`. |
| `too_many_keys` | 409 | The account has 100 active keys; revoke one first. Login only. |
| `kind_fixed` | 409 | A node's kind cannot be changed. |
| `wrong_state` | 409 | The node's state does not allow this request. |
| `invalid_parent` | 409 | The parent cannot hold this node. |
| `would_loop` | 409 | The move would put a node under itself. |
| `has_children` | 409 | The node still has children. |
| `precondition_failed` | 412 | The node has changed, or already exists; read it again. |
| `payload_too_large` | 413 | The request body is too large. |
| `unsupported_media_type` | 415 | The request body must be `application/json`. |
| `precondition_required` | 428 | A write needs `If-Match`, or `If-None-Match: *` to make a node. |
| `rate_limited` | 429 | Too many login attempts. Has `Retry-After`. |
| `internal` | 500 | Something went wrong on the server. |
| `unavailable` | 503 | The service is busy or not ready; try again soon. |
| `timeout` | 504 | The request took too long. |
| `error` | other | The request could not be completed. |

A request the server refuses before Techo sees it, such as a malformed target, gets a
bare status and no body in this format.
