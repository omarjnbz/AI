# ================================================================
# Non Site-to-Site Connections — Server API (Nagios Integration)
# ================================================================
# WHAT:  Read-only HTTP API that pulls data from Nagios XI/Core
#        and serves it as JSON for the dashboard.
# SAFE:  This script only READS from Nagios API. It does NOT
#        modify, write, delete, or change anything.
# AUTH:  Token-based. Every request must include the header:
#        Authorization: Bearer <YOUR_TOKEN>
# ================================================================

# --- CONFIGURATION ---
$Port        = 8080
$BearerToken = "CHANGE-ME-TO-A-SECURE-TOKEN"    # Dashboard must send this same token

# --- NAGIOS CONFIGURATION ---
$NagiosBase  = "http://NAGIOS-SERVER-IP/nagios"  # Nagios Core base URL
$NagiosUser  = "nagiosadmin"                      # Nagios web UI username
$NagiosPass  = "nagiosadmin"                      # Nagios web UI password

# If using Nagios XI instead of Core, set this:
$NagiosXI       = $false                          # Set to $true for Nagios XI
$NagiosXIBase   = "http://NAGIOS-XI-IP/nagiosxi"  # Nagios XI base URL
$NagiosXIApiKey = "YOUR-NAGIOS-XI-API-KEY"         # Nagios XI API key (found in Admin > Manage API Keys)

# --- DATA SOURCE MODE ---
# "nagios"  = Pull from Nagios API (requires config above)
# "local"   = Read directly from Windows (WMI/CIM) — no Nagios needed
# "both"    = Nagios first, fall back to local if Nagios is unreachable
$DataSource = "both"

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
Write-Host " Data source: $DataSource"
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

# --- NAGIOS API HELPERS (read-only) ---

function Invoke-NagiosCore($endpoint) {
    $cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${NagiosUser}:${NagiosPass}"))
    try {
        $response = Invoke-RestMethod -Uri "${NagiosBase}${endpoint}" -Headers @{
            Authorization = "Basic $cred"
        } -TimeoutSec 10 -ErrorAction Stop
        return $response
    } catch {
        Write-Host "  Nagios Core request failed: $_"
        return $null
    }
}

function Invoke-NagiosXI($endpoint) {
    try {
        $sep = if ($endpoint -match "\?") { "&" } else { "?" }
        $response = Invoke-RestMethod -Uri "${NagiosXIBase}/api/v1${endpoint}${sep}apikey=${NagiosXIApiKey}" -TimeoutSec 10 -ErrorAction Stop
        return $response
    } catch {
        Write-Host "  Nagios XI request failed: $_"
        return $null
    }
}

function Invoke-Nagios($coreEndpoint, $xiEndpoint) {
    if ($NagiosXI) {
        return Invoke-NagiosXI $xiEndpoint
    } else {
        return Invoke-NagiosCore $coreEndpoint
    }
}

# --- DATA COLLECTORS: NAGIOS ---

function Get-HealthFromNagios {
    $result = Invoke-Nagios "/cgi-bin/statusjson.cgi?query=programstatus" "/system/status"
    if (-not $result) { return $null }

    if ($NagiosXI) {
        $running = if ($result.running) { "online" } else { "offline" }
        return @{
            status = $running
            uptime = $result.program_start
            cpu    = 0
            memory = 0
            diskIO = "N/A (Nagios XI)"
        }
    }

    $hostResult = Invoke-NagiosCore "/cgi-bin/statusjson.cgi?query=hostlist&details=true"
    $cpuVal  = 0
    $memVal  = 0
    $uptimeStr = "N/A"

    if ($hostResult -and $hostResult.data -and $hostResult.data.hostlist) {
        $hosts = $hostResult.data.hostlist.PSObject.Properties
        foreach ($h in $hosts) {
            $perf = $h.Value.perf_data
            if ($perf -match "cpu=(\d+)") { $cpuVal = [int]$Matches[1] }
            if ($perf -match "mem=(\d+)") { $memVal = [int]$Matches[1] }
        }
    }

    if ($result.data -and $result.data.programstatus) {
        $startTime = $result.data.programstatus.program_start
        if ($startTime) {
            $span = (Get-Date) - [DateTime]::Parse($startTime)
            $uptimeStr = "{0}d {1}h {2}m" -f $span.Days, $span.Hours, $span.Minutes
        }
    }

    $overall = "online"
    if ($cpuVal -ge 90 -or $memVal -ge 90) { $overall = "degraded" }

    return @{
        status = $overall
        uptime = $uptimeStr
        cpu    = $cpuVal
        memory = $memVal
        diskIO = "via Nagios"
    }
}

function Get-ConnectivityFromNagios {
    $result = Invoke-Nagios "/cgi-bin/statusjson.cgi?query=servicelist&details=true" "/objects/servicestatus?name=lk:connection"
    if (-not $result) { return $null }

    $activeCount = 0
    $totalCount  = 0

    if ($NagiosXI) {
        if ($result.recordcount) { $totalCount = $result.recordcount }
        if ($result.servicestatus) {
            foreach ($svc in $result.servicestatus) {
                if ($svc.current_state -eq 0) { $activeCount++ }
            }
        }
    } else {
        if ($result.data -and $result.data.servicelist) {
            $services = $result.data.servicelist.PSObject.Properties
            foreach ($host in $services) {
                $svcList = $host.Value.PSObject.Properties
                foreach ($svc in $svcList) {
                    $totalCount++
                    if ($svc.Value.status -eq 2) { $activeCount++ }
                }
            }
        }
    }

    $hostCount = Invoke-Nagios "/cgi-bin/statusjson.cgi?query=hostcount" "/objects/hoststatus"
    $agentTotal = 0
    if ($NagiosXI -and $hostCount.recordcount) {
        $agentTotal = $hostCount.recordcount
    } elseif ($hostCount -and $hostCount.data -and $hostCount.data.count) {
        $agentTotal = $hostCount.data.count.up + $hostCount.data.count.down + $hostCount.data.count.unreachable
    }

    return @{
        status            = if ($activeCount -gt 0) { "online" } else { "offline" }
        activeConnections = $activeCount
        totalAgents       = if ($agentTotal -gt 0) { $agentTotal } else { $totalCount }
        avgLatency        = "via Nagios"
        packetLoss        = "via Nagios"
        connectionType    = "Non Site-to-Site"
    }
}

function Get-LogsFromNagios {
    $result = Invoke-Nagios "/cgi-bin/archivejson.cgi?query=alertlist&starttime=-3600&endtime=%2B0" "/objects/logentries?type=alert"
    if (-not $result) { return $null }

    $logs = @()

    if ($NagiosXI -and $result.logentry) {
        foreach ($entry in ($result.logentry | Select-Object -First 10)) {
            $statusVal = switch ($entry.state_type) {
                "HARD"  { if ($entry.state -eq 0) { "success" } else { "failed" } }
                "SOFT"  { "pending" }
                default { "success" }
            }
            $logs += @{
                timestamp = $entry.entry_time
                vendor    = $entry.host_name
                action    = $entry.name + " - " + $entry.status_text
                status    = $statusVal
            }
        }
    } elseif ($result.data -and $result.data.alertlist) {
        foreach ($alert in ($result.data.alertlist | Select-Object -First 10)) {
            $statusVal = switch ($alert.state) {
                0 { "success" }
                1 { "pending" }
                2 { "failed" }
                default { "pending" }
            }
            $logs += @{
                timestamp = if ($alert.timestamp) { $alert.timestamp } else { (Get-Date).ToString("yyyy-MM-dd HH:mm:ss") }
                vendor    = if ($alert.host_name) { $alert.host_name } else { "Unknown" }
                action    = if ($alert.description) { $alert.description.Substring(0, [Math]::Min(60, $alert.description.Length)) } else { $alert.name }
                status    = $statusVal
            }
        }
    }

    return @{
        status = "online"
        logs   = $logs
    }
}

# --- DATA COLLECTORS: LOCAL (Windows WMI fallback) ---

function Get-HealthLocal {
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

function Get-ConnectivityLocal {
    $tcpConnections = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue
    $activeCount    = ($tcpConnections | Measure-Object).Count
    $allTcp         = Get-NetTCPConnection -ErrorAction SilentlyContinue
    $totalCount     = ($allTcp | Measure-Object).Count

    $ping = Test-Connection -ComputerName "8.8.8.8" -Count 2 -ErrorAction SilentlyContinue
    $avgLatency = if ($ping) {
        "{0}ms" -f [math]::Round(($ping | Measure-Object -Property Latency -Average).Average)
    } else { "N/A" }

    return @{
        status            = "online"
        activeConnections = $activeCount
        totalAgents       = $totalCount
        avgLatency        = $avgLatency
        packetLoss        = "0.00%"
        connectionType    = "Non Site-to-Site"
    }
}

function Get-LogsLocal {
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
    return @{ status = "online"; logs = $logs }
}

# --- SMART DATA GETTER (Nagios -> Local fallback) ---

function Get-Data($type) {
    if ($DataSource -eq "nagios" -or $DataSource -eq "both") {
        $nagiosResult = switch ($type) {
            "health"       { Get-HealthFromNagios }
            "connectivity" { Get-ConnectivityFromNagios }
            "logs"         { Get-LogsFromNagios }
        }
        if ($nagiosResult) {
            Write-Host "    [source: nagios]"
            return $nagiosResult
        }
        if ($DataSource -eq "nagios") {
            Write-Host "    [source: nagios FAILED, no fallback]"
            return @{ status = "offline"; error = "Nagios unreachable" }
        }
        Write-Host "    [source: nagios failed, falling back to local]"
    }

    $localResult = switch ($type) {
        "health"       { Get-HealthLocal }
        "connectivity" { Get-ConnectivityLocal }
        "logs"         { Get-LogsLocal }
    }
    Write-Host "    [source: local]"
    return $localResult
}

# --- HEARTBEAT ---

function Get-HeartbeatData {
    $nagiosAlive = $false
    if ($DataSource -eq "nagios" -or $DataSource -eq "both") {
        $check = Invoke-Nagios "/cgi-bin/statusjson.cgi?query=programstatus" "/system/status"
        $nagiosAlive = ($null -ne $check)
    }

    return @{
        alive         = $true
        timestamp     = (Get-Date).ToString("yyyy-MM-ddTHH:mm:ss")
        nagiosAlive   = $nagiosAlive
        dataSource    = $DataSource
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

        if ($method -eq "OPTIONS") {
            Send-Json $context @{ ok = $true }
            continue
        }

        if (-not (Test-Auth $context)) {
            Send-Json $context @{ error = "Unauthorized" } 401
            Write-Host "  -> 401 Unauthorized"
            continue
        }

        switch ($path) {
            "/api/heartbeat" {
                $data = Get-HeartbeatData
                Send-Json $context $data
                Write-Host "  -> 200 heartbeat"
            }
            "/api/health" {
                $data = Get-Data "health"
                Send-Json $context $data
                Write-Host "  -> 200 health"
            }
            "/api/connectivity" {
                $data = Get-Data "connectivity"
                Send-Json $context $data
                Write-Host "  -> 200 connectivity"
            }
            "/api/logs" {
                $data = Get-Data "logs"
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
