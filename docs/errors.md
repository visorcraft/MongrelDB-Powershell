# Error handling

Methods throw an exception on failure. The exception carries a `Category` note
property (and `StatusCode`, `ErrorCode` when available) so you can catch by
category. Inspect `Category` to branch on the category of failure.

---

## The error model

The client uses two complementary mechanisms:

1. **Categories** - `Auth`, `NotFound`, `Conflict`, `Query`, `Network`,
   `InvalidArg`. Switch on these to branch on the *category* of failure.
2. **Exception message** - a human-readable message for the failure, including
   the daemon's structured error code when the server supplied one.

## Error category reference

| Category | Meaning | Typical cause |
|----------|---------|---------------|
| `Auth` | HTTP 401 or 403 | Missing/bad credentials against an auth-enabled daemon |
| `NotFound` | HTTP 404 | Missing table, missing schema, dropped resource |
| `Conflict` | HTTP 409 | Unique, foreign-key, check, or trigger violation at commit |
| `Query` | HTTP 400 or 5xx | Malformed request, server-side failure, everything else |
| `Network` | transport error | Connection refused, timeout, DNS failure |
| `InvalidArg` | client-side | nil or otherwise invalid argument |

## The daemon's error envelope

When the daemon rejects a request, it returns a JSON envelope decoded into the
exception message:

```json
{
  "status": "aborted",
  "error": {
    "code": "UNIQUE_VIOLATION",
    "message": "duplicate key in column 1",
    "op_index": 0
  }
}
```

Structured codes you will commonly see in the message:

| code | Meaning |
|------|---------|
| `UNIQUE_VIOLATION` | A unique/PK constraint rejected the commit |
| `FK_VIOLATION` | A foreign-key reference was missing |
| `CHECK_VIOLATION` | A check constraint or trigger rejected the commit |
| `NOT_FOUND` | A named resource (table, schema) does not exist |

## HTTP status -> category mapping

| HTTP status | Category | Notes |
|-------------|----------|-------|
| 401, 403 | `Auth` | Bad/missing credentials |
| 404 | `NotFound` | Resource not found |
| 409 | `Conflict` | Constraint violation at commit |
| 400 | `Query` | Malformed request / bad query |
| 5xx | `Query` | Daemon-side failure |
| other non-2xx | `Query` | Catch-all |
| 2xx | (no error) | Success |

## Discriminating errors

Switch on the category:

```powershell
try {
    Get-MongrelDBSchemaFor -Table 'missing_table'
} catch {
    switch ($_.Exception.Category) {
        'NotFound'  { Write-Host "table does not exist: $($_.Exception.Message)" }
        'Conflict'  { Write-Host "unexpected conflict on a read: $($_.Exception.Message)" }
        'Auth'      { Write-Host "bad credentials: $($_.Exception.Message)" }
        'Query'     { Write-Host "server error: $($_.Exception.Message)" }
        'Network'   { Write-Host "can't reach daemon: $($_.Exception.Message)" }
        default     { Write-Host "error: $($_.Exception.Message)" }
    }
}
```

## Recovery patterns

### Auth failure - do not retry blindly

A retry will not fix bad credentials. Surface the error to the operator.

### Not found - fall back, do not crash

For lookups by primary key, a 404 may be a normal "absent" result (when the
table itself is missing). Treat it accordingly.

### Constraint conflict - the engine already rolled back

```powershell
try {
    Invoke-MongrelDBTransaction -Ops $ops
} catch {
    if ($_.Exception.Category -eq 'Conflict') {
        Write-Host "constraint violated: $($_.Exception.Message)"
        # The engine already discarded the whole batch. Nothing to undo.
    }
}
```

### Transient failure - retry with an idempotency key

`Network` and `Query` (for 5xx) cover transport and transient server failures.
With an idempotency key, retrying a transaction is safe (see
[transactions.md](transactions.md)).

## Next steps

- [transactions.md](transactions.md) - constraint handling and retries in context
- [auth.md](auth.md) - credential management
