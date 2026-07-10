# SQL

MongrelDB ships a DataFusion-backed SQL engine at `POST /sql`. From PowerShell,
run SQL with `Invoke-MongrelDBSql`:

```powershell
Invoke-MongrelDBSql -Sql 'SELECT 1'
```

This guide covers the SQL surface - DDL, DML, `CREATE TABLE AS SELECT`,
recursive CTEs, and window functions - and when to reach for SQL versus the
native query builder.

---

## How `Invoke-MongrelDBSql` behaves

`Invoke-MongrelDBSql` sends `{"sql": "...", "format": "json"}` to `/sql`. It
returns the decoded JSON body on a 2xx response, or throws on failure.

In practice:

- **DDL and DML** (`CREATE TABLE`, `INSERT`, `UPDATE`, `DELETE`) reply with a
  non-JSON status body. `Invoke-MongrelDBSql` returns `$null` - success is the
  signal.
- **`SELECT`** in most daemon builds streams Arrow IPC bytes rather than JSON,
  but with `format:json` requested the server returns a JSON array of row
  objects keyed by column name when supported.

Errors are mapped to the same error categories as everything else: an HTTP 400
or 5xx is `Query`; 409 is `Conflict`; and so on. See [errors.md](errors.md).

```powershell
try {
    Invoke-MongrelDBSql -Sql "INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)"
} catch {
    if ($_.Exception.Category -eq 'Conflict') {
        Write-Host "duplicate row: $($_.Exception.Message)"
    }
}
```

## CREATE TABLE

```powershell
Invoke-MongrelDBSql -Sql "CREATE TABLE products (id INT64 PRIMARY KEY, name VARCHAR, price FLOAT64, category VARCHAR, in_stock BOOLEAN)"
```

## INSERT

```powershell
Invoke-MongrelDBSql -Sql "INSERT INTO products (id, name, price, category, in_stock) VALUES (1, 'Widget', 9.99, 'tools', true)"
```

For bulk inserts, the native batch transaction (`Invoke-MongrelDBTransaction`)
is usually faster because it stages ops in one round trip without re-parsing
SQL.

## UPDATE / DELETE

```powershell
Invoke-MongrelDBSql -Sql "UPDATE products SET price = 14.99 WHERE id = 1"
Invoke-MongrelDBSql -Sql "DELETE FROM products WHERE in_stock = false"
```

## SELECT

```powershell
$rows = Invoke-MongrelDBSql -Sql "SELECT id, name FROM products WHERE category = 'tools' ORDER BY price"
```

## CREATE TABLE AS SELECT

Materialize a query result into a new table. Great for snapshots, rollups, and
denormalized aggregates.

```powershell
Invoke-MongrelDBSql -Sql "CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500"

# Roll up sales by customer.
Invoke-MongrelDBSql -Sql "CREATE TABLE sales_by_customer AS SELECT customer, SUM(amount) AS total FROM orders GROUP BY customer"
```

## Recursive CTEs

`WITH RECURSIVE` is fully supported. Classic use cases: series generation,
hierarchy/graph traversal.

```powershell
Invoke-MongrelDBSql -Sql "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 10) SELECT n FROM r"
```

## Window functions

```powershell
Invoke-MongrelDBSql -Sql "SELECT id, customer, amount, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) AS rn FROM orders"
```

`RANK()`, `DENSE_RANK()`, `LAG()`, `LEAD()`, `NTILE()`, and the usual
window-frame clauses are available through DataFusion.

## When to use SQL vs. the query builder

| Reach for | When |
|-----------|------|
| **`Invoke-MongrelDBQuery`** | Point lookups, range scans, bitmap filters, and full-text that map to a native index. Sub-millisecond, no parser overhead, and rows decode into typed values directly. |
| **SQL** | DDL, multi-statement setup, joins, recursive CTEs, window functions, and arbitrary aggregates. |

## Next steps

- [queries.md](queries.md) - every native index condition in detail
- [transactions.md](transactions.md) - bulk inserts via batch transactions
- [errors.md](errors.md) - handling SQL execution errors
