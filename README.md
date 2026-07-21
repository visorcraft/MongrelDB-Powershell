<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB PowerShell Client</h1>

<p align="center">
  <b>PowerShell module for MongrelDB - embedded+server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
  <br />
  Built on Invoke-WebRequest and the built-in JSON cmdlets. No external dependencies; runs on Windows PowerShell 5.1 and PowerShell 7+ (Core).
</p>

<p align="center">
  <a href="https://github.com/visorcraft/MongrelDB-PowerShell/actions/workflows/ci.yml"><img src="https://github.com/visorcraft/MongrelDB-PowerShell/actions/workflows/ci.yml/badge.svg" alt="CI" /></a>
  <a href="https://github.com/visorcraft/MongrelDB/releases"><img src="https://img.shields.io/badge/server-v0.62.0-blue.svg" alt="MongrelDB server" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| PowerShell module | `MongrelDB` | `Import-Module ./src/MongrelDB.psd1` |

## Requirements

- **Windows PowerShell 5.1** or **PowerShell 7+** (pwsh)
- The built-in `Invoke-WebRequest` / `Invoke-RestMethod` and `ConvertTo-Json` / `ConvertFrom-Json` cmdlets (no external modules required)
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `Add-MongrelDBRow`, `Set-MongrelDBRow` (insert-or-update on PK conflict), `Remove-MongrelDBRow` (by row id or primary key), with idempotency keys for safe retries.
- **Query builder** that pushes conditions down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality, learned-range, null checks, and FM-index full-text search. Conditions are AND-ed.
- **Idempotent batch transactions** - all operations staged locally and committed atomically with `Invoke-MongrelDBTransaction`, with the engine enforcing unique, foreign key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint via `Invoke-MongrelDBSql`: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, and multi-statement execution.
- **Schema management**: `New-MongrelDBTable` (typed table creation with enum and default constraints), `Get-MongrelDBSchema` (full catalog), and `Get-MongrelDBSchemaFor` (per-table descriptor).
- **PowerShell-native naming**: all functions use approved Verb-Noun verbs (`New-`, `Get-`, `Set-`, `Add-`, `Remove-`, `Invoke-`, `Connect-`).
- **Typed exceptions**: failures throw an exception carrying a `Category` note property (`Auth`, `NotFound`, `Conflict`, `Query`, `Network`) so you can catch by category.

## Examples

Runnable, commented examples live in the docs:

- [Quickstart](docs/quickstart.md) - install, start the daemon, write and run a complete script.
- [Transactions](docs/transactions.md) - batch commits, idempotency keys, constraint handling.
- [Queries](docs/queries.md) - every native condition type and the index it pushes down to.
- [SQL](docs/sql.md) - recursive CTEs, window functions, advanced SQL.
- [Authentication](docs/auth.md) - bearer token, HTTP Basic, and open modes.
- [Errors](docs/errors.md) - error categories, the HTTP-status mapping, and recovery patterns.

## Quick Example

```powershell
Import-Module ./src/MongrelDB.psd1

Connect-MongrelDB -Url 'http://127.0.0.1:8453'

# Create a table.
$cols = @(
    @{ id = 1; name = 'id';       ty = 'int64';   primary_key = $true;  nullable = $false },
    @{ id = 2; name = 'customer'; ty = 'varchar'; primary_key = $false; nullable = $false },
    @{ id = 3; name = 'amount';   ty = 'float64'; primary_key = $false; nullable = $false }
)
$constraints = @{
    checks = @(@{ id = 1; name = 'ck_status'; expr = @{ IsNotNull = 3 } })
}
New-MongrelDBTable -Name 'orders' -Columns $cols -Constraints $constraints

# Insert rows (cells map column id to value).
Add-MongrelDBRow -Table 'orders' -Cells @{ 1 = 1; 2 = 'Alice'; 3 = 99.50 }
Add-MongrelDBRow -Table 'orders' -Cells @{ 1 = 2; 2 = 'Bob'; 3 = 150.00 }

# Query with a native index condition (learned-range index).
$cond = New-MongrelDBCondition -Kind range_f64 -ColumnId 3 -Lo 100.0 -LoSet
$res = Invoke-MongrelDBQuery -Table 'orders' -Conditions $cond -Limit 100
Write-Host "rows: $($res.Rows.Count)"

Write-Host "count: $(Get-MongrelDBCount -Table 'orders')"  # 2

# Run SQL.
Invoke-MongrelDBSql -Sql "UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'"
```

## Authentication

```powershell
# Bearer token (--auth-token mode)
Connect-MongrelDB -Url 'http://127.0.0.1:8453' -Token 'my-secret-token'

# HTTP Basic (--auth-users mode)
Connect-MongrelDB -Url 'http://127.0.0.1:8453' -Username 'admin' -Password 's3cret'
```

A token takes precedence over basic auth if both are supplied.

## Batch transactions

Operations are staged locally and committed atomically. The engine enforces
unique, foreign key, and check constraints at commit time.

```powershell
$ops = @(
    @{ put = @{ table = 'orders'; cells = @(1, 10, 2, 'Dave', 3, 50.0); returning = $false } },
    @{ put = @{ table = 'orders'; cells = @(1, 11, 2, 'Eve', 3, 75.0); returning = $false } },
    @{ delete_by_pk = @{ table = 'orders'; pk = 2 } }
)

# Atomic - all or nothing. The idempotency key makes it safe to retry.
try {
    Invoke-MongrelDBTransaction -Ops $ops -IdempotencyKey 'batch-1'
} catch {
    if ($_.Exception.Category -eq 'Conflict') {
        Write-Host "constraint violated: $($_.Exception.Message)"
    }
}
```

## Native query builder

Conditions push down to the engine's specialized indexes. Build them with
`New-MongrelDBCondition`; multiple conditions are AND-ed.

```powershell
# Bitmap equality (low-cardinality columns)
$bitmap = New-MongrelDBCondition -Kind bitmap_eq -ColumnId 2 -Value 'Alice'

# Range query (learned-range index)
$range = New-MongrelDBCondition -Kind range_f64 -ColumnId 3 -Lo 50.0 -LoSet -Hi 150.0 -HiSet

$res = Invoke-MongrelDBQuery -Table 'orders' -Conditions @($bitmap, $range) `
        -Projection @(1, 3) -Limit 100
if ($res.Truncated) {
    # result set hit the limit; more matches exist on the server
}
```

## Schema constraints

Two optional fields on a column hashtable let you constrain what goes into a
column at create time. Both are omitted from the wire JSON when left unset, so
existing schemas are unaffected.

```powershell
# An enum column whose values must come from this fixed set.
# Wire emit: "enum_variants": ["active","inactive","paused"]
$cols = @(
    @{ id = 1; name = 'id';     ty = 'int64';   primary_key = $true;  nullable = $false },
    @{ id = 2; name = 'customer'; ty = 'varchar'; primary_key = $false; nullable = $false },
    @{ id = 3; name = 'status'; ty = 'enum'; primary_key = $false; nullable = $false;
       enum_variants = @('active','inactive','paused'); default_value = 'active' }
)
New-MongrelDBTable -Name 'orders' -Columns $cols
```

`enum_variants` is an array of strings; omitting it means "absent".
`default_value` is any JSON scalar; supply the column's expected type. An
explicit `$null` stays a static null, a missing key means no default, and
literal `"now"` / `"uuid"` strings in `default_value` are static — use
`default_expr = 'now'` or `'uuid'` for a dynamic default. The constraint is
enforced server-side, so a row whose value falls outside the listed variants
surfaces as a `Conflict` exception on `Add-MongrelDBRow` /
`Invoke-MongrelDBTransaction`.
Table checks use the daemon's `constraints.checks` JSON shape and are forwarded
unchanged through `-Constraints`.

All supported static-default shapes pass through with their original JSON types:

```powershell
$cols = @(
    @{ id = 1; name = 'message'; ty = 'varchar'; primary_key = $false; nullable = $false; default_value = 'none' },
    @{ id = 2; name = 'count';   ty = 'int64';   primary_key = $false; nullable = $false; default_value = 0 },
    @{ id = 3; name = 'active';  ty = 'bool';    primary_key = $false; nullable = $false; default_value = $true },
    @{ id = 4; name = 'extra';   ty = 'varchar'; primary_key = $false; nullable = $true;  default_value = $null },
    @{ id = 5; name = 'tag';     ty = 'varchar'; primary_key = $false; nullable = $false; default_value = 'now' },
    @{ id = 6; name = 'created'; ty = 'timestamp'; primary_key = $false; nullable = $false; default_expr = 'now' }
)
New-MongrelDBTable -Name 'events' -Columns $cols
```

## SQL

```powershell
Invoke-MongrelDBSql -Sql "INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)"
Invoke-MongrelDBSql -Sql "CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500"

# Recursive CTEs and window functions
Invoke-MongrelDBSql -Sql "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r"
Invoke-MongrelDBSql -Sql "SELECT id, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) FROM orders"
```

## Error handling

Methods throw an exception on failure. Inspect `Category` to branch on the
category of failure.

```powershell
try {
    Get-MongrelDBSchemaFor -Table 'missing_table'
} catch {
    switch ($_.Exception.Category) {
        'NotFound'  { Write-Host "not found: $($_.Exception.Message)" }
        'Conflict'  { Write-Host "constraint: $($_.Exception.Message)" }
        'Auth'      { Write-Host "not authorized: $($_.Exception.Message)" }
        'Network'   { Write-Host "can't reach daemon: $($_.Exception.Message)" }
        default     { Write-Host "error: $($_.Exception.Message)" }
    }
}
```

## API reference

### Client lifecycle

| Function | Description |
|----------|-------------|
| `Connect-MongrelDB` | Construct the default client (omitted url defaults to `http://127.0.0.1:8453`) |
| `Disconnect-MongrelDB` | Clear the default client |

### Database operations

| Function | Description |
|----------|-------------|
| `Get-MongrelDBHealth` | Check daemon health |
| `Get-MongrelDBHistoryRetention` | Get the history-retention window and earliest retained epoch |
| `Get-MongrelDBEarliestRetainedEpoch` | Get the oldest epoch still queryable with `AS OF EPOCH` |
| `Set-MongrelDBHistoryRetention` | Set the history-retention window; requires admin |
| `Get-MongrelDBTable` | List table names |
| `New-MongrelDBTable -Indexes ...` | Create a table with optional constraints and all index definitions |
| `Remove-MongrelDBTable` | Drop a table |
| `Get-MongrelDBCount` | Row count |
| `Add-MongrelDBRow` | Insert a row |
| `Set-MongrelDBRow` | Upsert a row |
| `Remove-MongrelDBRow` | Delete by row id or primary key |
| `Invoke-MongrelDBTransaction` | Commit a batch atomically |
| `Invoke-MongrelDBQuery -Limit N -Offset N` | Run a paged native query |
| `New-MongrelDBCondition -Kind name -Parameters map` | Build any condition, including ANN, sparse, and MinHash |
| `Invoke-MongrelDBSql` | Execute SQL |
| `Get-MongrelDBSchema` | Full schema catalog |
| `Get-MongrelDBSchemaFor` | Single-table descriptor |

## Building and testing

```sh
# Validate the module manifest
pwsh -Command "Test-ModuleManifest -Path src/MongrelDB.psd1"

# Run the offline wire-shape unit tests (no daemon needed)
pwsh -File tests/wire_shape_test.ps1

# Run the live integration suite. Set MONGRELDB_URL to use an already-running
# daemon. Tests self-skip when no daemon is reachable.
pwsh -File tests/live_test.ps1
```

Fetch a prebuilt server binary from the [MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.62.0/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change - the suite must stay green.
3. Keep the code pure PowerShell, no external module dependencies.
4. Use approved Verb-Noun verbs for all exported functions.

## History retention

History retention controls how far back `AS OF EPOCH` time-travel queries can
read. Use these functions with `mongreldb-server` 0.48.0+:

```powershell
$window   = (Get-MongrelDBHistoryRetention).history_retention_epochs
$earliest = Get-MongrelDBEarliestRetainedEpoch

# Increase the window. Requires admin auth. Increasing retention cannot restore
# history already pruned past the previous earliest epoch.
Set-MongrelDBHistoryRetention -Epochs ($window + 10)

# Query historical state.
$rows = Invoke-MongrelDBSql -Sql "SELECT id FROM orders AS OF EPOCH $earliest"
```

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
