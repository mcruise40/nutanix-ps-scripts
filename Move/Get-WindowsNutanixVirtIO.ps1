# Define your server list
$servers = @(
    "Server01",
    "Server02",
    "Server03"
)

# Or read from a text file:
# $servers = Get-Content -Path "C:\servers.txt"

# Check each server
$results = foreach ($server in $servers) {
    Write-Host "Checking $server..." -ForegroundColor Cyan
    
    try {
        $software = Invoke-Command -ComputerName $server -ScriptBlock {
            Get-ItemProperty HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*,
                           HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\* -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Nutanix VirtIO*" } |
            Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
        } -ErrorAction Stop
        
        if ($software) {
            [PSCustomObject]@{
                ServerName     = $server
                Status         = "Installed"
                ProgramName    = $software.DisplayName
                Version        = $software.DisplayVersion
                InstallDate    = $software.InstallDate
            }
        } else {
            [PSCustomObject]@{
                ServerName     = $server
                Status         = "Not Found"
                ProgramName    = $null
                Version        = $null
                InstallDate    = $null
            }
        }
    }
    catch {
        [PSCustomObject]@{
            ServerName     = $server
            Status         = "Error: $($_.Exception.Message)"
            ProgramName    = $null
            Version        = $null
            InstallDate    = $null
        }
    }
}

# Display results
$results | Format-Table -AutoSize

# Export to CSV (optional)
$results | Export-Csv -Path "C:\NutanixVirtIO_Check.csv" -NoTypeInformation
