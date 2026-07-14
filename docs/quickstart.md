# Quickstart

Zero to a running MongrelDB PowerShell program in ten minutes. This guide walks
through importing the module, starting the daemon, and writing, running, and
understanding a complete script.

---

## 1. Prerequisites

You need PowerShell and a `mongreldb-server` daemon.

### Install PowerShell

On Windows, Windows PowerShell 5.1 ships with the OS. For PowerShell 7+
(`pwsh`) install from [Microsoft](https://learn.microsoft.com/powershell/).

On Linux/macOS:

```sh
# Debian/Ubuntu
sudo apt install powershell
# macOS
brew install --cask powershell
```

Verify:

```sh
pwsh --version
```

### Install mongreldb-server

Fetch a prebuilt server binary from the
[MongrelDB releases](https://github.com/visorcraft/MongrelDB/releases):

```sh
mkdir -p bin
curl -fsSL -o bin/mongreldb-server \
  https://github.com/visorcraft/MongrelDB/releases/download/v0.53.3/mongreldb-server-linux-x64
chmod +x bin/mongreldb-server
```

Verify it runs:

```sh
./bin/mongreldb-server --version
```

## 2. Start the daemon

By default `mongreldb-server` listens on `http://127.0.0.1:8453` and stores
data in the directory you pass as its first argument.

```sh
mkdir -p /tmp/mdb-data
/path/to/mongreldb-server /tmp/mdb-data
```

In another terminal, sanity-check it:

```sh
curl http://127.0.0.1:8453/health
# ok
```

## 3. Import the module

```powershell
Import-Module ./src/MongrelDB.psd1
Connect-MongrelDB -Url 'http://127.0.0.1:8453'
```

## 4. Write your first script

Create `demo.ps1`:

```powershell
Import-Module ./src/MongrelDB.psd1
$ErrorActionPreference = 'Stop'

# 1. Connect to the daemon.
Connect-MongrelDB -Url 'http://127.0.0.1:8453'

# 2. Health check before doing anything else.
if (-not (Get-MongrelDBHealth)) {
    Write-Error 'daemon not reachable'
    exit 1
}

# 3. Create a table. Two optional fields extend the schema:
#    - enum_variants: a fixed set of allowed values for a text column
#      (server-enforced on commit).
#    - default_value: a JSON scalar applied when a row omits the column.
$cols = @(
    @{ id = 1; name = 'id';       ty = 'int64';   primary_key = $true;  nullable = $false },
    @{ id = 2; name = 'customer'; ty = 'varchar'; primary_key = $false; nullable = $false },
    @{ id = 3; name = 'amount';   ty = 'float64'; primary_key = $false; nullable = $false; default_value = 0.0 },
    @{ id = 4; name = 'status';   ty = 'varchar'; primary_key = $false; nullable = $false;
       enum_variants = @('active','inactive','paused'); default_value = 'active' }
)
New-MongrelDBTable -Name 'orders' -Columns $cols

# 4. Insert rows. The status column is constrained to the enum set.
Add-MongrelDBRow -Table 'orders' -Cells @{ 1 = 1; 2 = 'Alice'; 3 = 99.5; 4 = 'active' }
Add-MongrelDBRow -Table 'orders' -Cells @{ 1 = 2; 2 = 'Bob'; 3 = 150.0; 4 = 'inactive' }

# 5. Query with a native index condition. Projection selects column ids 1,2.
$cond = New-MongrelDBCondition -Kind range_f64 -ColumnId 3 -Lo 100.0 -LoSet
$res = Invoke-MongrelDBQuery -Table 'orders' -Conditions $cond -Projection @(1, 2) -Limit 100
Write-Host "rows: $($res.Rows.Count)"

# 6. Count the rows.
Write-Host "total rows: $(Get-MongrelDBCount -Table 'orders')"
```

Run it:

```sh
pwsh -File demo.ps1
```

You should see the row count of 2.

## 5. What each part does

| Code | What it does |
|------|--------------|
| `Connect-MongrelDB` | Sets the module-scoped default client targeting one daemon. |
| `Get-MongrelDBHealth` | GET `/health`; returns `$true` when the daemon answers. |
| `New-MongrelDBTable` | POST `/kit/create_table`. Column `id`s are the on-wire identifiers. |
| `enum_variants` | Optional. Constrains a text column to a fixed value set; server-enforced on commit, surfaces as a `Conflict` exception. Omit = absent. |
| `default_value` | Optional JSON scalar. Supply the type expected by the column. Omit = absent. |
| `default_expr` | Optional dynamic `now` or `uuid` default. |
| `Add-MongrelDBRow` | Single-op transaction: POST `/kit/txn` with one `put` op. `cells` is flattened to `[col_id, val, ...]`. |
| `Invoke-MongrelDBQuery` | Builds a `/kit/query` body. Conditions push down to native indexes. |
| `-Projection @(1,2)` | Server returns only those column ids, saving bandwidth. |
| `-Limit 100` | Caps the result; check the `Truncated` property afterward. |
| `Get-MongrelDBCount` | GET `/tables/{name}/count`. |

## 6. Static defaults and history retention

`default_value` can be any JSON scalar. Explicit `$null` stays a static null, a
missing key means no default, and literal `"now"` / `"uuid"` strings are static
— use `default_expr` for dynamic `now` / `uuid` defaults:

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

History retention controls how far back `AS OF EPOCH` queries can read:

```powershell
$window   = (Get-MongrelDBHistoryRetention).history_retention_epochs
$earliest = Get-MongrelDBEarliestRetainedEpoch

Set-MongrelDBHistoryRetention -Epochs ($window + 10)
$rows = Invoke-MongrelDBSql -Sql "SELECT id FROM orders AS OF EPOCH $earliest"
```

## 7. Common pitfalls

**Using the column name instead of the column id.** Every on-wire API uses the
numeric `id` from `New-MongrelDBTable`, never the `name`. Conditions take the
numeric `ColumnId`, not the string name.

**Treating a single `Add-MongrelDBRow` as non-transactional.** `put` is a one-op
transaction. A unique constraint violation surfaces as a `Conflict` exception
(HTTP 409), not as a silent no-op.

**Expecting `Invoke-MongrelDBSql` to always return rows.** The `/sql` endpoint
streams Arrow IPC for `SELECT` in most builds, so `Invoke-MongrelDBSql` returns
the decoded JSON when the server honors `format:json`, or `$null` for non-JSON
bodies. Use it for DDL/DML and statements whose success is the signal.

**Pointing at a daemon that requires auth.** If the daemon was started with
`--auth-token` or `--auth-users`, every call fails with an `Auth` exception
unless you use `-Token` or `-Username`/`-Password`. See [auth.md](auth.md).

**Assuming `enum_variants` is checked client-side.** The PowerShell module only
emits the constraint in the wire JSON; the engine enforces it on `put` /
`commit` and throws a `Conflict` exception for any value outside the set.

## Next steps

- [transactions.md](transactions.md) - atomic batches, idempotency, retries
- [queries.md](queries.md) - every native index condition
- [sql.md](sql.md) - recursive CTEs, window functions, `CREATE TABLE AS SELECT`
- [auth.md](auth.md) - bearer tokens, basic auth, user/role management
- [errors.md](errors.md) - the full error category set and recovery patterns
