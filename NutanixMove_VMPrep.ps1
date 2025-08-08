
Set-ExecutionPolicy Bypass -Scope Process -Force
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
$scriptPath = (New-Object System.Net.WebClient).DownloadString('https://' + '10.40.205.250' + '/resources/uvm/win/esx_setup_uvm.ps1')
$retainIP = $true
$installNgt = $true
$installVirtio = $true
$setSanPolicy = $true
$uninstallVMwareTools = $true
$minPSVersion = '4.0.0'
$virtIOVersion = '1.2.3.9'

Invoke-Command -ScriptBlock ([scriptblock]::Create($scriptPath)) -ArgumentList '10.40.205.250',$retainIP,$setSanPolicy,$installNgt,$minPSVersion,$installVirtio,$uninstallVMwareTools,$virtIOVersion