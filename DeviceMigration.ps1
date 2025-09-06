# Combined Domain Unjoin + AAD PPKG Apply (PS 5.1 safe) — RK project
# Run as SYSTEM from RMM.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ========= CONFIG (defaults; can be overridden by JSON file below) =========
$DomainUserDefault          = 'RECHTKORNFELD\administrator'
$DomainPasswordPlainDefault = 'T&5T=wRE'                 # rotate after!
$PpkgPathDefault            = 'C:\workspace\rk.ppkg'
$SuspendBitLockerDefault    = $true                      # suspend C: for 2 reboots
$ResetProxyToDirectDefault  = $true                      # child resets WinHTTP to DIRECT
$SetWinHttpProxyDefault     = ''                         # e.g. 'http=myproxy:8080;https=myproxy:8443' overrides reset
$VerifyWaitSecondsDefault   = 20
$VerifyRetriesDefault       = 30                         # ~10 minutes
# Optional JSON override file:
$ConfigJsonPath             = 'C:\workspace\aadjoin.params.json'
# JSON schema example:
# {
#   "DomainUser":"RECHTKORNFELD\\administrator",
#   "DomainPasswordPlain":"T&5T=wRE",
#   "PpkgPath":"C:\\workspace\\rk.ppkg",
#   "SuspendBitLocker": true,
#   "ResetProxyToDirect": true,
#   "SetWinHttpProxy": "",
#   "VerifyWaitSeconds": 20,
#   "VerifyRetries": 30
# }

# ========= paths & constants =========
$WorkspaceDir    = 'C:\workspace'
$LogsDir         = Join-Path $WorkspaceDir 'logs'
$ChildScriptPath = Join-Path $WorkspaceDir 'apply-ppkg-postreboot.ps1'
$TaskName        = 'ApplyPPKG_AADJoin_PostReboot'

# ========= ensure dirs =========
if (-not (Test-Path $WorkspaceDir)) { New-Item -ItemType Directory -Path $WorkspaceDir -Force | Out-Null }
if (-not (Test-Path $LogsDir))      { New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null }

# ========= load/merge config =========
$cfg = [ordered]@{
  DomainUser          = $DomainUserDefault
  DomainPasswordPlain = $DomainPasswordPlainDefault
  PpkgPath            = $PpkgPathDefault
  SuspendBitLocker    = $SuspendBitLockerDefault
  ResetProxyToDirect  = $ResetProxyToDirectDefault
  SetWinHttpProxy     = $SetWinHttpProxyDefault
  VerifyWaitSeconds   = $VerifyWaitSecondsDefault
  VerifyRetries       = $VerifyRetriesDefault
}

if (Test-Path $ConfigJsonPath) {
  try {
    $j = Get-Content $ConfigJsonPath -Raw | ConvertFrom-Json
    foreach ($k in $j.PSObject.Properties.Name) {
      if ($cfg.Contains($k) -and $null -ne $j.$k -and "$($j.$k)".Length -gt 0) {
        $cfg[$k] = $j.$k
      }
    }
  } catch { Write-Warning "Config JSON parse failed: $($_.Exception.Message). Using defaults." }
}

# ========= validate ppkg path =========
if (-not (Test-Path $cfg.PpkgPath)) { throw "PPKG not found at $($cfg.PpkgPath)" }
$ResolvedPpkg = (Resolve-Path $cfg.PpkgPath).Path

# ========= child script (runs at startup, as SYSTEM) =========
# single-quoted here-string → no premature interpolation
$Child = @'
param(
  [string]$PpkgPath,
  [string]$LogsDir,
  [int]$VerifyWaitSeconds = 20,
  [int]$VerifyRetries = 30,
  [switch]$ResetProxyToDirect,
  [string]$SetWinHttpProxy = '',
  [string]$TaskName = 'ApplyPPKG_AADJoin_PostReboot',
  [switch]$NoFinalReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

function Ensure-Dir($p){ if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null } }
function Log($m){
  $ts=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $line="[$ts] $m"
  Write-Host $line
  Add-Content -Path (Join-Path $LogsDir 'ppkg-apply.log') -Value $line
}
function Test-AADJoined { (dsregcmd /status) -match 'AzureAdJoined\s*:\s*YES' }

Ensure-Dir $LogsDir
"===== $(Get-Date) START ApplyPPKG =====" | Out-File -FilePath (Join-Path $LogsDir 'ppkg-apply.log') -Encoding UTF8 -Append

# WinHTTP proxy posture
try {
  if ($SetWinHttpProxy -and $SetWinHttpProxy.Trim().Length -gt 0) {
    Log "Setting WinHTTP proxy: $SetWinHttpProxy"
    cmd /c "netsh winhttp set proxy $SetWinHttpProxy" | Out-Null
  } elseif ($ResetProxyToDirect) {
    Log "Resetting WinHTTP proxy to DIRECT..."
    cmd /c 'netsh winhttp reset proxy' | Out-Null
  }
} catch { Log "WARN: winhttp proxy ops: $($_.Exception.Message)" }

# Time sync (non-blocking)
try { Log "Time sync..."; w32tm /resync /nowait | Out-Null } catch { Log "WARN: time sync: $($_.Exception.Message)" }

# Apply PPKG
Import-Module Provisioning -ErrorAction SilentlyContinue | Out-Null
try {
  Log "Applying provisioning package: $PpkgPath ..."
  Install-ProvisioningPackage -PackagePath $PpkgPath -ForceInstall -QuietInstall -LogsDirectoryPath $LogsDir | Out-Null
  Log "Install-ProvisioningPackage returned success."
} catch {
  Log "ERROR: Install-ProvisioningPackage threw: $($_.Exception.Message)"
  exit 2
}

# Poll for AzureAdJoined
$joined = $false
for ($i=1; $i -le $VerifyRetries; $i++) {
  if (Test-AADJoined) { $joined = $true; break }
  Log "AzureAdJoined not YES yet. Waiting ${VerifyWaitSeconds}s (try $i/$VerifyRetries)..."
  Start-Sleep -Seconds $VerifyWaitSeconds
}

if (-not $joined) {
  Log "FAIL: AzureAdJoined stayed NO after ~$([math]::Round(($VerifyRetries*$VerifyWaitSeconds)/60,2)) minutes."
  exit 3
}

Log "SUCCESS: AzureAdJoined = YES"

# Cleanup task
try { schtasks /Delete /TN "$TaskName" /F | Out-Null } catch { Log "WARN: Task cleanup issue: $($_.Exception.Message)" }

if (-not $NoFinalReboot) {
  Log "Rebooting to finalize..."
  shutdown.exe /r /t 5 /c "AAD Join complete via PPKG"
}
exit 0
'@

Set-Content -Path $ChildScriptPath -Value $Child -Encoding UTF8 -Force

# ========= register startup scheduled task (SYSTEM) =========
$argList = @(
  "-NoProfile",
  "-ExecutionPolicy Bypass",
  "-File `"$ChildScriptPath`"",
  "-PpkgPath `"$ResolvedPpkg`"",
  "-LogsDir `"$LogsDir`"",
  "-VerifyWaitSeconds $($cfg.VerifyWaitSeconds)",
  "-VerifyRetries $($cfg.VerifyRetries)",
  "-TaskName `"$TaskName`""
)
if ($cfg.ResetProxyToDirect -and -not ($cfg.SetWinHttpProxy -and $cfg.SetWinHttpProxy.Trim().Length -gt 0)) { $argList += "-ResetProxyToDirect" }
if ($cfg.SetWinHttpProxy -and $cfg.SetWinHttpProxy.Trim().Length -gt 0) { $argList += "-SetWinHttpProxy `"$($cfg.SetWinHttpProxy)`"" }

$Action    = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Argument ($argList -join ' ')
$Trigger   = New-ScheduledTaskTrigger -AtStartup
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest

try {
  if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
  }
} catch {}
Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Principal $Principal | Out-Null

# ========= BitLocker suspend (optional) =========
if ($cfg.SuspendBitLocker) {
  try {
    $blv = Get-BitLockerVolume -MountPoint 'C:' -ErrorAction SilentlyContinue
    if ($blv -and $blv.ProtectionStatus -eq 'On') {
      Write-Host "Suspending BitLocker for 2 reboots on C: ..."
      Suspend-BitLocker -MountPoint 'C:' -RebootCount 2 | Out-Null
    }
  } catch { Write-Warning "BitLocker suspend failed: $($_.Exception.Message)" }
}

# ========= unjoin (or if already workgroup, just reboot to trigger child) =========
$cs = $null; $isDomain = $true
try { $cs = Get-CimInstance Win32_ComputerSystem; $isDomain = [bool]$cs.PartOfDomain } catch { $isDomain = $true }
if ($isDomain) {
  if ($cs -and $cs.Domain) { Write-Host "[*] Machine is domain-joined to '$($cs.Domain)'. Unjoining..." } else { Write-Host "[*] Machine is domain-joined. Unjoining..." }
  $sec  = ConvertTo-SecureString $cfg.DomainPasswordPlain -AsPlainText -Force
  $cred = New-Object System.Management.Automation.PSCredential ($cfg.DomainUser, $sec)
  Remove-Computer -UnjoinDomainCredential $cred -Force -Verbose -Restart
} else {
  Write-Host "[*] Machine already in WORKGROUP. Rebooting to trigger startup task..."
  Restart-Computer -Force
}
