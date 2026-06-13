#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Exports network configuration from one or more remote servers to CSV.

.DESCRIPTION
    Connects to each remote server via WinRM and collects:
    - Network adapter name and interface index
    - IPv4 address and prefix length
    - Default gateway
    - DNS server addresses

    Output CSV is used as input for Invoke-DRReIP.ps1 during DR exercises.

.PARAMETER ComputerName
    One or more remote server names or IPs to collect configuration from.

.PARAMETER InputFile
    Path to a text file containing one server name per line.

.PARAMETER OutputPath
    Path for the output CSV file.
    Defaults to .\NetworkConfig-<timestamp>.csv

.EXAMPLE
    .\Export-NetworkConfig.ps1 -ComputerName "SRV01","SRV02","SRV03"

.EXAMPLE
    .\Export-NetworkConfig.ps1 -InputFile "C:\DR\servers.txt" -OutputPath "C:\DR\NetworkConfig.csv"

.NOTES
    Author      : Brahim O.
    Version     : 1.0
    Requires    : PowerShell 5.1+, WinRM enabled on target servers
    Context     : DR exercise preparation — run before isolated bubble test
#>

[CmdletBinding(DefaultParameterSetName = 'Direct')]
param(
    [Parameter(ParameterSetName = 'Direct')]
    [string[]]$ComputerName = @(),

    [Parameter(ParameterSetName = 'File')]
    [ValidateScript({ Test-Path $_ })]
    [string]$InputFile,

    [string]$OutputPath = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $OutputPath) {
    $OutputPath = ".\NetworkConfig-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [$Level] $Message"
    switch ($Level) {
        "ERROR"   { Write-Host $entry -ForegroundColor Red    }
        "SUCCESS" { Write-Host $entry -ForegroundColor Green  }
        "WARN"    { Write-Host $entry -ForegroundColor Yellow }
        default   { Write-Host $entry }
    }
}

$computers = [System.Collections.Generic.List[string]]::new()

switch ($PSCmdlet.ParameterSetName) {
    'Direct' {
        if ($ComputerName.Count -eq 0) {
            throw "No computer names provided. Use -ComputerName or -InputFile."
        }
        $ComputerName | ForEach-Object { $computers.Add($_) }
    }
    'File' {
        Get-Content $InputFile |
            Where-Object { $_ -match '\S' } |
            ForEach-Object { $computers.Add($_.Trim()) }
        Write-Log "Loaded $($computers.Count) server(s) from file." "SUCCESS"
    }
}

if ($computers.Count -eq 0) {
    Write-Log "No servers to process. Exiting." "WARN"
    exit 0
}

Write-Log "Servers to export: $($computers.Count)"

$results = [System.Collections.Generic.List[PSCustomObject]]::new()

for ($i = 0; $i -lt $computers.Count; $i++) {
    $machine = $computers[$i]

    Write-Progress `
        -Activity        "Collecting network configuration..." `
        -Status          "Processing $machine ($($i+1) of $($computers.Count))" `
        -PercentComplete ([int](($i + 1) / $computers.Count * 100))

    try {
        Write-Log "Querying: $machine"

        $networkAdapters = Invoke-Command -ComputerName $machine -ScriptBlock {
            Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
        } -ErrorAction Stop

        foreach ($adapter in $networkAdapters) {
            $interfaceId = $adapter.InterfaceIndex
            $adapterName = $adapter.Name

            $ipConfig = Invoke-Command -ComputerName $machine -ScriptBlock {
                Get-NetIPAddress -InterfaceIndex $using:interfaceId -AddressFamily IPv4 -ErrorAction SilentlyContinue
            }

            $dnsServers = Invoke-Command -ComputerName $machine -ScriptBlock {
                Get-DnsClientServerAddress -InterfaceIndex $using:interfaceId -AddressFamily IPv4 -ErrorAction SilentlyContinue
            }

            $gateway = Invoke-Command -ComputerName $machine -ScriptBlock {
                Get-NetRoute -InterfaceIndex $using:interfaceId -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' } |
                    Select-Object -ExpandProperty NextHop -First 1
            }

            $results.Add([PSCustomObject]@{
                MachineName  = $machine
                NIC_Name     = $adapterName
                InterfaceID  = $interfaceId
                IPAddress    = ($ipConfig.IPAddress    -join ", ")
                PrefixLength = ($ipConfig.PrefixLength -join ", ")
                Gateway      = $gateway
                DNSServers   = ($dnsServers.ServerAddresses -join ", ")
            })

            Write-Log "OK: $machine — $adapterName — $($ipConfig.IPAddress -join ', ')" "SUCCESS"
        }
    }
    catch {
        Write-Log "FAILED: $machine — $($_.Exception.Message)" "ERROR"
        $results.Add([PSCustomObject]@{
            MachineName  = $machine
            NIC_Name     = "ERROR"
            InterfaceID  = "N/A"
            IPAddress    = "N/A"
            PrefixLength = "N/A"
            Gateway      = "N/A"
            DNSServers   = "N/A"
        })
    }
}

Write-Progress -Activity "Collecting network configuration..." -Completed

$results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Log "Export completed — $($results.Count) adapter(s) — CSV: $OutputPath" "SUCCESS"
