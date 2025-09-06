<# 
CSV-driven Pre-ACL for user profiles (Quest-style)

CSV headers:
  SourceObjectID,DestinationObjectID

SourceObjectID       = on-prem AD user objectGUID (e.g. 8c8a5d5c-....-....)
DestinationObjectID  = Entra ID (Azure AD) user ObjectId (GUID)

What it does (per row):
  1) Resolve SourceObjectID -> on-prem user SID via LDAP
  2) Find local profile in HKLM\...\ProfileList matching that SID
  3) Compute AzureAD local SID (S-1-12-1-*) from DestinationObjectID
  4) Create a new ProfileList entry for the AzureAD SID, copying values, fixing binary 'Sid'
  5) Take ownership (optional) and grant Full Control to the new SID on the profile folder (recursively)
  6) (Optional) remove the old SID ACE

Log: C:\workspace\reacl.log
#>

[CmdletBinding()]
param(
  [string]$CsvPath = 'C:\workspace\user_map.csv',
  [switch]$RemoveOldSidAces,    # remove old SID ACEs after granting new SID
  [switch]$SkipOwnerChange,     # don't change owner
  [switch]$DryRun               # no writes, log only
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Logging ----
$Workspace = 'C:\workspace'
$LogFile   = Join-Path $Workspace 'reacl.log'
if (-not (Test-Path $Workspace)) { New-Item -ItemType Directory -Path $Workspace -Force | Out-Null }
function Write-Log([string]$Message){
  $ts=(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
  $line="[$ts] $Message"
  Write-Host $line
  Add-Content -Path $LogFile -Value $line
}
"===== REACL START $(Get-Date) =====" | Out-File -FilePath $LogFile -Encoding UTF8

if (-not (Test-Path $CsvPath)) { throw "CSV not found at $CsvPath" }
$rows = Import-Csv -Path $CsvPath
if (-not $rows -or -not ($rows | Get-Member -Name SourceObjectID -MemberType NoteProperty) -or -not ($rows | Get-Member -Name DestinationObjectID -MemberType NoteProperty)) {
  throw "CSV must have headers: SourceObjectID,DestinationObjectID"
}

# ---- Helpers ----

# Convert Entra ObjectId (GUID) -> local AzureAD SID (S-1-12-1-<4x UInt32>)
function Convert-AadObjectIdToSid([Guid]$ObjectId) {
  $bytes = $ObjectId.ToByteArray()
  $u32 = New-Object 'System.UInt32[]' 4
  for ($i=0; $i -lt 4; $i++) { $u32[$i] = [BitConverter]::ToUInt32($bytes, $i*4) }
  "S-1-12-1-{0}-{1}-{2}-{3}" -f $u32[0],$u32[1],$u32[2],$u32[3]
}

# AD search: objectGUID -> objectSid (+ DN & sAM)
function Get-AdSidFromObjectGuid([Guid]$GuidValue) {
  $root = [ADSI]"LDAP://RootDSE"
  $base = "LDAP://{0}" -f $root.defaultNamingContext
  $entry = New-Object System.DirectoryServices.DirectoryEntry($base)
  $ds    = New-Object System.DirectoryServices.DirectorySearcher($entry)

  $bytes = $GuidValue.ToByteArray()
  $sb = New-Object System.Text.StringBuilder
  foreach ($b in $bytes) { [void]$sb.AppendFormat("\{0}", [System.String]::Format("{0:x2}", $b)) }
  $ds.Filter = "(&(objectClass=user)(objectGUID=$sb))"
  $ds.SearchScope = "Subtree"
  $ds.PropertiesToLoad.AddRange(@('objectSid','distinguishedName','sAMAccountName')) | Out-Null

  $res = $ds.FindOne()
  if (-not $res) { return $null }
  $sidBytes = $res.Properties['objectSid'][0]
  if (-not $sidBytes) { return $null }
  $sid = New-Object System.Security.Principal.SecurityIdentifier($sidBytes,0)
  [PSCustomObject]@{
    Sid = $sid.Value
    DN  = ($res.Properties['distinguishedName'] | Select-Object -First 1)
    sAM = ($res.Properties['sAMAccountName']    | Select-Object -First 1)
  }
}

function Get-ProfileListEntries {
  $base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
  if (-not (Test-Path $base)) { return @() }
  Get-ChildItem $base | ForEach-Object {
    $sid = Split-Path $_.Name -Leaf
    $pi  = Get-ItemProperty $_.PSPath
    [PSCustomObject]@{
      Sid = $sid
      ProfileImagePath = $pi.ProfileImagePath
      State     = $pi.State
      RefCount  = $pi.RefCount
      Flags     = $pi.Flags
      Guid      = $pi.Guid
      KeyPath   = $_.PSPath
    }
  }
}

function Copy-ProfileListEntry([string]$OldSid,[string]$NewSid) {
  if ($DryRun) { Write-Log "DRYRUN: Would clone ProfileList $OldSid -> $NewSid"; return }
  $base = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
  $oldKey = Join-Path $base $OldSid
  $newKey = Join-Path $base $NewSid
  if (-not (Test-Path $oldKey)) { throw "Source ProfileList key not found: $oldKey" }
  if (Test-Path $newKey)        { throw "ProfileList already contains $NewSid" }

  New-Item -Path $newKey -Force | Out-Null

  # copy known value names (skip 'Sid' for now)
  $props = Get-ItemProperty -Path $oldKey
  foreach ($name in @('ProfileImagePath','State','RefCount','Flags','Guid')) {
    if ($props.PSObject.Properties[$name]) {
      Set-ItemProperty -Path $newKey -Name $name -Value $props.$name
    }
  }

  # write binary Sid for new key
  $sidObj = New-Object System.Security.Principal.SecurityIdentifier($NewSid)
  $sidBytes = New-Object byte[] ($sidObj.BinaryLength)
  $sidObj.GetBinaryForm($sidBytes,0)
  Set-ItemProperty -Path $newKey -Name 'Sid' -Value $sidBytes
}

function Set-ProfileFolderAcl([string]$Path,[string]$OldSid,[string]$NewSid) {
  if (-not (Test-Path $Path)) { throw "Profile path not found: $Path" }
  Write-Log "ReACL: $Path  old=$OldSid  new=$NewSid"
  if ($DryRun) { Write-Log 'DRYRUN: Would take ownership and grant ACLs recursively.'; return }

  try {
    $ownerArg  = "*${NewSid}"
    $grantArg  = "*${NewSid}:(F)"
    $removeArg = "*${OldSid}"

    if (-not $SkipOwnerChange) {
      # take ownership recursively
      & icacls $Path /setowner $ownerArg /T /C | Out-Null
    }
    # grant FullControl to new SID recursively
    & icacls $Path /grant $grantArg /T /C | Out-Null

    if ($RemoveOldSidAces) {
      & icacls $Path /remove $removeArg /T /C | Out-Null
    }
  } catch {
    throw "icacls failed: $($_.Exception.Message)"
  }
}


# ---- Main ----

$profiles = Get-ProfileListEntries
if (-not $profiles) { throw 'No profiles found in ProfileList.' }

foreach ($row in $rows) {
  # Parse GUIDs
  try { $srcGuid = [guid]$row.SourceObjectID } catch { Write-Log "SKIP: bad SourceObjectID '$($row.SourceObjectID)'"; continue }
  try { $dstGuid = [guid]$row.DestinationObjectID } catch { Write-Log "SKIP: bad DestinationObjectID '$($row.DestinationObjectID)'"; continue }

  Write-Log "Map: SourceGUID=$srcGuid  ->  DestGUID=$dstGuid"

  # Resolve source SID from AD
  $srcInfo = $null
  try { $srcInfo = Get-AdSidFromObjectGuid -GuidValue $srcGuid } catch { Write-Log "ERROR: LDAP lookup failed: $($_.Exception.Message)"; continue }
  if (-not $srcInfo -or -not $srcInfo.Sid) { Write-Log "WARN: Could not resolve $srcGuid to a SID (no DC reachability?). Skipping."; continue }

  $sourceSid = $srcInfo.Sid
  Write-Log ("Resolved Source SID = {0}  (sAM={1})" -f $sourceSid,$srcInfo.sAM)

  # Find local profile for that SID
  $prof = $profiles | Where-Object { $_.Sid -eq $sourceSid } | Select-Object -First 1
  if (-not $prof) { Write-Log "WARN: No local profile for SID $sourceSid. Skipping."; continue }
  Write-Log "Local profile path: $($prof.ProfileImagePath)"

  # Compute AzureAD target SID
  $targetSid = Convert-AadObjectIdToSid -ObjectId $dstGuid
  Write-Log "Target AzureAD SID = $targetSid"

  # Clone ProfileList to new SID
  try {
    Copy-ProfileListEntry -OldSid $prof.Sid -NewSid $targetSid
    Write-Log "ProfileList cloned to $targetSid"
  } catch {
    Write-Log "ERROR: ProfileList clone failed: $($_.Exception.Message)"
    continue
  }

  # ReACL the profile folder
  try {
    Set-ProfileFolderAcl -Path $prof.ProfileImagePath -OldSid $prof.Sid -NewSid $targetSid
    Write-Log "ReACL complete for $($prof.ProfileImagePath)"
  } catch {
    Write-Log "ERROR: ReACL failed: $($_.Exception.Message)"
    # optional: Remove-Item "HKLM:\...\ProfileList\$targetSid"
    continue
  }

  Write-Log "SUCCESS: Pre-ACL done for Source=$($srcInfo.sAM) -> TargetSID=$targetSid"
}

Write-Log "===== REACL END $(Get-Date) ====="
Write-Host "Done. See $LogFile"
