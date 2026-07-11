<#
.SYNOPSIS
    Pure PowerShell HTTP client for MongrelDB.

.DESCRIPTION
    MongrelDB is a PowerShell module that talks JSON over the Kit transaction,
    query, and SQL endpoints of a running mongreldb-server daemon. It uses
    Invoke-RestMethod / Invoke-WebRequest (built into PowerShell) and the
    built-in ConvertTo-Json / ConvertFrom-Json cmdlets, so there are no
    external dependencies.

    Function naming follows PowerShell Verb-Noun conventions (approved verbs):
      Connect-MongrelDB, Get-MongrelDBHealth, New-MongrelDBTable,
      Remove-MongrelDBTable, Get-MongrelDBCount, Add-MongrelDBRow,
      Set-MongrelDBRow (upsert), Remove-MongrelDBRow, Invoke-MongrelDBQuery,
      Invoke-MongrelDBTransaction, Invoke-MongrelDBSql, Get-MongrelDBSchema.

    Error handling: methods throw a typed exception (MongrelDB.MongrelDBException)
    with a Category property ('Auth','NotFound','Conflict','Query','Network')
    so callers can catch by category. Set -ErrorAction Stop or wrap in try/catch.

.LICENSE
    Dual-licensed under MIT OR Apache-2.0.
    SPDX-License-Identifier: MIT OR Apache-2.0
#>

# Module-scoped state: the currently-connected client. Set by Connect-MongrelDB.
$script:Client = $null

# Cap on a response body size (256 MB) so a runaway query cannot exhaust memory.
$script:MaxResponseBytes = 268435456

# Default daemon URL when none is supplied.
$script:DefaultUrl = 'http://127.0.0.1:8453'

# ── Exception type ────────────────────────────────────────────────────────

# A typed exception with a Category so callers can catch by category. PowerShell
# does not make it trivial to define a real class with default constructors in
# pure script, so we use a factory that builds a System.Exception with an
# added note property. Callers inspect $_.Exception.Category in a catch block,
# or $_.Category after the message has been promoted.
function New-MongrelDBException {
    <#
    .SYNOPSIS
        Build a typed MongrelDB exception carrying a Category.
    #>
    [CmdletBinding()]
    [OutputType([System.Exception])]
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Category = 'Query',
        [int]$StatusCode = 0,
        [string]$ErrorCode
    )
    $ex = [System.Exception]::new($Message)
    $ex | Add-Member -NotePropertyName Category -NotePropertyValue $Category -Force
    if ($StatusCode) { $ex | Add-Member -NotePropertyName StatusCode -NotePropertyValue $StatusCode -Force }
    if ($ErrorCode) { $ex | Add-Member -NotePropertyName ErrorCode -NotePropertyValue $ErrorCode -Force }
    return $ex
}

# ── Internal helpers ──────────────────────────────────────────────────────

# Map an HTTP status code to the right error category.
function Get-MongrelDBCategory {
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$StatusCode)
    switch ($StatusCode) {
        401 { 'Auth' }
        403 { 'Auth' }
        404 { 'NotFound' }
        409 { 'Conflict' }
        default { 'Query' }
    }
}

# Percent-encode a single URL path segment so a table name containing '/',
# '?', '#', or spaces cannot inject extra segments or break routing.
function ConvertTo-EncodedSegment {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Segment)
    # [uri]::EscapeDataString encodes everything except A-Za-z0-9-_.~ which is
    # exactly the unreserved set we want for a path segment.
    return [uri]::EscapeDataString($Segment)
}

# Decode the daemon's {"error":{"message":...,"code":...,"op_index":...}}
# envelope when present. Returns a hashtable with Message, Code, OpIndex.
function ConvertFrom-MongrelDBErrorEnvelope {
    [CmdletBinding()]
    param([string]$Body)
    if (-not $Body) { return $null }
    try {
        $obj = $Body | ConvertFrom-Json -ErrorAction Stop
    } catch {
        return $null
    }
    if ($obj.error) {
        $e = $obj.error
        if ($e -is [string]) {
            return @{ Message = $e; Code = $null; OpIndex = $null }
        }
        return @{
            Message  = if ($e.message) { $e.message } else { $Body }
            Code     = if ($e.code) { $e.code } else { $null }
            OpIndex  = if ($null -ne $e.op_index) { $e.op_index } else { $null }
        }
    }
    if ($obj.message) {
        return @{ Message = $obj.message; Code = $null; OpIndex = $null }
    }
    return $null
}

# Reject CR/LF in an auth credential: token/username/password are placed
# verbatim into the Authorization header, so an embedded newline would allow
# header injection (request splitting). Validate before use.
function Assert-NoCrlf {
    [CmdletBinding()]
    param(
        [string]$Value,
        [string]$Name
    )
    if ($null -ne $Value -and ($Value -match '\r' -or $Value -match '\n')) {
        throw (New-MongrelDBException "auth $Name must not contain CR or LF" -Category 'InvalidArg')
    }
}

# Core request helper. Returns the decoded JSON body (or $null for empty bodies).
# Throws a MongrelDB exception of the appropriate category on failure.
function Invoke-MongrelDBRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Path,
        $Body,
        $Client
    )
    if (-not $Client) { $Client = $script:Client }
    if (-not $Client) {
        throw (New-MongrelDBException 'not connected; call Connect-MongrelDB first' -Category 'InvalidArg')
    }

    $url = "$($Client.Url)/$Path"
    $headers = @{ 'Accept' = 'application/json' }
    if ($Client.AuthHeader) {
        $headers['Authorization'] = $Client.AuthHeader
    }

    $requestParams = @{
        Method          = $Method
        Uri             = $url
        Headers         = $headers
        ErrorAction     = 'Stop'
        MaximumRedirection = 0
    }
    # PowerShell 7+ honors -SkipHttpErrorCheck to avoid throwing on non-2xx,
    # letting us read the body. Fall back to the classic try/catch behavior on
    # Windows PowerShell 5.1. -SkipHttpErrorCheck is the only option needed;
    # -ResponseHeadersVariable is intentionally avoided because it is a dynamic
    # parameter not present on every PowerShell 7+ build (e.g. the Linux pwsh
    # used by CI), and passing an unknown parameter splat fails to bind and
    # breaks every request.
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $requestParams['SkipHttpErrorCheck'] = $true
    }

    $content = $null
    if ($null -ne $Body) {
        $content = $Body | ConvertTo-Json -Depth 20 -Compress
        $requestParams['Body'] = $content
        $requestParams['ContentType'] = 'application/json'
    }

    try {
        $response = Invoke-WebRequest @requestParams
    } catch [System.Net.WebException], [Microsoft.PowerShell.Commands.HttpResponseException] {
        # PowerShell 5.1 path: the exception carries the HTTP response.
        $resp = $_.Exception.Response
        if ($resp) {
            $status = [int]$resp.StatusCode
            $errBody = $null
            try {
                $stream = $resp.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $errBody = $reader.ReadToEnd()
            } catch {}
            $cat = Get-MongrelDBCategory -StatusCode $status
            if ($errBody -match 'not found') { $cat = 'NotFound' }
            $envelope = ConvertFrom-MongrelDBErrorEnvelope -Body $errBody
            $message = if ($envelope -and $envelope.Message) { $envelope.Message } else { "Server error ($status)" }
            if ($message -match '^not found:') { $cat = 'NotFound' }
            $code = if ($envelope -and $envelope.Code) { $envelope.Code } else { $null }
            throw (New-MongrelDBException $message -Category $cat -StatusCode $status -ErrorCode $code)
        }
        throw (New-MongrelDBException "network error: $($_.Exception.Message)" -Category 'Network')
    } catch {
        throw (New-MongrelDBException "network error: $($_.Exception.Message)" -Category 'Network')
    }

    # PowerShell 7+ path: SkipHttpErrorCheck returns the response even on 4xx/5xx.
    $status = [int]$response.StatusCode
    $respBody = $response.Content
    # Cap the response body at 256 MB.
    if ($respBody -and $respBody.Length -gt $script:MaxResponseBytes) {
        throw (New-MongrelDBException "response body exceeds $($script:MaxResponseBytes) bytes" -Category 'Query')
    }
    if ($status -lt 200 -or $status -ge 300) {
        $cat = Get-MongrelDBCategory -StatusCode $status
        if ($respBody -match 'not found') { $cat = 'NotFound' }
        $envelope = ConvertFrom-MongrelDBErrorEnvelope -Body $respBody
        $message = if ($envelope -and $envelope.Message) { $envelope.Message } else { "Server error ($status)" }
        if ($message -match '^not found:') { $cat = 'NotFound' }
        $code = if ($envelope -and $envelope.Code) { $envelope.Code } else { $null }
        throw (New-MongrelDBException $message -Category $cat -StatusCode $status -ErrorCode $code)
    }

    if (-not $respBody) { return $null }
    try {
        return $respBody | ConvertFrom-Json -ErrorAction Stop
    } catch {
        # Non-JSON 2xx body (e.g. plain "ok" from /health): treat as success
        # with no body.
        return $null
    }
}

# Flatten a hashtable of { colId => value } into the flat [colId, value, ...]
# array the server expects. Column ids are sorted ascending.
function ConvertTo-FlatCells {
    [CmdletBinding()]
    param([hashtable]$Cells)
    if (-not $Cells) { return @() }
    $flat = [System.Collections.ArrayList]::new()
    foreach ($key in ($Cells.Keys | Sort-Object { [long]$_ })) {
        [void]$flat.Add([long]$key)
        [void]$flat.Add($Cells[$key])
    }
    return , $flat.ToArray()
}

# ── Public API: lifecycle ─────────────────────────────────────────────────

function Connect-MongrelDB {
    <#
    .SYNOPSIS
        Connect to a mongreldb-server daemon.
    .DESCRIPTION
        Open mode by default. Use -Token for bearer auth, or -Username/-Password
        for HTTP Basic. Sets the module-scoped default client; pass -PassThru to
        also return the client object for multi-connection use.
    .EXAMPLE
        Connect-MongrelDB -Url 'http://127.0.0.1:8453'
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [string]$Url,
        [string]$Token,
        [string]$Username,
        [string]$Password,
        [int]$TimeoutSec = 30,
        [switch]$PassThru
    )

    Assert-NoCrlf -Value $Token -Name 'token'
    Assert-NoCrlf -Value $Username -Name 'username'
    Assert-NoCrlf -Value $Password -Name 'password'

    $u = if ($Url) { $Url.TrimEnd('/') } else { $script:DefaultUrl }

    $authHeader = $null
    if ($Token) {
        $authHeader = "Bearer $Token"
    } elseif ($Username) {
        $creds = "$Username`:$Password"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($creds)
        $encoded = [System.Convert]::ToBase64String($bytes)
        $authHeader = "Basic $encoded"
    }

    $client = @{
        Url        = $u
        AuthHeader = $authHeader
        TimeoutSec = $TimeoutSec
    }
    $script:Client = $client
    if ($PassThru) { return $client }
}

function Disconnect-MongrelDB {
    <#
    .SYNOPSIS
        Clear the module-scoped default client.
    #>
    [CmdletBinding()]
    param()
    $script:Client = $null
}

# ── Public API: health & tables ───────────────────────────────────────────

function Get-MongrelDBHealth {
    <#
    .SYNOPSIS
        Check daemon health. Returns $true on success.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param($Client)
    try {
        $null = Invoke-MongrelDBRequest -Method 'GET' -Path 'health' -Client $Client
        return $true
    } catch {
        return $false
    }
}

function Get-MongrelDBHistoryRetention {
    param($Client)
    Invoke-MongrelDBRequest -Method 'GET' -Path 'history/retention' -Client $Client
}

function Get-MongrelDBEarliestRetainedEpoch {
    param($Client)
    (Get-MongrelDBHistoryRetention -Client $Client).earliest_retained_epoch
}

function Set-MongrelDBHistoryRetention {
    param([Parameter(Mandatory)][long]$Epochs, $Client)
    Invoke-MongrelDBRequest -Method 'PUT' -Path 'history/retention' -Body @{ history_retention_epochs = $Epochs } -Client $Client
}

function Get-MongrelDBTable {
    <#
    .SYNOPSIS
        List all table names.
    #>
    [CmdletBinding()]
    param($Client)
    $r = Invoke-MongrelDBRequest -Method 'GET' -Path 'tables' -Client $Client
    if ($r -is [array]) { return $r }
    return @()
}

function ConvertTo-MongrelDBCreateTableBody {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Columns,
        [hashtable]$Constraints
    )
    $colsList = @()
    foreach ($c in $Columns) {
        $d = [ordered]@{
            id          = [long]$c.id
            name        = $c.name
            ty          = $c.ty
            primary_key = [bool]$c.primary_key
            nullable    = [bool]$c.nullable
        }
        if ($c.enum_variants -and $c.enum_variants.Count -gt 0) {
            $d['enum_variants'] = @($c.enum_variants)
        }
        if ($c.ContainsKey('default_value')) {
            $d['default_value'] = $c.default_value
        }
        if ($c.ContainsKey('default_expr')) {
            $d['default_expr'] = [string]$c.default_expr
        }
        $colsList += ,$d
    }
    $body = @{ name = $Name; columns = $colsList }
    if ($null -ne $Constraints) { $body['constraints'] = $Constraints }
    return $body
}

function New-MongrelDBTable {
    <#
    .SYNOPSIS
        Create a table. Returns the assigned table id (0 if none reported).
    .PARAMETER Name
        Table name.
    .PARAMETER Columns
        Array of column hashtables: @{ id=1; name='id'; ty='int64';
        primary_key=$true; nullable=$false; enum_variants=@('a','b');
        default_value='a' }.
    .PARAMETER Constraints
        Optional table constraints hashtable, including a checks array.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Columns,
        $Client,
        [hashtable]$Constraints
    )
    $body = ConvertTo-MongrelDBCreateTableBody -Name $Name -Columns $Columns -Constraints $Constraints
    $r = Invoke-MongrelDBRequest -Method 'POST' -Path 'kit/create_table' -Body $body -Client $Client
    if ($r -and $r.table_id) { return [long]$r.table_id }
    return 0
}

function Remove-MongrelDBTable {
    <#
    .SYNOPSIS
        Drop a table by name.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Name,
        $Client
    )
    $seg = ConvertTo-EncodedSegment -Segment $Name
    $null = Invoke-MongrelDBRequest -Method 'DELETE' -Path "tables/$seg" -Client $Client
}

function Get-MongrelDBCount {
    <#
    .SYNOPSIS
        Row count for a table.
    #>
    [CmdletBinding()]
    [OutputType([long])]
    param(
        [Parameter(Mandatory)][string]$Table,
        $Client
    )
    $seg = ConvertTo-EncodedSegment -Segment $Table
    $r = Invoke-MongrelDBRequest -Method 'GET' -Path "tables/$seg/count" -Client $Client
    if ($r -and $null -ne $r.count) { return [long]$r.count }
    return 0
}

# ── Public API: CRUD (single-op transactions) ─────────────────────────────

function Add-MongrelDBRow {
    <#
    .SYNOPSIS
        Insert a row. $Cells maps column id to value. Use -IdempotencyKey for
        safe retries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][hashtable]$Cells,
        [string]$IdempotencyKey,
        $Client
    )
    $op = [ordered]@{
        put = [ordered]@{
            table     = $Table
            cells     = ConvertTo-FlatCells -Cells $Cells
            returning = $false
        }
    }
    $body = @{ ops = @($op) }
    if ($IdempotencyKey) { $body['idempotency_key'] = $IdempotencyKey }
    $r = Invoke-MongrelDBRequest -Method 'POST' -Path 'kit/txn' -Body $body -Client $Client
    if ($r -and $r.results) { return $r.results[0] }
    return $null
}

function Set-MongrelDBRow {
    <#
    .SYNOPSIS
        Upsert (insert or update on PK conflict). -UpdateCells supplies the
        values written on conflict (omit for DO NOTHING).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [Parameter(Mandatory)][hashtable]$Cells,
        [hashtable]$UpdateCells,
        [string]$IdempotencyKey,
        $Client
    )
    $opDict = [ordered]@{
        table     = $Table
        cells     = ConvertTo-FlatCells -Cells $Cells
        returning = $false
    }
    if ($UpdateCells) {
        $opDict['update_cells'] = ConvertTo-FlatCells -Cells $UpdateCells
    }
    $body = @{ ops = @(@{ upsert = $opDict }) }
    if ($IdempotencyKey) { $body['idempotency_key'] = $IdempotencyKey }
    $r = Invoke-MongrelDBRequest -Method 'POST' -Path 'kit/txn' -Body $body -Client $Client
    if ($r -and $r.results) { return $r.results[0] }
    return $null
}

function Remove-MongrelDBRow {
    <#
    .SYNOPSIS
        Delete a row by its internal row id, or by primary key when -PrimaryKeyValue
        is supplied.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        [long]$RowId,
        $PrimaryKeyValue,
        $Client
    )
    if ($null -ne $PrimaryKeyValue) {
        $op = @{ delete_by_pk = @{ table = $Table; pk = $PrimaryKeyValue } }
    } else {
        $op = @{ delete = @{ table = $Table; row_id = $RowId } }
    }
    $body = @{ ops = @($op) }
    $null = Invoke-MongrelDBRequest -Method 'POST' -Path 'kit/txn' -Body $body -Client $Client
}

# ── Public API: batch transactions ────────────────────────────────────────

function Invoke-MongrelDBTransaction {
    <#
    .SYNOPSIS
        Stage an ops array and commit atomically. Each op is a hashtable like
        @{ put=@{table=..; cells=..} }, @{ upsert=@{..} }, @{ delete=@{..} },
        @{ delete_by_pk=@{..} }. Optional idempotency key for safe retries.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Ops,
        [string]$IdempotencyKey,
        $Client
    )
    $body = @{ ops = $Ops }
    if ($IdempotencyKey) { $body['idempotency_key'] = $IdempotencyKey }
    $r = Invoke-MongrelDBRequest -Method 'POST' -Path 'kit/txn' -Body $body -Client $Client
    if ($r -and $r.results) { return $r.results }
    return @()
}

# ── Public API: query ─────────────────────────────────────────────────────

function Invoke-MongrelDBQuery {
    <#
    .SYNOPSIS
        Run a native query. $Conditions is an array of condition hashtables
        (see New-MongrelDBCondition). Optional projection and limit. Returns a
        hashtable with Rows and Truncated.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        $Conditions,
        [int[]]$Projection,
        [long]$Limit,
        $Client
    )
    $body = [ordered]@{ table = $Table }
    if ($Conditions) { $body['conditions'] = @($Conditions) }
    if ($Projection) { $body['projection'] = @($Projection) }
    if ($Limit -gt 0) { $body['limit'] = $Limit }

    $r = Invoke-MongrelDBRequest -Method 'POST' -Path 'kit/query' -Body $body -Client $Client
    $rows = @()
    $trunc = $false
    if ($r) {
        if ($r.rows) { $rows = @($r.rows) }
        if ($r.truncated) { $trunc = [bool]$r.truncated }
    }
    # The daemon returns each row as {"row_id":"0","cells":[col_id, value,
    # col_id, value, ...]} with a flat cells array. Expand it into a per-row
    # object whose properties are the column ids (as strings) so callers can do
    # $row.'2'. See mongreldb-server/src/kit.rs KitRow serialization.
    $decoded = foreach ($row in $rows) { ConvertFrom-MongrelDBRow $row }
    return @{ Rows = @($decoded); Truncated = $trunc }
}

# Expand the flat `cells` array of one /kit/query row into a PSCustomObject
# keyed by column id (as a string), preserving row_id. Cells is flat:
# [col_id, value, col_id, value, ...] with even indices as column ids.
function ConvertFrom-MongrelDBRow {
    param($Row)
    if ($null -eq $Row) { return $null }
    $ht = [ordered]@{}
    if ($Row.PSObject.Properties.Match('row_id').Count -gt 0) { $ht['row_id'] = $Row.row_id }
    $cells = $Row.cells
    if ($cells) {
        $arr = @($cells)
        for ($i = 0; $i + 1 -lt $arr.Count; $i += 2) {
            $colId = [string]$arr[$i]
            $ht[$colId] = $arr[$i + 1]
        }
    }
    return [pscustomobject]$ht
}

function New-MongrelDBCondition {
    <#
    .SYNOPSIS
        Build a native query condition. Translates friendly aliases:
        column -> column_id, min/max -> lo/hi, value -> pattern for fm_contains.
    .PARAMETER Kind
        One of: pk, bitmap_eq, range (int64), range_f64 (float64), fm_contains,
        is_null, is_not_null. Use range_f64 for float64 columns and range for
        integer columns.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('pk','bitmap_eq','range','range_f64','fm_contains','is_null','is_not_null')]
        [string]$Kind,
        [long]$ColumnId,
        $Value,
        [double]$Lo,
        [double]$Hi,
        [switch]$LoSet,
        [switch]$HiSet,
        [switch]$LoInclusive,
        [switch]$HiInclusive,
        [switch]$IntSet
    )
    switch ($Kind) {
        'pk' {
            return @{ pk = @{ value = $Value } }
        }
        'bitmap_eq' {
            return @{ bitmap_eq = @{ column_id = $ColumnId; value = $Value } }
        }
        'range' {
            $d = [ordered]@{ column_id = $ColumnId }
            if ($LoSet) { $d['lo'] = $Lo }
            if ($HiSet) { $d['hi'] = $Hi }
            return @{ range = $d }
        }
        'range_f64' {
            $d = [ordered]@{ column_id = $ColumnId }
            if ($LoSet) { $d['lo'] = $Lo }
            if ($HiSet) { $d['hi'] = $Hi }
            if ($LoInclusive) { $d['lo_inclusive'] = $true }
            if ($HiInclusive) { $d['hi_inclusive'] = $true }
            return @{ range_f64 = $d }
        }
        'fm_contains' {
            return @{ fm_contains = @{ column_id = $ColumnId; pattern = $Value } }
        }
        'is_null' {
            return @{ is_null = @{ column_id = $ColumnId } }
        }
        'is_not_null' {
            return @{ is_not_null = @{ column_id = $ColumnId } }
        }
    }
}

# ── Public API: SQL & schema ──────────────────────────────────────────────

function Invoke-MongrelDBSql {
    <#
    .SYNOPSIS
        Execute SQL. Requests the JSON result format. Returns decoded rows for
        SELECTs, or $null for statements that produce no rows.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Sql,
        $Client
    )
    return Invoke-MongrelDBRequest -Method 'POST' -Path 'sql' -Body @{ sql = $Sql; format = 'json' } -Client $Client
}

function Get-MongrelDBSchema {
    <#
    .SYNOPSIS
        Full schema catalog.
    #>
    [CmdletBinding()]
    param($Client)
    $r = Invoke-MongrelDBRequest -Method 'GET' -Path 'kit/schema' -Client $Client
    if ($r -and $r.tables) { return $r.tables }
    return $r
}

function Get-MongrelDBSchemaFor {
    <#
    .SYNOPSIS
        Descriptor for a single table.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Table,
        $Client
    )
    $seg = ConvertTo-EncodedSegment -Segment $Table
    return Invoke-MongrelDBRequest -Method 'GET' -Path "kit/schema/$seg" -Client $Client
}

# Export the public surface (approved verbs only).
Export-ModuleMember -Function `
    Connect-MongrelDB, Disconnect-MongrelDB, `
    Get-MongrelDBHealth, Get-MongrelDBTable, `
    New-MongrelDBTable, Remove-MongrelDBTable, Get-MongrelDBCount, `
    Add-MongrelDBRow, Set-MongrelDBRow, Remove-MongrelDBRow, `
    Invoke-MongrelDBTransaction, `
    Invoke-MongrelDBQuery, New-MongrelDBCondition, `
    Invoke-MongrelDBSql, Get-MongrelDBSchema, Get-MongrelDBSchemaFor
