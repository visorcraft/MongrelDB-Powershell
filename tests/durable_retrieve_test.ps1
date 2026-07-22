# Offline unit tests for 0.64 durable HLC recovery parsers.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $here '../src/MongrelDB.psd1') -Force

$failures = 0
$passed = 0
function Check([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        $script:passed++
        Write-Host -NoNewline '.'
    } catch {
        $script:failures++
        Write-Host "`nFAIL $Name : $_"
    }
}

$fixture = @{
    query_id = 'abcdefabcdefabcdefabcdefabcdefab'
    status = 'committed'
    state = 'completed'
    server_state = 'completed'
    terminal_state = 'committed'
    committed = $true
    last_commit_epoch = 17
    last_commit_hlc = @{
        physical_micros = 1700000000000000
        logical = 3
        node_tiebreaker = 7
    }
    outcome = @{
        committed = $true
        last_commit_epoch = 17
        last_commit_hlc = @{
            physical_micros = 1700000000000000
            logical = 3
            node_tiebreaker = 7
        }
        serialization = 'succeeded'
        serialization_state = 'succeeded'
        terminal_state = 'committed'
    }
    durable = @{
        committed = $true
        last_commit_epoch = 17
        last_commit_hlc = @{
            physical_micros = 1700000000000000
            logical = 3
            node_tiebreaker = 7
        }
        serialization = 'succeeded'
        serialization_state = 'succeeded'
        terminal_state = 'committed'
    }
}

Check 'parse structural HLC' {
    $status = ConvertFrom-MongrelDBQueryStatus -Raw $fixture
    if (-not $status.committed) { throw 'committed false' }
    $hlc = Get-MongrelDBCommitHlc -Status $status
    if ($null -eq $hlc) { throw 'hlc null' }
    if ([int64]$hlc.physical_micros -ne 1700000000000000) { throw "phys=$($hlc.physical_micros)" }
    if ([int]$hlc.logical -ne 3) { throw "logical=$($hlc.logical)" }
    if ([int]$hlc.node_tiebreaker -ne 7) { throw "node=$($hlc.node_tiebreaker)" }
    $ser = Get-MongrelDBSerializationState -Status $status
    if ($ser -ne 'succeeded') { throw "ser=$ser" }
}

Check 'absent hlc' {
    if ($null -ne (ConvertFrom-MongrelDBCommitHlc -Raw $null)) { throw 'expected null' }
    if ($null -ne (ConvertFrom-MongrelDBCommitHlc -Raw @{})) { throw 'expected null empty' }
    if ($null -ne (ConvertFrom-MongrelDBCommitHlc -Raw @{ logical = 1 })) { throw 'expected null missing phys' }
}

Write-Host ""
Write-Host "$passed passed, $failures failed"
if ($failures -gt 0) { exit 1 }
