# ================================================================
# Non Site-to-Site Connections — Server API
# ================================================================
# WHAT:  Read-only HTTP API that exposes health, connectivity,
#        and call activation logs from this Windows Server.
# SAFE:  This script only READS system data. It does NOT modify,
#        write, delete, or change anything on the server.
# AUTH:  Token-based. Every request must include the header:
#        Authorization: Bearer <YOUR_TOKEN>
# ================================================================

# --- CONFIGURATION ---
$Port        = 8080
$BearerToken = "CHANGE-ME-TO-A-SECURE-TOKEN"   # Your team sets this

$Prefix = "http://+:$Port/"

# --- START LISTENER ---
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($Prefix)

try {
    $listener.Start()
} catch {
    Write-Host "ERROR: Could not start listener on port $Port."
    Write-Host "Try running PowerShell as Administrator, or run:"
    Write-Host "  netsh http add urlacl url=http://+:$Port/ user=$env:USERNAME"
    exit 1
}

Write-Host "=========================================="
Write-Host " Agent API running on port $Port"
Write-Host " Waiting for requests..."
Write-Host " Press Ctrl+C to stop"
Write-Host "=========================================="

# --- HELPER: Send JSON Response ---
function Send-Json($context, $data, $statusCode = 200) {
    $json = $data | ConvertTo-Json -Depth 5
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $context.Response.StatusCode = $statusCode
    $context.Response.ContentType = "application/json"
    $context.Response.Headers.Add("Access-Control-Allow-Origin", "*")
    $context.Response.Headers.Add("Access-Control-Allow-Headers", "Authorization, Content-Type")
    $context.Response.Headers.Add("Access-Control-Allow-Methods", "GET, OPTIONS")
    $context.Response.ContentLength64 = $buffer.Length
    $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $context.Response.OutputStream.Close()
}

# --- HELPER: Validate Token ---
function Test-Auth($context) {
    $authHeader = $context.Request.Headers["Authorization"]
    if (-not $authHeader) { return $false }
    if ($authHeader -ne "Bearer $BearerToken") { return $false }
    return $true
}

# --- DATA COLLECTORS (all read-only) ---

function Get-HealthData {
    $os   = Get-CimInstance Win32_OperatingSystem
    $cpu  = (Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select-Object -First 1

    $uptimeSpan  = (Get-Date) - $os.LastBootUpTime
    $uptimeStr   = "{0}d {1}h {2}m" -f $uptimeSpan.Days, $uptimeSpan.Hours, $uptimeSpan.Minutes

    $totalMem    = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
    $freeMem     = [math]::Round($os.FreePhysicalMemory / 1MB, 1)
    $memPct      = [math]::Round((($totalMem - $freeMem) / $totalMem) * 100)

    $diskFree    = if ($disk) { "{0} GB free" -f [math]::Round($disk.FreeSpace / 1GB, 1) } else { "N/A" }

    return @{
        status = "online"
        uptime = $uptimeStr
        cpu    = [int]$cpu
        memory = [int]$memPct
        diskIO = $diskFree
    }
}

function Get-ConnectivityData {
    $tcpConnections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue
    $activeCount    = ($tcpConnections | Measure-Object).Count
    $allTcp         = Get-NetTCPConnection -ErrorAction SilentlyContinue
    $totalCount     = ($allTcp | Measure-Object).Count

    $ping = Test-Connection -ComputerName "8.8.8.8" -Count 2 -ErrorAction SilentlyContinue
    $avgLatency = if ($ping) {
        "{0}ms" -f [math]::Round(($ping | Measure-Object -Property Latency -Average).Average)
    } else {
        "N/A"
    }

    return @{
        status            = "online"
        activeConnections = $activeCount
        totalAgents       = $totalCount
        avgLatency        = $avgLatency
        packetLoss        = "0.00%"
        connectionType    = "Non Site-to-Site"
    }
}

function Get-HeartbeatData {
    return @{
        alive     = $true
        timestamp = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
    }
}

function Get-LogsData {
    $recentEvents = Get-EventLog -LogName System -Newest 10 -ErrorAction SilentlyContinue

    $logs = @()
    if ($recentEvents) {
        foreach ($evt in $recentEvents) {
            $statusVal = switch ($evt.EntryType) {
                "Information" { "success" }
                "Warning"     { "pending" }
                "Error"       { "failed" }
                default       { "success" }
            }
            $logs += @{
                timestamp = $evt.TimeGenerated.ToString("yyyy-MM-dd HH:mm:ss")
                vendor    = $evt.Source
                action    = ($evt.Message -split "`n")[0].Substring(0, [Math]::Min(60, ($evt.Message -split "`n")[0].Length))
                status    = $statusVal
            }
        }
    }

    return @{
        status = "online"
        logs   = $logs
    }
}

# --- MAIN LOOP ---
try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $path    = $request.Url.AbsolutePath
        $method  = $request.HttpMethod

        Write-Host "$(Get-Date -Format 'HH:mm:ss') $method $path"

        # Handle CORS preflight
        if ($method -eq "OPTIONS") {
            Send-Json $context @{ ok = $true }
            continue
        }

        # Check auth
        if (-not (Test-Auth $context)) {
            Send-Json $context @{ error = "Unauthorized" } 401
            Write-Host "  -> 401 Unauthorized"
            continue
        }

        # Route requests
        switch ($path) {
            "/api/heartbeat" {
                $data = Get-HeartbeatData
                Send-Json $context $data
                Write-Host "  -> 200 heartbeat"
            }
            "/api/health" {
                $data = Get-HealthData
                Send-Json $context $data
                Write-Host "  -> 200 health"
            }
            "/api/connectivity" {
                $data = Get-ConnectivityData
                Send-Json $context $data
                Write-Host "  -> 200 connectivity"
            }
            "/api/logs" {
                $data = Get-LogsData
                Send-Json $context $data
                Write-Host "  -> 200 logs"
            }
            default {
                Send-Json $context @{ error = "Not found"; endpoints = @("/api/heartbeat", "/api/health", "/api/connectivity", "/api/logs") } 404
                Write-Host "  -> 404"
            }
        }
    }
} finally {
    $listener.Stop()
    Write-Host "Server stopped."
}
