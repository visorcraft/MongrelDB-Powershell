<#
.SYNOPSIS
    Example: basic CRUD operations with the MongrelDB PowerShell client.

.DESCRIPTION
    Requires a mongreldb-server daemon running on http://127.0.0.1:8453, or
    point MONGRELDB_URL at a running daemon.

    Creates a table, inserts three rows, counts them, queries all rows, upserts
    (updates) one row by primary key, deletes one row, then drops the table.
    Progress is printed at every step.

.LICENSE
    MIT OR Apache-2.0.
#>

[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src' 'MongrelDB.psd1') -Force

# Per-run unique suffix (unix time) keeps every invocation isolated on a
# shared daemon.
$table = "ps_example_crud_$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

$url = $env:MONGRELDB_URL
if (-not $url) { $url = 'http://127.0.0.1:8453' }

$db = Connect-MongrelDB -Url $url -PassThru
$tableCreated = $false
$status = 1

try {
    # 1. Health check.
    if (-not (Get-MongrelDBHealth -Client $db)) {
        Write-Error "daemon not reachable at $url"; return 1
    }
    Write-Host 'Connected to MongrelDB'

    # 2. Create the table. The status column is an enum with a default.
    $statusVariants = @('active','inactive','paused')
    $cols = @(
        @{ id = 1; name = 'id';     ty = 'int64';   primary_key = $true;  nullable = $false },
        @{ id = 2; name = 'name';   ty = 'varchar'; primary_key = $false; nullable = $false },
        @{ id = 3; name = 'score';  ty = 'float64'; primary_key = $false; nullable = $false; default_value = '0.0' },
        @{ id = 4; name = 'status'; ty = 'enum'; primary_key = $false; nullable = $false; enum_variants = $statusVariants; default_value = 'active' }
    )
    $tid = New-MongrelDBTable -Name $table -Columns $cols -Client $db
    $tableCreated = $true
    Write-Host "Created table $table (id $tid)"

    # 3. Insert three rows.
    Add-MongrelDBRow -Table $table -Cells @{ 1 = 1; 2 = 'Alice'; 3 = 95.5; 4 = 'active'   } -Client $db
    Add-MongrelDBRow -Table $table -Cells @{ 1 = 2; 2 = 'Bob';   3 = 82.0; 4 = 'inactive' } -Client $db
    Add-MongrelDBRow -Table $table -Cells @{ 1 = 3; 2 = 'Carol'; 3 = 78.3; 4 = 'paused'   } -Client $db
    Write-Host 'Inserted 3 rows'

    # 4. Count.
    $n = Get-MongrelDBCount -Table $table -Client $db
    Write-Host "Total rows: $n"

    # 5. Query all rows.
    $res = Invoke-MongrelDBQuery -Table $table -Client $db
    Write-Host "Query returned $($res.Rows.Count) rows:"
    foreach ($row in $res.Rows) { Write-Host "  $([string]::Join(', ', ($row.PSObject.Properties | ForEach-Object { "$($_.Name)=$($_.Value)" })))" }

    # 6. Upsert (update) Alice's score and mark her paused.
    Set-MongrelDBRow -Table $table -Cells @{ 1 = 1; 2 = 'Alice'; 3 = 100.0; 4 = 'paused' } `
        -UpdateCells @{ 2 = 'Alice'; 3 = 100.0; 4 = 'paused' } -Client $db
    Write-Host "Upserted Alice's score to 100.0"
    $n = Get-MongrelDBCount -Table $table -Client $db
    Write-Host "Total rows after upsert: $n"

    # 7. Delete Carol (primary key 3).
    Remove-MongrelDBRow -Table $table -PrimaryKeyValue 3 -Client $db
    $n = Get-MongrelDBCount -Table $table -Client $db
    Write-Host "Deleted Carol; remaining rows: $n"

    $status = 0
} finally {
    # Guaranteed cleanup: drop the table if it was created.
    if ($tableCreated) {
        try {
            Remove-MongrelDBTable -Name $table -Client $db
            Write-Host "Dropped table $table"
        } catch {
            Write-Host "drop_table failed: $($_.Exception.Message)"
        }
    }
}
return $status
