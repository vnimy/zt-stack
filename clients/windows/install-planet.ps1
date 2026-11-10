<#
.SYNOPSIS
    Install a self-hosted ZeroTier planet file on Windows.

.DESCRIPTION
    Downloads the planet from <ServerUrl>/planet to a temporary file next to the
    target, validates it (size + planet magic byte + optional sha256), backs up
    the existing planet as planet.bak.<timestamp>, replaces the planet
    atomically and restarts the ZeroTier One service.

    A failed download or a failed validation never touches the existing planet.

.PARAMETER ServerUrl
    Base URL of your self-hosted planet server, e.g. https://zt.example.com
    The script requests <ServerUrl>/planet .

.PARAMETER Token
    Optional download token. Sent as ?token=... and as "Authorization: Bearer".

.PARAMETER Target
    Optional planet path override (testing / advanced). Default:
    C:\ProgramData\ZeroTier\One\planet

.PARAMETER Sha256
    Optional expected SHA256 of the planet file (recommended in production).

.PARAMETER SkipRestart
    Replace the file only, do not restart the ZeroTier One service.

.EXAMPLE
    .\install-planet.ps1 -ServerUrl https://zt.example.com -Token abc123

.EXAMPLE
    .\install-planet.ps1 -ServerUrl http://127.0.0.1:18089 -Token abc -Target D:\tmp\planet -SkipRestart
#>
#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$ServerUrl,

    [string]$Token = '',

    [string]$Target = '',

    [string]$Sha256 = '',

    [switch]$SkipRestart
)

$ErrorActionPreference = 'Stop'

$ScriptVersion = '1.0.0'
$MinBytes = 128
$MaxBytes = 65536
$MaxAttempts = 3
$ServiceName = 'ZeroTierOneService'
$DefaultPlanet = Join-Path $env:ProgramData 'ZeroTier\One\planet'
$script:TmpPath = $null
$stoppedForReplace = $false

function Write-Ok([string]$m) { Write-Host ('[OK]   ' + $m) -ForegroundColor Green }
function Write-Note([string]$m) { Write-Host ('[INFO] ' + $m) }
function Write-Warn([string]$m) { Write-Host ('[WARN] ' + $m) -ForegroundColor Yellow }
function Write-Fail([string]$m) {
    Write-Host ('[FAIL] ' + $m) -ForegroundColor Red
    if ($script:TmpPath -and (Test-Path -LiteralPath $script:TmpPath)) {
        Remove-Item -LiteralPath $script:TmpPath -Force -ErrorAction SilentlyContinue
    }
    exit 1
}

function Test-Elevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Atomic replace on the same volume. File.Replace needs a backup file name on
# .NET Framework (a $null argument becomes an empty string and is rejected),
# so a throwaway one is used and deleted afterwards.
function Invoke-AtomicSwap([string]$src, [string]$dst) {
    $swap = $dst + '.replace.tmp'
    [System.IO.File]::Replace($src, $dst, $swap)
    if (Test-Path -LiteralPath $swap) {
        Remove-Item -LiteralPath $swap -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ('install-planet.ps1 v' + $ScriptVersion + ' (PowerShell ' + $PSVersionTable.PSVersion.ToString() + ')')

if ($ServerUrl -notmatch '^https?://') {
    Write-Fail 'ServerUrl must start with http:// or https://'
}

$elevated = Test-Elevated
$testMode = $false

if ([string]::IsNullOrWhiteSpace($Target)) {
    if (-not $elevated) {
        Write-Fail 'Administrator rights required. Open PowerShell as Administrator and re-run, or use -Target <path> for a test install.'
    }
    $planet = $DefaultPlanet
} else {
    $planet = [System.IO.Path]::GetFullPath($Target)
    $testMode = $true
    if (-not $elevated) {
        Write-Warn 'not running elevated: custom -Target mode, service restart may fail'
    }
}

Write-Note ('planet path : ' + $planet)
if ($testMode) { Write-Warn 'custom -Target given: TEST/ADVANCED mode, the default planet path is not used' }

$base = $ServerUrl.TrimEnd('/')
$url = $base + '/planet'
$headers = @{}
if ($Token -ne '') {
    $url = $url + '?token=' + [Uri]::EscapeDataString($Token)
    $headers['Authorization'] = 'Bearer ' + $Token
}

$dir = Split-Path -Parent $planet
if (-not (Test-Path -LiteralPath $dir)) {
    if ($testMode) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    } else {
        Write-Fail ('directory not found: ' + $dir + ' - is ZeroTier One installed?')
    }
}

# temp file lives in the target directory so the final rename stays on one volume
$tmp = Join-Path $dir ('.planet.download.' + [Guid]::NewGuid().ToString('N') + '.tmp')
$script:TmpPath = $tmp

$downloaded = $false
for ($i = 1; $i -le $MaxAttempts; $i++) {
    Write-Note ('downloading ' + $url + ' (attempt ' + $i + '/' + $MaxAttempts + ')')
    try {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $req = @{
            Uri             = $url
            OutFile         = $tmp
            UseBasicParsing = $true
            TimeoutSec      = 120
        }
        if ($headers.Count -gt 0) { $req['Headers'] = $headers }
        Invoke-WebRequest @req
        $downloaded = $true
        break
    } catch {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
        Write-Warn ('download attempt failed: ' + $_.Exception.Message)
        if ($i -lt $MaxAttempts) { Start-Sleep -Seconds 2 }
    }
}
if (-not $downloaded) {
    Write-Fail ('download failed after ' + $MaxAttempts + ' attempts; existing planet untouched')
}

$len = (Get-Item -LiteralPath $tmp).Length
if ($len -lt $MinBytes -or $len -gt $MaxBytes) {
    Write-Fail ('validation failed: ' + $len + ' bytes is outside ' + $MinBytes + '..' + $MaxBytes + ' (wrong page downloaded?); existing planet untouched')
}

$fs = [System.IO.File]::OpenRead($tmp)
try {
    $firstByte = $fs.ReadByte()
} finally {
    $fs.Dispose()
}
if ($firstByte -ne 1) {
    $hex = '0x' + ([int]$firstByte).ToString('X2')
    Write-Fail ('validation failed: not a planet file (first byte ' + $hex + ', expected 0x01); existing planet untouched')
}
Write-Ok ('format check passed: ' + $len + ' bytes, first byte 0x01')

$actualSha = (Get-FileHash -LiteralPath $tmp -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Note ('sha256: ' + $actualSha)

if ($Sha256 -ne '') {
    $want = ($Sha256 -replace '\s', '').ToLowerInvariant()
    if ($actualSha -ne $want) {
        Write-Fail ('validation failed: sha256 mismatch (expected ' + $want + '); existing planet untouched')
    }
    Write-Ok 'sha256 verified'
}

$planetExists = Test-Path -LiteralPath $planet
if ($planetExists) {
    $bak = $planet + '.bak.' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $planet -Destination $bak -Force
    Write-Ok ('backed up existing planet -> ' + $bak)
} else {
    Write-Note 'no planet at target yet; creating it'
}

if ($planetExists) {
    try {
        Invoke-AtomicSwap $tmp $planet
    } catch {
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if ($null -eq $svc -or $SkipRestart) {
            Write-Fail ('replace failed: ' + $_.Exception.Message + '. Close ZeroTier One (or stop ' + $ServiceName + ') and re-run.')
        }
        Write-Warn ('replace failed (' + $_.Exception.Message + '); stopping ' + $ServiceName + ' and retrying')
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        $stoppedForReplace = $true
        Start-Sleep -Seconds 2
        Invoke-AtomicSwap $tmp $planet
    }
} else {
    Move-Item -LiteralPath $tmp -Destination $planet -Force
}
$script:TmpPath = $null
Write-Ok ('installed planet -> ' + $planet)

if ($SkipRestart) {
    Write-Note 'service restart skipped (-SkipRestart)'
    if ($stoppedForReplace) {
        Start-Service -Name $ServiceName -ErrorAction SilentlyContinue
        Write-Warn ($ServiceName + ' was stopped for the replace and has been started again')
    }
} else {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        Write-Warn ('service ' + $ServiceName + ' not found (ZeroTier One not installed?). The planet file is in place and will be used on the next start.')
    } else {
        try {
            if ($svc.Status -eq 'Running') {
                Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            }
            Start-Sleep -Seconds 1
            Start-Service -Name $ServiceName -ErrorAction Stop
            (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
            Write-Ok ('restarted ' + $ServiceName)
        } catch {
            Write-Warn ('restart failed: ' + $_.Exception.Message)
            Write-Warn ('restart manually: net stop ' + $ServiceName + ' && net start ' + $ServiceName)
        }
    }
}

$cliCandidates = @()
if ($env:ProgramFiles) { $cliCandidates += (Join-Path $env:ProgramFiles 'ZeroTier\One\zerotier-cli.bat') }
$pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
if ($pf86) { $cliCandidates += (Join-Path $pf86 'ZeroTier\One\zerotier-cli.bat') }
$cli = 'zerotier-cli'
foreach ($c in $cliCandidates) {
    if (Test-Path -LiteralPath $c) { $cli = $c; break }
}

Write-Host ''
Write-Host 'Next steps:'
Write-Host ('  1) check status : "' + $cli + '" info')
Write-Host ('  2) join network : "' + $cli + '" join <NETWORK_ID>')
Write-Host '  <NETWORK_ID> comes from your self-hosted controller / admin (ZTNet -> Networks).'
Write-Host ('  rollback: copy ' + $planet + '.bak.<timestamp> back over ' + $planet + ' and restart ' + $ServiceName)
exit 0
