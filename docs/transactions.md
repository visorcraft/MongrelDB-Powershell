# Transactions

MongrelDB commits every write through a single atomic transaction endpoint
(`POST /kit/txn`). This guide covers the two ways to use it - a one-shot
single op, and a staged batch - plus idempotency keys for safe retries and
constraint-violation handling.

The engine enforces `UNIQUE`, foreign-key, check, and trigger constraints at
**commit time**. A violation aborts the entire batch: no op in the batch
becomes visible.

---

## Single puts vs. batch transactions

### Single op: `Add-MongrelDBRow`

`Add-MongrelDBRow` is a convenience wrapper that sends a one-op transaction.
Use it when a write is independent and you do not need atomicity across
multiple rows.

```powershell
try {
    Add-MongrelDBRow -Table 'orders' -Cells @{ 1 = 1; 2 = 'Alice'; 3 = 99.5 }
} catch {
    Write-Host "put failed: $($_.Exception.Message)"
}
```

`Set-MongrelDBRow` (upsert) and `Remove-MongrelDBRow` are the same shape:
single-op transactions.

### Batch: `Invoke-MongrelDBTransaction`

When several writes must succeed or fail together, stage them in an ops array
and commit once. All ops go to the server in a single HTTP request and commit
atomically.

```powershell
$ops = @(
    @{ put = @{ table = 'orders'; cells = @(1, 10, 2, 'Dave'); returning = $false } },
    @{ put = @{ table = 'orders'; cells = @(1, 11, 2, 'Eve'); returning = $false } },
    @{ delete_by_pk = @{ table = 'orders'; pk = 2 } }
)
Invoke-MongrelDBTransaction -Ops $ops
```

An `upsert` op takes an additional `update_cells` array applied on a
primary-key conflict. Omitting it means "do nothing on conflict".

## Idempotency keys for safe retries

Networks drop requests and daemons crash after committing but before replying.
An idempotency key makes a commit safe to retry: the daemon remembers the key
and replays the **original** result on a duplicate commit, even across restarts.

Pass the key via `-IdempotencyKey`:

```powershell
$ops = @( @{ put = @{ table = 'charges'; cells = @(1, $orderId, 2, 199.0); returning = $false } } )
# On a retry with the same key the daemon returns the first commit's result
# instead of inserting a second row.
Invoke-MongrelDBTransaction -Ops $ops -IdempotencyKey 'charge-order-123'
```

Rules for keys:

- Any non-empty string works. Prefer content-derived, globally-unique values.
- Omitting the key disables idempotency - a retry will commit again.
- The key scopes the **entire batch**, not individual ops. Reuse the exact
  same ops and key together when retrying.

## Handling constraint violations

Constraint violations arrive as HTTP 409, mapped to the `Conflict` category.
The exception message carries the daemon's structured message:

```powershell
try {
    Invoke-MongrelDBTransaction -Ops $ops
} catch {
    if ($_.Exception.Category -eq 'Conflict') {
        Write-Host "constraint violated: $($_.Exception.Message)"
        # The engine already rolled back the whole batch. Nothing to undo.
    } elseif ($_.Exception.Category -eq 'Auth') {
        Write-Host "not authorized: $($_.Exception.Message)"
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

## Rollback

There are two notions of "rollback":

1. **Server-side.** When `Invoke-MongrelDBTransaction` fails with `Conflict`,
   the engine has already discarded the entire batch. Nothing was written.
2. **Client-side.** Because ops are staged in your own array, discarding them
   is just a matter of not calling `Invoke-MongrelDBTransaction`. There is no
   transaction handle to roll back - the batch only exists once you send it.

## Summary

| Goal | Use |
|------|-----|
| One independent write | `Add-MongrelDBRow` / `Set-MongrelDBRow` / `Remove-MongrelDBRow` |
| Several writes that must commit together | `Invoke-MongrelDBTransaction` with an ops array |
| Retry safely after a network blip | `Invoke-MongrelDBTransaction` with a stable idempotency key |
| Distinguish constraint classes | Check the `Conflict` category and read the message |
| Abort before sending | Don't call `Invoke-MongrelDBTransaction` - the batch is local |

See [errors.md](errors.md) for the full error category set and
[queries.md](queries.md) for read patterns.
