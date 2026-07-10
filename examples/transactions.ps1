<#
.SYNOPSIS
    Example: atomic batch transactions with an idempotent retry in PowerShell.

.DESCRIPTION
    Requires a mongreldb-server daemon running on http://127.0.0.1:8453, or
    point MONGRELDB_URL at a running daemon.

    Creates a table, stages three puts in one transaction, and commits them
    atomically. It then verifies the row count. Finally it stages a fourth put
    and commits it twice with the SAME idempotency key: the daemon replays the
    first commit's result so the second commit is a no-op. The table is dropped
    at the end (even on error).

.LICENSE
    MIT OR Apache-2.0.
#>

[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src' 'MongrelDB.psd1') -Force

$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$table = "ps_example_txn_$ts"
$txnKey = "ps-example-txn-key-$ts"

$url = $env:MONGRELDB_URL
if (-not $url) { $url = 'http://127.0.0.1:8453' }

$db = Connect-MongrelDB -Url $url -PassThru
$tableCreated = $false
$status = 1

# Build a put-op dict referencing the per-run table.
function New-PutOp {
    param([string]$Table, [array]$FlatRow)
    return @{ put = @{ table = $Table; cells = $FlatRow; returning = $false } }
}
# Flatten (id, name, score, status) into [colId, value, ...] with fixed ids 1..4.
function ConvertTo-FlatRow {
    param($Id, [string]$Name, $Score, [string]$Status)
    return @(1, $Id, 2, $Name, 3, $Score, 4, $Status)
}

try {
    if (-not (Get-MongrelDBHealth -Client $db)) { Write-Error "daemon not reachable at $url"; return 1 }
    Write-Host 'Connected to MongrelDB'

    $statusVariants = @('active','inactive','paused')
    $cols = @(
        @{ id = 1; name = 'id';     ty = 'int64';   primary_key = $true;  nullable = $false },
        @{ id = 2; name = 'name';   ty = 'varchar'; primary_key = $false; nullable = $false },
        @{ id = 3; name = 'score';  ty = 'float64'; primary_key = $false; nullable = $false; default_value = '0.0' },
        @{ id = 4; name = 'status'; ty = 'varchar'; primary_key = $false; nullable = $false; enum_variants = $statusVariants; default_value = 'active' }
    )
    $tid = New-MongrelDBTable -Name $table -Columns $cols -Client $db
    $tableCreated = $true
    Write-Host "Created table $table (id $tid)"

    # Stage three puts and commit them atomically.
    $batch1 = @(
        (New-PutOp $table (ConvertTo-FlatRow 1 'Alice' 95.5 'active')),
        (New-PutOp $table (ConvertTo-FlatRow 2 'Bob'   82.0 'inactive')),
        (New-PutOp $table (ConvertTo-FlatRow 3 'Carol' 78.3 'paused'))
    )
    Invoke-MongrelDBTransaction -Ops $batch1 -Client $db | Out-Null
    Write-Host 'Committed transaction with 3 puts'

    $n = Get-MongrelDBCount -Table $table -Client $db
    Write-Host "Total rows after commit: $n"

    # Idempotent retry: stage a fourth put and commit twice with the same key.
    $batch2 = @( (New-PutOp $table (ConvertTo-FlatRow 4 'Dave' 60.0 'active')) )
    Invoke-MongrelDBTransaction -Ops $batch2 -IdempotencyKey $txnKey -Client $db | Out-Null
    Write-Host "Committed 4th put with idempotency key $txnKey"

    Invoke-MongrelDBTransaction -Ops $batch2 -IdempotencyKey $txnKey -Client $db | Out-Null
    Write-Host 'Recommitted with same key (idempotent replay)'

    $n = Get-MongrelDBCount -Table $table -Client $db
    Write-Host "Total rows after idempotent retry: $n"

    $status = 0
} finally {
    if ($tableCreated) {
        try { Remove-MongrelDBTable -Name $table -Client $db; Write-Host "Dropped table $table" }
        catch { Write-Host "drop_table failed: $($_.Exception.Message)" }
    }
}
return $status
