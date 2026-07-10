# Queries

The `Invoke-MongrelDBQuery` cmdlet pushes conditions down to MongrelDB's native
indexes for sub-millisecond lookups - bitmap, learned-range, FM-index full
text, and more. Each condition type maps to one specialized index; conditions
are AND-ed together.

```powershell
$cond = New-MongrelDBCondition -Kind range -ColumnId 3 -Lo 100.0 -LoSet -Hi 500.0 -HiSet
$res = Invoke-MongrelDBQuery -Table 'orders' -Conditions $cond -Projection @(1, 2) -Limit 100
```

This guide covers every condition type, projection, limits and truncation, and
combining conditions.

---

## The basics

Every query call takes the table, an array of conditions, a projection, a
limit, and returns a hashtable with `Rows` and `Truncated`:

| Parameter | Purpose |
|-----------|---------|
| `-Conditions` (or omit) | An array of native conditions. All are AND-ed. |
| `-Projection` (or omit) | Return only these column ids (omit for all columns). |
| `-Limit` (or 0) | Cap the number of rows. |
| Returns `.Rows` / `.Truncated` | The rows array and a bool set when the limit was hit. |

The request body the client builds matches the daemon's `/kit/query` shape:

```json
{
  "table": "orders",
  "conditions": [{"range": {"column_id": 3, "lo": 100.0, "hi": 500.0}}],
  "projection": [1, 2],
  "limit": 100
}
```

Each returned row is a PSCustomObject with properties named by column id.

## Condition types

Build conditions with `New-MongrelDBCondition`. Column references use the
numeric **column id**, never the column name.

### `pk` - exact primary-key match

The fastest lookup. Supply the primary-key value via `-Value`.

```powershell
$cond = New-MongrelDBCondition -Kind pk -Value 42
$res = Invoke-MongrelDBQuery -Table 'orders' -Conditions $cond
```

### `range` - numeric range (learned-range index)

Inclusive bounds. Leave `-LoSet` / `-HiSet` off for an open end.

```powershell
$cond = New-MongrelDBCondition -Kind range -ColumnId 3 -Lo 100.0 -LoSet -Hi 500.0 -HiSet

# Open-ended: amount >= 100
$cond = New-MongrelDBCondition -Kind range -ColumnId 3 -Lo 100.0 -LoSet
```

### `bitmap_eq` - equality on a bitmap-indexed column

Best for low-cardinality columns (status, category, booleans).

```powershell
$cond = New-MongrelDBCondition -Kind bitmap_eq -ColumnId 2 -Value 'Alice'
```

### `is_null` / `is_not_null` - null checks

```powershell
$isNull = New-MongrelDBCondition -Kind is_null -ColumnId 3
$notNull = New-MongrelDBCondition -Kind is_not_null -ColumnId 3
```

### `fm_contains` - full-text substring search (FM-index)

Substring match within a column. The `-Value` becomes the on-wire `pattern`.

```powershell
$cond = New-MongrelDBCondition -Kind fm_contains -ColumnId 2 -Value 'database performance'
$res = Invoke-MongrelDBQuery -Table 'documents' -Conditions $cond -Limit 10
```

## Projection (column selection)

Pass a `-Projection` array to restrict the columns in each returned row. Omit
for all columns. Projecting to only the columns you need cuts bandwidth.

```powershell
$res = Invoke-MongrelDBQuery -Table 'orders' -Conditions $conds -Projection @(1, 2) -Limit 100
```

Returned cells are PSCustomObject properties; read them by column id:

```powershell
foreach ($row in $res.Rows) {
    $id = $row.'1'
    $amount = $row.'3'
    Write-Host "id=$id amount=$amount"
}
```

## Limit and the truncated flag

A non-zero `-Limit` caps the result. When the server has more matches than the
limit allows, it returns the first `limit` and sets `Truncated` to `$true`.

```powershell
$res = Invoke-MongrelDBQuery -Table 'orders' -Conditions $cond -Limit 100
if ($res.Truncated) {
    # 100 rows came back but more exist on the server.
}
```

## Multiple AND conditions

Pass an array of conditions. Every condition must match; the server intersects
the index results.

```powershell
$bitmap = New-MongrelDBCondition -Kind bitmap_eq -ColumnId 2 -Value 'Alice'
$range  = New-MongrelDBCondition -Kind range -ColumnId 3 -Lo 100.0 -LoSet -Hi 500.0 -HiSet
$res = Invoke-MongrelDBQuery -Table 'orders' -Conditions @($bitmap, $range) `
        -Projection @(1, 3) -Limit 50
```

For arbitrary predicates, joins, and aggregations that the native indexes do
not cover, use SQL instead - see [sql.md](sql.md).
