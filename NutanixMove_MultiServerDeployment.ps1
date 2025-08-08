<#
.SYNOPSIS
    Deploys and executes a Nutanix VM preparation script on multiple remote servers.

.DESCRIPTION
    This script connects to a list of remote Windows servers using PowerShell remoting (WinRM), 
    copies a local preparation script (such as NutanixMove_VMPrep.ps1) to a specified location 
    on each server, and executes it remotely.

.PARAMETER Servers
    An array of server names (or IPs) to which the script will be deployed and executed.

.PARAMETER LocalScript
    The full path to the local PowerShell script to copy to each remote server.

.PARAMETER RemoteScript
    The path on the remote server where the script should be copied and executed.

.EXAMPLE
    .\Run-NutanixPrep.ps1 -Servers server01, server02 -LocalScript "C:\Scripts\NutanixMove_VMPrep.ps1" -RemoteScript "C:\Temp\NutanixMove_VMPrep.ps1"

.NOTES
    Author: Andy Kruesi
    Date:   2025-08-08
    Requires: PowerShell 5.1 or PowerShell 7+, WinRM enabled on target servers
#>

param (
    [Parameter(Mandatory = $true)]
    [string[]]$Servers,

    [Parameter(Mandatory = $true)]
    [string]$LocalScript,

    [Parameter(Mandatory = $true)]
    [string]$RemoteScript
)

foreach ($server in $Servers) {
    try {
        Write-Host "Copying script to $($server)..."
        $session = New-PSSession -ComputerName $server

        Copy-Item -Path $LocalScript -Destination $RemoteScript -ToSession $session -Force

        Write-Host "Executing script on $server..."
        Invoke-Command -Session $session -ScriptBlock {
            param ($scriptPath)
            & $scriptPath
        } -ArgumentList $RemoteScript

        Remove-PSSession $session
    }
    catch {
        Write-Warning "Failed on $($server): $_"
    }
}
