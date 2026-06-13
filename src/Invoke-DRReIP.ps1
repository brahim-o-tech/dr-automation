#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Automatically re-IPs a server during a DR isolated bubble exercise.

.DESCRIPTION
    Reads a CSV file containing source (production) and target (DR) IP configurations
    and applies the DR network settings to the local server.

    Designed for DR exercises using an isolated VMware bubble:
    - VMs are cloned from NetApp SnapMirror replicated volumes
    - The isolated bubble has its own AD and DNS (no connection to production)
    - Testers access VMs via VMware console
    - After the exercise, the bubble is destroyed and SnapMirror resumes

    Workflow:
      1. Backup current IP config via netsh dump
      2. Read DR network config from CSV
      3. Match current hostname against CSV entries
      4. Remove production IP configuration
      5. Apply DR site IP, subnet, gateway
      6. Set DR DNS servers
      7. Handle iSCSI/Storage adapters separately (no gateway, no DNS)

.PARAMETER CsvPath
    Path to the DR network configuration CSV file.

.PARAMETER DnsServers
    DNS server IP addresses for the DR site.

.PARAMETER BackupPath
    Directory for the netsh config backup and transcript.

.PARAMETER Simulate
    Switch. Simulates all changes with -WhatIf logging.
    Always run with -Simulate first.

.EXAMPLE
    # Simulate first — always
    .\Invoke-DRReIP.ps1 -Simulate

.EXAMPLE
    .\Invoke-DRReIP.ps1 `
        -CsvPath    "C:\Temp\DR-Exercise\DR-network_config.csv" `
        -DnsServers @("10.20.0.10","10.20.0.11")

.NOTES
    Author      : Brahim O.
    Version     : 1.1
    Requires    : PowerShell 5.1+, Administrator rights
    Context     : DR isolated bubble exercise — VMware + NetApp SnapMirror

    CSV columns:
      Hostname, NIC_Name, PROD_IP, PROD_Mask, PROD_GW,
      DR_IP, DR_Mask, DR_GW, ADM_GW

    REVERT: Destroy the isolated bubble — SnapMirror resync
    restores production data and network config automatically.
#>

[CmdletBinding()]
param(
    [string]$CsvPath    = "C:\Temp\DR-Exercise\DR-network_config.csv",
    [string[]]$DnsServers = @("10.20.0.10"),
    [string]$BackupPath = "C:\Temp\DR-Exercise",
    [switch]$Simulate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$computer       = $env:COMPUTERNAME
$timestamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$transcriptPath = Join-Path $BackupPath "$computer-DR-ReIP-$timestamp.log"
$backupFile     = Join-Path $BackupPath "$computer-IP-Backup-$timestamp.txt"

if (-not (Test-Path $BackupPath)) {
    New-Item -ItemType Directory -Path $BackupPath -Force | Out-Null
}

Start-Transcript -Path $transcriptPath

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red    }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green  }
        "WARN"    { Write-Host $entry -ForegroundColor Yellow }
        "SIM"     { Write-Host $entry -ForegroundColor Cyan   }
        default   { Write-Host $entry }
    }
}

function Get-PrefixLength {
    param([string]$SubnetMask)
    return ([System.Net.IPAddress]::Parse($SubnetMask).GetAddressBytes() |
        ForEach-Object { [System.Convert]::ToString($_, 2) } |
        ForEach-Object { $_.Replace('0','') } |
        Measure-Object -Property Length -Sum).Sum
}

Write-Log "DR Re-IP starting on [$computer]"
Write-Log "Simulate : $($Simulate.IsPresent) | DNS: $($DnsServers -join ', ')"

if ($Simulate) { Write-Log "SIMULATION MODE — no changes will be applied." "SIM" }

# Step 1 — Backup
try {
    $netshOutput = netsh -c interface dump
    $netshOutput | Out-File -FilePath $backupFile -Encoding UTF8
    Write-Log "Backup saved: $backupFile" "SUCCESS"
}
catch { Write-Log "Backup failed: $($_.Exception.Message)" "WARN" }

# Step 2 — Import CSV
if (-not (Test-Path $CsvPath)) {
    Write-Log "CSV not found: $CsvPath" "ERROR"
    Stop-Transcript; exit 1
}

$networkConfigs = Import-Csv -Path $CsvPath
Write-Log "Loaded $($networkConfigs.Count) entries from CSV." "SUCCESS"

# Step 3 — Process matching entries
$matched = $false

foreach ($config in $networkConfigs) {

    if ($config.Hostname -ne $computer) { continue }

    $matched     = $true
    $adapterName = $config.NIC_Name

    # FIX BUG 1 — No hyphens in variable names
    $targetIP      = $config.DR_IP
    $targetMask    = $config.DR_Mask
    $targetGateway = $config.DR_GW
    $prodIP        = $config.PROD_IP
    $admGateway    = $config.ADM_GW

    Write-Log "Processing NIC: $adapterName"

    $adapter = Get-NetAdapter -Name $adapterName -ErrorAction SilentlyContinue
    if (-not $adapter) {
        Write-Log "Adapter '$adapterName' not found — skipping." "WARN"
        continue
    }

    # Remove prod IP
    $currentIPs = @(Get-NetIPAddress -InterfaceIndex $adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)

    foreach ($currentIP in $currentIPs) {
        if ($currentIP.IPAddress -eq $prodIP) {
            Write-Log "Removing production IP: $prodIP"

            if ($Simulate) {
                Write-Log "SIMULATION: Flush IP + Remove-NetRoute $admGateway" "SIM"
            }
            else {
                Set-NetIPInterface -InterfaceIndex $adapter.InterfaceIndex -Dhcp Enabled
                Start-Sleep -Seconds 5

                # FIX BUG 2 — Correct Where-Object scriptblock
                $gatewayToRemove = Get-NetRoute `
                    -InterfaceIndex $adapter.InterfaceIndex `
                    -AddressFamily IPv4 `
                    -ErrorAction SilentlyContinue |
                    Where-Object { $_.NextHop -eq $admGateway }

                if ($gatewayToRemove) {
                    Remove-NetRoute `
                        -InterfaceIndex $adapter.InterfaceIndex `
                        -NextHop        $admGateway `
                        -Confirm:$false `
                        -ErrorAction    SilentlyContinue
                    Write-Log "Gateway removed: $admGateway" "SUCCESS"
                }
            }
        }
    }

    if (-not $targetIP -or -not $targetMask) {
        Write-Log "Invalid DR config for '$adapterName' — skipping." "WARN"
        continue
    }

    $prefixLength     = Get-PrefixLength -SubnetMask $targetMask
    $isStorageAdapter = $adapterName -like "iSCSI*" -or $adapterName -like "Storage*"

    if ($isStorageAdapter) {
        if ($Simulate) {
            Write-Log "SIMULATION: New-NetIPAddress $targetIP/$prefixLength on $adapterName (storage — no GW/DNS)" "SIM"
        }
        else {
            New-NetIPAddress `
                -InterfaceIndex $adapter.InterfaceIndex `
                -IPAddress      $targetIP `
                -PrefixLength   $prefixLength
        }
        Write-Log "Storage NIC '$adapterName' — IP: $targetIP/$prefixLength" "SUCCESS"
    }
    else {
        if ($Simulate) {
            Write-Log "SIMULATION: New-NetIPAddress $targetIP/$prefixLength GW:$targetGateway on $adapterName" "SIM"
            Write-Log "SIMULATION: Set-DnsClientServerAddress $($DnsServers -join ',') on $adapterName" "SIM"
        }
        else {
            New-NetIPAddress `
                -InterfaceIndex $adapter.InterfaceIndex `
                -IPAddress      $targetIP `
                -PrefixLength   $prefixLength `
                -DefaultGateway $targetGateway

            Set-DnsClientServerAddress `
                -InterfaceIndex  $adapter.InterfaceIndex `
                -ServerAddresses $DnsServers
        }
        Write-Log "NIC '$adapterName' — IP: $targetIP/$prefixLength GW: $targetGateway" "SUCCESS"
    }
}

if (-not $matched) {
    Write-Log "No CSV entries matched hostname '$computer'." "WARN"
}

Write-Log "DR Re-IP completed on [$computer]." "SUCCESS"
Stop-Transcript
