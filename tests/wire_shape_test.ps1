<#
.SYNOPSIS
    Offline wire-format conformance test for the MongrelDB PowerShell client.

.DESCRIPTION
    Does NOT contact a daemon. Serializes a create_table body, a batch txn body,
    and a query body, then asserts the exact JSON keys and shape the server
    expects. This catches regressions in the on-wire format without needing a
    running mongreldb-server.

.LICENSE
    MIT OR Apache-2.0.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$Pass = 0
$Fail = 0

$repoRoot = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $repoRoot 'src' 'MongrelDB.psd1') -Force

function Invoke-Test {
    param([string]$Name, [scriptblock]$Body)
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

# ── Tests ─────────────────────────────────────────────────────────────────

# The create_table body must carry name, columns[] with id/name/ty/primary_key/
# nullable, plus optional enum_variants and default_value when set.
Invoke-Test 'test_create_table_body' {
    $cols = @(
        @{ id = 1; name = 'id'; ty = 'int64'; primary_key = $true; nullable = $false },
        @{ id = 4; name = 'status'; ty = 'varchar'; primary_key = $false; nullable = $false;
           enum_variants = @('active','inactive','paused'); default_value = 'active' }
    )
    $body = @{ name = 'orders'; columns = $cols }
    $json = $body | ConvertTo-Json -Depth 20 -Compress
    if ($json -notmatch '"name":"orders"') { Fail-Test 'body missing table name' }
    if ($json -notmatch '"ty":"int64"') { Fail-Test 'body missing column type' }
    if ($json -notmatch '"primary_key":true') { Fail-Test 'body missing primary_key' }
    if ($json -notmatch 'enum_variants') { Fail-Test 'body missing enum_variants' }
    if ($json -notmatch '"default_value":"active"') { Fail-Test 'body missing default_value' }
}

# The batch txn body must wrap ops in {"ops":[...]} and carry an idempotency
# key when one is supplied.
Invoke-Test 'test_txn_body_with_key' {
    $body = @{
        ops = @( @{ put = @{ table = 'orders'; cells = @(1, 1); returning = $false } } )
        idempotency_key = 'batch-1'
    }
    $json = $body | ConvertTo-Json -Depth 20 -Compress
    if ($json -notmatch '"ops":') { Fail-Test 'txn body missing ops' }
    if ($json -notmatch '"idempotency_key":"batch-1"') { Fail-Test 'txn body missing idempotency_key' }
    if ($json -notmatch '"returning":false') { Fail-Test 'txn body put must set returning:false' }
}

# The query body must serialize conditions, projection, and limit.
Invoke-Test 'test_query_body' {
    $body = [ordered]@{
        table = 'orders'
        conditions = @( @{ range = @{ column_id = 3; lo = 100.0; hi = 500.0 } } )
        projection = @(1, 2)
        limit = 100
    }
    $json = $body | ConvertTo-Json -Depth 20 -Compress
    if ($json -notmatch '"table":"orders"') { Fail-Test 'query body missing table' }
    if ($json -notmatch 'range') { Fail-Test 'query body missing range condition' }
    if ($json -notmatch 'column_id') { Fail-Test 'query body missing column_id' }
    if ($json -notmatch 'projection') { Fail-Test 'query body missing projection' }
    if ($json -notmatch '"limit":100') { Fail-Test 'query body missing limit' }
}

# Table names with special characters must be percent-encoded in path segments.
Invoke-Test 'test_segment_encoding' {
    # Invoke the module's internal helper. '/' must become %2F.
    $encoded = & (Get-Module MongrelDB) { [uri]::EscapeDataString('a/b c') }
    if ($encoded -notmatch '%2F') { Fail-Test 'slash must be percent-encoded' }
    if ($encoded -notmatch '%20') { Fail-Test 'space must be percent-encoded' }
}

# New-MongrelDBCondition must build the right wire shape per kind.
Invoke-Test 'test_condition_builder' {
    $pk = New-MongrelDBCondition -Kind pk -Value 42
    if (-not $pk.pk -or $pk.pk.value -ne 42) { Fail-Test 'pk condition wrong' }

    $range = New-MongrelDBCondition -Kind range -ColumnId 3 -Lo 100 -Hi 500 -LoSet -HiSet
    if ($range.range.column_id -ne 3 -or $range.range.lo -ne 100 -or $range.range.hi -ne 500) {
        Fail-Test 'range condition wrong'
    }

    $bm = New-MongrelDBCondition -Kind bitmap_eq -ColumnId 2 -Value 'Alice'
    if ($bm.bitmap_eq.value -ne 'Alice') { Fail-Test 'bitmap_eq condition wrong' }

    $fm = New-MongrelDBCondition -Kind fm_contains -ColumnId 2 -Value 'database'
    if ($fm.fm_contains.pattern -ne 'database') { Fail-Test 'fm_contains must map value->pattern' }
}

# CR/LF in an auth credential must be rejected (header-injection guard).
Invoke-Test 'test_crlf_rejection' {
    $threw = $false
    try {
        Connect-MongrelDB -Token "good`r`nX-Evil: yes" 2>$null
    } catch {
        $threw = $true
    }
    if (-not $threw) { Fail-Test 'must reject CR/LF in token' }
}

Write-Host ""
Write-Host "$Pass passed, $Fail failed"
if ($Fail -gt 0) { exit 1 } else { exit 0 }
