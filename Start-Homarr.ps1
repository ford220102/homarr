<#
.SYNOPSIS
Starts Homarr for Windows from a portable package.

.DESCRIPTION
Starts a local Microsoft Garnet instance, runs SQLite migrations, starts the
Homarr Next.js server and stores generated secrets outside the installation
directory. Services are bound to 127.0.0.1 by default.
#>
[CmdletBinding()]
param(
    [string]$DataPath,
    [switch]$NoWait,
    [switch]$Stop,
    [int]$HealthTimeoutSeconds = 120
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($DataPath)) {
    if ([string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $DataPath = Join-Path $env:TEMP "Homarr"
    } else {
        $DataPath = Join-Path $env:LOCALAPPDATA "Homarr"
    }
}

$Root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Root)) {
    $Root = (Get-Location).Path
}
$Root = (Resolve-Path -LiteralPath $Root).Path

$NodeExe = Join-Path $Root "runtime\node\node.exe"
$GarnetExe = Join-Path $Root "runtime\garnet\net10.0\GarnetServer.exe"
$ServerScript = Join-Path $Root "apps\nextjs\server.js"
$MigrationScript = Join-Path $Root "db\migrations\sqlite\migrate.cjs"
$MigrationsFolder = Join-Path $Root "db\migrations\sqlite"

$DatabasePath = Join-Path $DataPath "db\homarr.db"
$LogDirectory = Join-Path $DataPath "logs"
$SecretDirectory = Join-Path $DataPath "secrets"
$PidFile = Join-Path $DataPath "pids.json"

function Write-Status {
    param([string]$Message)
    Write-Host "[Homarr] $Message"
}

function Test-RedisCompatibleService {
    param(
        [string]$HostName,
        [int]$Port
    )

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $client.Connect($HostName, $Port)
        $stream = $client.GetStream()
        $stream.ReadTimeout = 2000
        $stream.WriteTimeout = 2000
        $ping = [System.Text.Encoding]::ASCII.GetBytes("PING`r`n")
        $stream.Write($ping, 0, $ping.Length)
        $buffer = [byte[]]::new(64)
        $read = $stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) {
            return $false
        }
        $response = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read)
        return $response.Trim() -eq "+PONG"
    } catch {
        return $false
    } finally {
        $client.Dispose()
    }
}

function Get-StoredSecret {
    param(
        [string]$Name,
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        $value = (Get-Content -LiteralPath $Path -Raw).Trim()
        if ($value -match "^[0-9a-fA-F]{64}$") {
            return $value
        }
        throw "Stored secret '$Name' is invalid: $Path"
    }

    $bytes = [byte[]]::new(32)
    [System.Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $value = [Convert]::ToHexString($bytes).ToLowerInvariant()

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    Set-Content -LiteralPath $Path -Value $value -NoNewline -Encoding ascii

    try {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetAccessRuleProtection($true, $false)
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $identity,
            "FullControl",
            "Allow"
        )
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $Path -AclObject $acl
    } catch {
        throw "Could not restrict ACL for secret file '$Path': $($_.Exception.Message)"
    }

    return $value
}

function Get-VerifiedManagedProcess {
    param(
        [object]$Entry,
        [string]$ExpectedPath
    )

    if ($null -eq $Entry) {
        return $null
    }

    $processId = $null
    $expectedStartTime = $null
    $storedPath = $null

    if ($Entry -is [int] -or $Entry -is [long]) {
        $processId = [int]$Entry
    } elseif ($Entry -is [string]) {
        if ($Entry -notmatch "^[0-9]+$") {
            throw "Invalid process id in state file: $Entry"
        }
        $processId = [int]$Entry
    } else {
        $processId = [int]$Entry.Id
        $expectedStartTime = $Entry.StartTime
        $storedPath = $Entry.Path
    }

    if ($processId -le 0) {
        return $null
    }

    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    if (-not $process) {
        return $null
    }

    $actualPath = $null
    try {
        $actualPath = $process.Path
    } catch {
        $actualPath = $null
    }

    if ([string]::IsNullOrWhiteSpace($actualPath) -or
        -not [string]::Equals($actualPath, $ExpectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to stop PID $processId because '$actualPath' is not '$ExpectedPath'."
    }

    if (-not [string]::IsNullOrWhiteSpace($storedPath) -and
        -not [string]::Equals($storedPath, $ExpectedPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to stop PID $processId because the stored executable path is invalid."
    }

    if ([string]::IsNullOrWhiteSpace($expectedStartTime)) {
        throw "Refusing to stop PID $processId because process start time is missing."
    }

    $actualStartTime = $process.StartTime.ToUniversalTime().ToString("o")
    if ($actualStartTime -ne $expectedStartTime) {
        throw "Refusing to stop PID $processId because the process start time does not match."
    }

    return $process
}

function Stop-ManagedProcesses {
    if (-not (Test-Path -LiteralPath $PidFile)) {
        return
    }

    try {
        $state = Get-Content -LiteralPath $PidFile -Raw | ConvertFrom-Json
    } catch {
        throw "Could not read process state file: $PidFile"
    }

    $entries = @(
        @{ Name = "Homarr"; Entry = $state.Homarr; ExpectedPath = $NodeExe }
        @{ Name = "Garnet"; Entry = $state.Garnet; ExpectedPath = $GarnetExe }
    )

    $processesToStop = @()
    foreach ($item in $entries) {
        $process = Get-VerifiedManagedProcess -Entry $item.Entry -ExpectedPath $item.ExpectedPath
        if ($process) {
            $processesToStop += @{ Name = $item.Name; Process = $process }
        }
    }

    foreach ($item in $processesToStop) {
        $process = $item.Process
        Write-Status "Stopping $($item.Name) (PID $($process.Id))..."
        Stop-Process -Id $process.Id -Force -ErrorAction Stop
        Wait-Process -Id $process.Id -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
}

function Show-RecentLogs {
    foreach ($logPath in @(
        (Join-Path $LogDirectory "homarr.stdout.log"),
        (Join-Path $LogDirectory "homarr.stderr.log"),
        (Join-Path $LogDirectory "garnet.stdout.log"),
        (Join-Path $LogDirectory "garnet.stderr.log")
    )) {
        if (Test-Path -LiteralPath $logPath) {
            Write-Host "===== $logPath ====="
            Get-Content -LiteralPath $logPath -Tail 80 -ErrorAction SilentlyContinue
        }
    }
}

if ($Stop) {
    Stop-ManagedProcesses
    Write-Status "Stopped."
    exit 0
}

foreach ($requiredPath in @($NodeExe, $ServerScript, $MigrationScript, $GarnetExe)) {
    if (-not (Test-Path -LiteralPath $requiredPath)) {
        throw "Missing required file: $requiredPath"
    }
}

New-Item -ItemType Directory -Force -Path (Split-Path -Parent $DatabasePath) | Out-Null
New-Item -ItemType Directory -Force -Path $LogDirectory | Out-Null
New-Item -ItemType Directory -Force -Path $SecretDirectory | Out-Null

$AuthSecret = Get-StoredSecret -Name "AUTH_SECRET" -Path (Join-Path $SecretDirectory "auth-secret.txt")
$EncryptionKey = Get-StoredSecret -Name "SECRET_ENCRYPTION_KEY" -Path (Join-Path $SecretDirectory "encryption-key.txt")

$env:NODE_ENV = "production"
$env:SKIP_ENV_VALIDATION = "true"
$env:DB_DIALECT = "sqlite"
$env:DB_DRIVER = "better-sqlite3"
$env:DB_URL = $DatabasePath
$env:AUTH_SECRET = $AuthSecret
$env:SECRET_ENCRYPTION_KEY = $EncryptionKey
$env:AUTH_PROVIDERS = "credentials"
$env:HOSTNAME = "127.0.0.1"
$env:PORT = "3000"
$env:REDIS_IS_EXTERNAL = "true"
$env:REDIS_HOST = "127.0.0.1"
$env:REDIS_PORT = "6379"
Remove-Item Env:CI -ErrorAction SilentlyContinue
Remove-Item Env:DISABLE_REDIS_LOGS -ErrorAction SilentlyContinue

$startedGarnet = $false
$garnetProcess = $null
$homarrProcess = $null
$keepProcessesRunning = $false

try {
    $DotnetRoot = Join-Path $Root "runtime\dotnet"
    if (Test-Path -LiteralPath (Join-Path $DotnetRoot "dotnet.exe")) {
        $env:DOTNET_ROOT = $DotnetRoot
        if ([string]::IsNullOrWhiteSpace($env:PATH)) {
            $env:PATH = $DotnetRoot
        } else {
            $env:PATH = "$DotnetRoot;$env:PATH"
        }
    }

    if (-not (Test-RedisCompatibleService -HostName "127.0.0.1" -Port 6379)) {
        Write-Status "Starting Microsoft Garnet on 127.0.0.1:6379..."
        $garnetStdout = Join-Path $LogDirectory "garnet.stdout.log"
        $garnetStderr = Join-Path $LogDirectory "garnet.stderr.log"
        Remove-Item -LiteralPath $garnetStdout, $garnetStderr -Force -ErrorAction SilentlyContinue

        $garnetProcess = Start-Process -FilePath $GarnetExe `
            -ArgumentList "--bind", "127.0.0.1", "--port", "6379" `
            -WorkingDirectory (Split-Path -Parent $GarnetExe) `
            -PassThru -NoNewWindow `
            -RedirectStandardOutput $garnetStdout `
            -RedirectStandardError $garnetStderr

        $startedGarnet = $true
        $garnetReady = $false
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            Start-Sleep -Seconds 1
            if (Test-RedisCompatibleService -HostName "127.0.0.1" -Port 6379) {
                $garnetReady = $true
                break
            }
            if ($garnetProcess.HasExited) {
                break
            }
        }

        if (-not $garnetReady) {
            Show-RecentLogs
            throw "Microsoft Garnet did not start on 127.0.0.1:6379"
        }
    } else {
        Write-Status "Garnet is already listening on 127.0.0.1:6379."
    }

    Write-Status "Running SQLite migrations..."
    & $NodeExe $MigrationScript $MigrationsFolder
    if ($LASTEXITCODE -ne 0) {
        throw "SQLite migration failed with exit code $LASTEXITCODE"
    }

    Write-Status "Starting Homarr on http://127.0.0.1:3000..."
    $homarrStdout = Join-Path $LogDirectory "homarr.stdout.log"
    $homarrStderr = Join-Path $LogDirectory "homarr.stderr.log"
    Remove-Item -LiteralPath $homarrStdout, $homarrStderr -Force -ErrorAction SilentlyContinue

    $homarrProcess = Start-Process -FilePath $NodeExe `
        -ArgumentList @("`"$ServerScript`"") `
        -WorkingDirectory $Root `
        -PassThru -NoNewWindow `
        -RedirectStandardOutput $homarrStdout `
        -RedirectStandardError $homarrStderr

    $liveStatus = "NO_RESPONSE"
    $readyStatus = "NO_RESPONSE"
    $allHealthy = $false
    $deadline = (Get-Date).AddSeconds($HealthTimeoutSeconds)

    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 1

        try {
            $liveResponse = Invoke-WebRequest -Uri "http://127.0.0.1:3000/api/health/live" -UseBasicParsing -TimeoutSec 3
            $liveStatus = [int]$liveResponse.StatusCode
        } catch {
            if ($_.Exception.Response) {
                $liveStatus = [int]$_.Exception.Response.StatusCode
            }
        }

        try {
            $readyResponse = Invoke-WebRequest -Uri "http://127.0.0.1:3000/api/health/ready" -UseBasicParsing -TimeoutSec 3
            $readyStatus = [int]$readyResponse.StatusCode
        } catch {
            if ($_.Exception.Response) {
                $readyStatus = [int]$_.Exception.Response.StatusCode
            }
        }

        Write-Host "HOMARR_HEALTH_LIVE=$liveStatus"
        Write-Host "HOMARR_HEALTH_READY=$readyStatus"

        if ($liveStatus -eq 200 -and $readyStatus -eq 200) {
            $allHealthy = $true
            break
        }

        if ($homarrProcess.HasExited) {
            break
        }
    }

    if (-not $allHealthy) {
        Show-RecentLogs
        throw "Homarr health check failed: live=$liveStatus ready=$readyStatus"
    }

    Write-Status "Homarr is running at http://127.0.0.1:3000"
    Write-Status "Press Ctrl+C to stop. Data is stored in: $DataPath"

    $garnetState = if ($startedGarnet -and $garnetProcess) {
        @{
            Id = $garnetProcess.Id
            StartTime = $garnetProcess.StartTime.ToUniversalTime().ToString("o")
            Path = $GarnetExe
        }
    } else {
        $null
    }

    $homarrState = @{
        Id = $homarrProcess.Id
        StartTime = $homarrProcess.StartTime.ToUniversalTime().ToString("o")
        Path = $NodeExe
    }

    @{
        Garnet = $garnetState
        Homarr = $homarrState
        DataPath = $DataPath
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $PidFile -Encoding utf8

    if ($NoWait) {
        $keepProcessesRunning = $true
        exit 0
    }

    while ($true) {
        Start-Sleep -Seconds 1
        if ($homarrProcess.HasExited) {
            throw "Homarr exited unexpectedly with code $($homarrProcess.ExitCode)"
        }
    }
} finally {
    if (-not $keepProcessesRunning) {
        if ($homarrProcess -and -not $homarrProcess.HasExited) {
            Stop-Process -Id $homarrProcess.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $homarrProcess.Id -ErrorAction SilentlyContinue
        }

        if ($startedGarnet -and $garnetProcess -and -not $garnetProcess.HasExited) {
            Stop-Process -Id $garnetProcess.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $garnetProcess.Id -ErrorAction SilentlyContinue
        }

        Remove-Item -LiteralPath $PidFile -Force -ErrorAction SilentlyContinue
    }
}
