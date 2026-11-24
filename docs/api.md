# The API

Every route is under `/v1`, speaks JSON, and needs an API key.
`GET /health` needs none.

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

**In this version an admin cannot yet make an account or a key.** That arrives with
login. So on a fresh server no key works, and every request to `/v1` with one
answers `401`.

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

`GET /v1/keys` takes:

- `limit`: how many, 1 or more. Default `50`. Over `100` counts as `100`. Anything
  else is a `400`.
- `after`: an id. The page starts after it. Use the last answer's `next`.

`next` is the id to pass as `after`, or `null` on the last page.

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
| `forbidden` | 403 | A key can only regenerate itself. |
| `not_found` | 404 | There is no such thing here. |
| `method_not_allowed` | 405 | That method is not allowed here. Has `Allow`. |
| `payload_too_large` | 413 | The request body is too large. |
| `unsupported_media_type` | 415 | The request body must be `application/json`. |
| `internal` | 500 | Something went wrong on the server. |
| `unavailable` | 503 | The service is busy or not ready; try again soon. |
| `timeout` | 504 | The request took too long. |
| `error` | other | The request could not be completed. |

A request the server refuses before Techo sees it, such as a malformed target, gets a
bare status and no body in this format.
