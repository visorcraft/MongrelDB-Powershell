<#
.SYNOPSIS
    Live integration tests for the MongrelDB PowerShell client.

.DESCRIPTION
    These exercise the full client surface against a running mongreldb-server
    daemon. They self-skip (print SKIP and pass) when no daemon is reachable.

    Point at an already-running daemon with the MONGRELDB_URL environment
    variable. By default this connects to http://127.0.0.1:8453.

    The 14-operation conformance matrix mirrors the other official clients:
    health, create_table, drop_table, count, put, upsert, delete (by row id),
    delete_by_pk, query (pk), query (range), transaction (batch commit),
    table_names, schema, schema_for, sql, idempotency_key, error not_found.

.LICENSE
    MIT OR Apache-2.0.
#>

[CmdletBinding()]
param(
    [string]$TestUrl
)

$ErrorActionPreference = 'Stop'
$Pass = 0
$Fail = 0
$Skip = 0
$Current = ''

# Import the module from the repo src/ directory.
$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src' 'MongrelDB.psd1') -Force

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
    $script:Current = $Name
    Write-Host "== $Name"
    $before = $script:Fail
    try {
        & $Body
    } catch {
        Write-Host ("  FAIL " + $_.InvocationInfo.ScriptLineNumber + ": " + $_.Exception.Message)
        $script:Fail++
    }
    if ($script:Fail -eq $before) { $script:Pass++ }
}

function Fail-Test {
    param([string]$Message)
    Write-Host "  FAIL: $Message"
    $script:Fail++
    throw 'test-abort'
}

function Skip-Test {
    param([string]$Reason = '(no daemon)')
    Write-Host "  SKIP: $Reason"
    $script:Skip++
    throw 'test-skip'
}

# ── Daemon harness ────────────────────────────────────────────────────────

$HaveDaemon = $false

$url = $TestUrl
if (-not $url) { $url = $env:MONGRELDB_URL }
if (-not $url) { $url = 'http://127.0.0.1:8453' }

try {
    $c = Connect-MongrelDB -Url $url -PassThru
    if (Get-MongrelDBHealth -Client $c) {
        $script:HaveDaemon = $true
    }
} catch {
    $script:HaveDaemon = $false
}

if (-not $HaveDaemon) {
    Write-Host "--- no mongreldb-server reachable at $url; live tests skipped"
}

# A persistent client used across all tests.
$global:DBC = if ($HaveDaemon) { $c } else { $null }

function Assert-Daemon {
    if (-not $script:HaveDaemon) { Skip-Test 'no mongreldb-server available' }
}

# ── Helpers ───────────────────────────────────────────────────────────────

function New-IntCol {
    param([long]$Id, [string]$Name, [bool]$Pk)
    return @{ id = $Id; name = $Name; ty = 'int64'; primary_key = $Pk; nullable = (-not $Pk) }
}
function New-FloatCol {
    param([long]$Id, [string]$Name)
    return @{ id = $Id; name = $Name; ty = 'float64'; primary_key = $false; nullable = $false }
}
function New-VarcharCol {
    param([long]$Id, [string]$Name)
    return @{ id = $Id; name = $Name; ty = 'varchar'; primary_key = $false; nullable = $false }
}

# Drop-then-create so a fresh table is ready for the test.
function New-FreshTable {
    param([string]$Name, $Cols)
    try { Remove-MongrelDBTable -Name $Name -Client $script:DBC } catch {}
    $tid = New-MongrelDBTable -Name $Name -Columns $Cols -Client $script:DBC
    if ($LASTEXITCODE) { Fail-Test "create_table $Name failed" }
    return $tid
}

# ── Tests (14-operation conformance matrix) ───────────────────────────────

# 1. health
Invoke-Test 'test_health' {
    Assert-Daemon
    $ok = Get-MongrelDBHealth -Client $script:DBC
    if (-not $ok) { Fail-Test 'health failed' }
}

# 2. create_table + count
Invoke-Test 'test_create_table_and_count' {
    Assert-Daemon
    $cols = @( (New-IntCol 1 'id' $true), (New-FloatCol 2 'amount') )
    New-FreshTable 'ps_tbl_count' $cols
    $n = Get-MongrelDBCount -Table 'ps_tbl_count' -Client $script:DBC
    if ($n -ne 0) { Fail-Test "expected 0 rows, got $n" }
}

# 3. put + count
Invoke-Test 'test_put_and_count' {
    Assert-Daemon
    $cols = @( (New-IntCol 1 'id' $true), (New-FloatCol 2 'amount') )
    New-FreshTable 'ps_put' $cols
    Add-MongrelDBRow -Table 'ps_put' -Cells @{ 1 = 1; 2 = 99.5 } -Client $script:DBC
    Add-MongrelDBRow -Table 'ps_put' -Cells @{ 1 = 2; 2 = 150.0 } -Client $script:DBC
    $n = Get-MongrelDBCount -Table 'ps_put' -Client $script:DBC
    if ($n -ne 2) { Fail-Test "expected 2 rows, got $n" }
}

# 4. upsert (update on conflict)
Invoke-Test 'test_upsert' {
    Assert-Daemon
    $cols = @( (New-IntCol 1 'id' $true), (New-FloatCol 2 'amount') )
    New-FreshTable 'ps_upsert' $cols
    Add-MongrelDBRow -Table 'ps_upsert' -Cells @{ 1 = 1; 2 = 10.0 } -Client $script:DBC
    Set-MongrelDBRow -Table 'ps_upsert' -Cells @{ 1 = 1; 2 = 20.0 } -UpdateCells @{ 2 = 20.0 } -Client $script:DBC
    $n = Get-MongrelDBCount -Table 'ps_upsert' -Client $script:DBC
    if ($n -ne 1) { Fail-Test "expected 1 row after upsert, got $n" }

    # Query back and verify the updated value.
    $cond = New-MongrelDBCondition -Kind pk -Value 1
    $res = Invoke-MongrelDBQuery -Table 'ps_upsert' -Conditions $cond -Client $script:DBC
    if ($res.Rows.Count -ne 1) { Fail-Test "expected 1 row from pk query, got $($res.Rows.Count)" }
    $amt = [double]$res.Rows[0].'2'
    if ($amt -ne 20.0) { Fail-Test "expected updated amount 20.0, got $amt" }
}

# 5. query by primary key
Invoke-Test 'test_query_by_pk' {
    Assert-Daemon
    $cols = @( (New-IntCol 1 'id' $true) )
    New-FreshTable 'ps_pk' $cols
    Add-MongrelDBRow -Table 'ps_pk' -Cells @{ 1 = 42 } -Client $script:DBC
    Add-MongrelDBRow -Table 'ps_pk' -Cells @{ 1 = 43 } -Client $script:DBC
    $cond = New-MongrelDBCondition -Kind pk -Value 42
    $res = Invoke-MongrelDBQuery -Table 'ps_pk' -Conditions $cond -Client $script:DBC
    if ($res.Rows.Count -ne 1) { Fail-Test "expected 1 row, got $($res.Rows.Count)" }
}

# 6. query by range
Invoke-Test 'test_query_range' {
    Assert-Daemon
    $cols = @( (New-IntCol 1 'id' $true), (New-FloatCol 2 'amount' $false) )
    New-FreshTable 'ps_range' $cols
    Add-MongrelDBRow -Table 'ps_range' -Cells @{ 1 = 1; 2 = 50.0 } -Client $script:DBC
    Add-MongrelDBRow -Table 'ps_range' -Cells @{ 1 = 2; 2 = 120.0 } -Client $script:DBC
    Add-MongrelDBRow -Table 'ps_range' -Cells @{ 1 = 3; 2 = 200.0 } -Client $script:DBC
    # Column 2 is float64, so use range_f64 (range targets integer columns).
    $cond = New-MongrelDBCondition -Kind range_f64 -ColumnId 2 -Lo 100.0 -Hi 150.0 -LoSet -HiSet -LoInclusive -HiInclusive
    $res = Invoke-MongrelDBQuery -Table 'ps_range' -Conditions $cond -Client $script:DBC
    if ($res.Rows.Count -ne 1) { Fail-Test "expected exactly 1 matching row, got $($res.Rows.Count)" }
    if ($res.Truncated) { Fail-Test 'result should not be truncated' }
}

# 7. transaction (batch commit)
Invoke-Test 'test_transaction_commit' {
    Assert-Daemon
    $cols = @( (New-IntCol 1 'id' $true) )
    New-FreshTable 'ps_txn' $cols
    $ops = @(
        @{ put = @{ table = 'ps_txn'; cells = @(1, 1); returning = $false } },
        @{ put = @{ table = 'ps_txn'; cells = @(1, 2); returning = $false } },
        @{ put = @{ table = 'ps_txn'; cells = @(1, 3); returning = $false } }
    )
    Invoke-MongrelDBTransaction -Ops $ops -Client $script:DBC
    $n = Get-MongrelDBCount -Table 'ps_txn' -Client $script:DBC
    if ($n -ne 3) { Fail-Test "expected 3 rows after commit, got $n" }
}

# 8. delete_by_pk
Invoke-Test 'test_delete_by_pk' {
    Assert-Daemon
    $cols = @( (New-IntCol 1 'id' $true) )
    New-FreshTable 'ps_del' $cols
    Add-MongrelDBRow -Table 'ps_del' -Cells @{ 1 = 5 } -Client $script:DBC
    $n = Get-MongrelDBCount -Table 'ps_del' -Client $script:DBC
    if ($n -ne 1) { Fail-Test "expected 1 row, got $n" }
    Remove-MongrelDBRow -Table 'ps_del' -PrimaryKeyValue 5 -Client $script:DBC
    $n = Get-MongrelDBCount -Table 'ps_del' -Client $script:DBC
    if ($n -ne 0) { Fail-Test "expected 0 rows after delete, got $n" }
}

# 9. delete by row id
Invoke-Test 'test_delete_by_row_id' {
    Assert-Daemon
    $cols = @( (New-IntCol 1 'id' $true) )
    New-FreshTable 'ps_delrow' $cols
    Add-MongrelDBRow -Table 'ps_delrow' -Cells @{ 1 = 7 } -Client $script:DBC
    # First inserted row on a fresh table has internal row_id 1.
    Remove-MongrelDBRow -Table 'ps_delrow' -RowId 1 -Client $script:DBC
    $n = Get-MongrelDBCount -Table 'ps_delrow' -Client $script:DBC
    if ($n -ne 0) { Fail-Test "expected 0 rows after delete by row id, got $n" }
}

# 10. string values round-trip
Invoke-Test 'test_string_values' {
    Assert-Daemon
    $cols = @( (New-IntCol 1 'id' $true), (New-VarcharCol 2 'label'), (New-FloatCol 3 'amount') )
    New-FreshTable 'ps_str' $cols
    Add-MongrelDBRow -Table 'ps_str' -Cells @{ 1 = 1; 2 = 'hello world'; 3 = 1.5 } -Client $script:DBC
    $cond = New-MongrelDBCondition -Kind pk -Value 1
    $res = Invoke-MongrelDBQuery -Table 'ps_str' -Conditions $cond -Client $script:DBC
    if ($res.Rows.Count -ne 1) { Fail-Test "expected 1 row, got $($res.Rows.Count)" }
    $label = [string]$res.Rows[0].'2'
    if ($label -ne 'hello world') { Fail-Test "expected label 'hello world', got $label" }
}

# 11. sql
Invoke-Test 'test_sql' {
    Assert-Daemon
    $cols = @( (New-IntCol 1 'id' $true), (New-IntCol 2 'amount' $false) )
    New-FreshTable 'ps_sql' $cols
    $n = Get-MongrelDBCount -Table 'ps_sql' -Client $script:DBC
    if ($n -ne 0) { Fail-Test "expected 0 rows before SQL INSERT, got $n" }
    Invoke-MongrelDBSql -Sql "INSERT INTO ps_sql (id, amount) VALUES (10, 42)" -Client $script:DBC | Out-Null
    $n = Get-MongrelDBCount -Table 'ps_sql' -Client $script:DBC
    if ($n -ne 1) { Fail-Test "expected count to increase to 1 after INSERT, got $n" }
}

# 12. table_names
Invoke-Test 'test_table_names' {
    Assert-Daemon
    $cols = @( (New-IntCol 1 'id' $true) )
    New-FreshTable 'ps_tables' $cols
    $names = Get-MongrelDBTable -Client $script:DBC
    $found = $false
    foreach ($name in $names) {
        if ($name -eq 'ps_tables') { $found = $true; break }
    }
    if (-not $found) { Fail-Test 'table list missing ps_tables' }
}

# 13. schema + schema_for
Invoke-Test 'test_schema_for' {
    Assert-Daemon
    $cols = @( (New-IntCol 1 'id' $true), (New-FloatCol 2 'amount') )
    New-FreshTable 'ps_schema' $cols
    $body = Get-MongrelDBSchemaFor -Table 'ps_schema' -Client $script:DBC
    if (-not $body) { Fail-Test 'expected non-empty schema body' }
}

# 14. error not_found
Invoke-Test 'test_error_not_found' {
    Assert-Daemon
    try {
        Get-MongrelDBSchemaFor -Table 'ps_does_not_exist_xyz' -Client $script:DBC | Out-Null
        Fail-Test 'expected an error for missing table'
    } catch {
        $cat = $_.Exception.Category
        if ($cat -ne 'NotFound') { Fail-Test "expected NotFound, got $cat" }
    }
}

# 15. idempotency key
Invoke-Test 'test_idempotency_key' {
    Assert-Daemon
    $cols = @( (New-IntCol 1 'id' $true) )
    New-FreshTable 'ps_idem' $cols
    # Use a unique idempotency key per run so prior test runs on the same server
    # don't replay stale results.
    $key = "idem-key-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    Add-MongrelDBRow -Table 'ps_idem' -Cells @{ 1 = 1 } -IdempotencyKey $key -Client $script:DBC
    $n = Get-MongrelDBCount -Table 'ps_idem' -Client $script:DBC
    if ($n -ne 1) { Fail-Test "expected 1 row, got $n" }
    # Second put with a DIFFERENT value but the SAME key replays the original
    # result; the row count stays at 1.
    try {
        Add-MongrelDBRow -Table 'ps_idem' -Cells @{ 1 = 2 } -IdempotencyKey $key -Client $script:DBC | Out-Null
    } catch {}
    $n = Get-MongrelDBCount -Table 'ps_idem' -Client $script:DBC
    if ($n -ne 1) { Fail-Test "expected 1 row after duplicate idempotent commit, got $n" }
}

Write-Host ""
Write-Host "$Pass passed, $Fail failed, $Skip skipped"
if ($Fail -gt 0) { exit 1 } else { exit 0 }
