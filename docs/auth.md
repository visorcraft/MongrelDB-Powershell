# Authentication & Authorization

A `mongreldb-server` daemon runs in one of three modes:

1. **Open** (default) - no auth required.
2. **Bearer token** (`--auth-token <TOKEN>`) - every request must carry an
   `Authorization: Bearer <TOKEN>` header.
3. **HTTP Basic** (`--auth-users`) - every request must carry an
   `Authorization: Basic <base64(user:pass)>` header.

The PowerShell module supports all three through `Connect-MongrelDB` parameters.
This guide shows each mode and how to manage users and roles via SQL when the
server is in Basic mode.

---

## Bearer token mode

Start the daemon with a token:

```sh
mongreldb-server --auth-token s3cret-token
```

Connect with `-Token`. The token is sent as `Authorization: Bearer ...` on every
request.

```powershell
Connect-MongrelDB -Url 'http://127.0.0.1:8453' -Token 's3cret-token'

if (-not (Get-MongrelDBHealth)) {
    # a 401/403 surfaces as an Auth exception
}
```

A missing or wrong token surfaces as an `Auth` exception (HTTP 401/403).

### Where the token comes from

Hard-coding secrets in source is bad practice. Read it from the environment:

```powershell
$token = $env:MONGRELDB_TOKEN
if (-not $token) { Write-Error 'MONGRELDB_TOKEN not set'; exit 1 }
Connect-MongrelDB -Token $token
```

## Basic auth mode

Connect with `-Username` / `-Password`:

```powershell
Connect-MongrelDB -Url 'http://127.0.0.1:8453' -Username 'admin' -Password 's3cret'
```

The module base64-encodes `username:password` and sets
`Authorization: Basic ...` on every request.

## Token takes precedence

A token takes precedence over basic auth. In practice you pass one or the
other to `Connect-MongrelDB`, but the rule holds if you ever layer them.

## User and role management via SQL

When the daemon is in Basic auth mode, users and roles live in the catalog and
are managed with SQL. Run these statements through `Invoke-MongrelDBSql`.

### Create a user

```powershell
Invoke-MongrelDBSql -Sql "CREATE USER alice WITH PASSWORD 'hunter2'"
```

### Alter a user

```powershell
Invoke-MongrelDBSql -Sql "ALTER USER alice WITH PASSWORD 'new-password'"
Invoke-MongrelDBSql -Sql "ALTER USER alice ADMIN"
```

`ALTER USER ... ADMIN` is how you promote a user to full administrative
privileges (table creation/drop, compaction, user management). Use it
sparingly.

### Drop a user

```powershell
Invoke-MongrelDBSql -Sql "DROP USER alice"
```

### Roles and grants

```powershell
Invoke-MongrelDBSql -Sql "CREATE ROLE analyst"
Invoke-MongrelDBSql -Sql "GRANT SELECT ON orders TO analyst"
Invoke-MongrelDBSql -Sql "GRANT analyst TO alice"
Invoke-MongrelDBSql -Sql "REVOKE SELECT ON orders FROM analyst"
Invoke-MongrelDBSql -Sql "DROP ROLE analyst"
```

## Common pitfalls

**Auth errors look like other errors without the category.** A 401/403 maps to
`Auth`; a 404 maps to `NotFound`. Always switch on the exception category
rather than string-matching the message.

**Forgetting to set auth in production.** A client built with plain
`Connect-MongrelDB` and no auth parameters sends no credentials. Against an
auth-enabled daemon, every call fails with `Auth`. Centralize the connection so
the auth parameters are never accidentally dropped.

**Token in version control.** Put secrets in the environment, a secret
manager, or a file outside the repo. Never commit a real token.

## Next steps

- [errors.md](errors.md) - the `Auth` category and the rest of the error codes
- [quickstart.md](quickstart.md) - the full end-to-end walkthrough
