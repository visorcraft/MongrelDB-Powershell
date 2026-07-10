<#
.SYNOPSIS
    Example: native query builder (range + primary-key lookups) in PowerShell.

.DESCRIPTION
    Requires a mongreldb-server daemon running on http://127.0.0.1:8453, or
    point MONGRELDB_URL at a running daemon.

    Creates a table, loads five rows with varying scores, then runs two native
    queries: a range scan over score in [60, 90], and an exact primary-key
    lookup for id == 4. Results are printed, then the table is dropped
    (even on error).

.LICENSE
    MIT OR Apache-2.0.
#>

[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src' 'MongrelDB.psd1') -Force

$table = "ps_example_query_$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

$url = $env:MONGRELDB_URL
if (-not $url) { $url = 'http://127.0.0.1:8453' }

$db = Connect-MongrelDB -Url $url -PassThru
$tableCreated = $false
$status = 1

try {
    if (-not (Get-MongrelDBHealth -Client $db)) { Write-Error "daemon not reachable at $url"; return 1 }
    Write-Host 'Connected to MongrelDB'

    $cols = @(
        @{ id = 1; name = 'id';    ty = 'int64';   primary_key = $true;  nullable = $false },
        @{ id = 2; name = 'name';  ty = 'varchar'; primary_key = $false; nullable = $false },
        @{ id = 3; name = 'score'; ty = 'float64'; primary_key = $false; nullable = $false }
    )
    $tid = New-MongrelDBTable -Name $table -Columns $cols -Client $db
    $tableCreated = $true
    Write-Host "Created table $table (id $tid)"

    # Load five rows with varying scores.
    $rows = @(
        @{ 1 = 1; 2 = 'Alice'; 3 = 40.0 },
        @{ 1 = 2; 2 = 'Bob';   3 = 65.0 },
        @{ 1 = 3; 2 = 'Carol'; 3 = 82.0 },
        @{ 1 = 4; 2 = 'Dave';  3 = 91.0 },
        @{ 1 = 5; 2 = 'Eve';   3 = 12.5 }
    )
    foreach ($r in $rows) { Add-MongrelDBRow -Table $table -Cells $r -Client $db }
    Write-Host 'Inserted 5 rows'

    # Range query: 60 <= score <= 90 (both inclusive).
    $rangeCond = New-MongrelDBCondition -Kind range -ColumnId 3 -Lo 60 -Hi 90 -LoSet -HiSet
    $res = Invoke-MongrelDBQuery -Table $table -Conditions $rangeCond -Client $db
    Write-Host "  range [60, 90] on score: $($res.Rows.Count) rows"
    foreach ($row in $res.Rows) { Write-Host "    $([string]::Join(', ', ($row.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" })))" }

    # Primary-key lookup: id == 4 (Dave).
    $pkCond = New-MongrelDBCondition -Kind pk -Value 4
    $res = Invoke-MongrelDBQuery -Table $table -Conditions $pkCond -Client $db
    Write-Host "  pk == 4: $($res.Rows.Count) rows"
    foreach ($row in $res.Rows) { Write-Host "    $([string]::Join(', ', ($row.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" })))" }

    $status = 0
} finally {
    if ($tableCreated) {
        try { Remove-MongrelDBTable -Name $table -Client $db; Write-Host "Dropped table $table" }
        catch { Write-Host "drop_table failed: $($_.Exception.Message)" }
    }
}
return $status
