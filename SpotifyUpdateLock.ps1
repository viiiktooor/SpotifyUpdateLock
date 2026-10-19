<# Spotify Update Lock: PREPARE -> install -> LOCK. STATUS is read-only; UNLOCK reverts owned changes. #>
[CmdletBinding()]
param(
    [ValidateSet('PREPARE','LOCK','STATUS','UNLOCK')][string]$Mode,
    [switch]$Force,
    [ValidateSet('Add','Remove')][string]$FwAction, # internal elevated helper
    [string]$FwName,
    [string]$ExePath
)
$ErrorActionPreference='Stop'

# Configuration
$StateVer=3
$AppExe=Join-Path $env:APPDATA 'Spotify\Spotify.exe'
$LocalSpotify=Join-Path $env:LOCALAPPDATA 'Spotify'
$UpdateDir=Join-Path $LocalSpotify 'Update'
$Guard=Join-Path $UpdateDir '.SpotifyUpdateLock.guard'
$StateDir=Join-Path $env:LOCALAPPDATA 'SpotifyUpdateLock'
$StateFile=Join-Path $StateDir 'state.json'
$Sid=[Security.Principal.WindowsIdentity]::GetCurrent().User
$Rights=[Security.AccessControl.FileSystemRights]'Write, Delete, DeleteSubdirectoriesAndFiles'
$Inherit=[Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
$NoProp=[Security.AccessControl.PropagationFlags]::None
$Deny=[Security.AccessControl.AccessControlType]::Deny
$FwGroup='SpotifyUpdateLock'; $FwDisplay='SpotifyUpdateLock - Temporary Preinstall Block'
$FwPattern='^SpotifyUpdateLock-[0-9a-f]{32}$'
$script:S=$null; $script:SS='Missing'; $script:SV=0; $script:M=$null

function OK($x){Write-Host "[OK] $x" -ForegroundColor Green}; function INFO($x){Write-Host "[INFO] $x"}
function WARN($x){Write-Host "[WARN] $x" -ForegroundColor Yellow}; function ERR($x){Write-Host "[ERROR] $x" -ForegroundColor Red}
function HEAD($x){Write-Host "`n$('='*56)`n$x`n$('='*56)"}

# State. firewallRuleName being non-empty means that exact rule may exist.
function New-State { @{stateVersion=$StateVer;createdUpdateDir=$false;denyRuleAdded=$false;guardCreated=$false;firewallRuleName=''} }
function Read-State {
    if(!(Test-Path $StateFile)){return @{Status='Missing';Data=(New-State);Version=0}}
    try{
        $j=Get-Content $StateFile -Raw|ConvertFrom-Json; if(!$j){throw 'empty'}
        $v=0; if(-not [int]::TryParse([string]$j.stateVersion,[ref]$v)){throw 'version'}
        if($v -gt $StateVer){return @{Status='Unsupported';Data=(New-State);Version=$v}}
        if($v -ne $StateVer){throw 'old version'}
        foreach($k in 'createdUpdateDir','denyRuleAdded','guardCreated'){
            if(!($j.PSObject.Properties.Name -contains $k) -or !($j.$k -is [bool])){throw "field $k"}
        }
        if(!($j.PSObject.Properties.Name -contains 'firewallRuleName')){throw 'firewallRuleName'}
        $fw=[string]$j.firewallRuleName; if($fw -and $fw -notmatch $FwPattern){throw 'firewall name'}
        $d=New-State; foreach($k in 'createdUpdateDir','denyRuleAdded','guardCreated'){$d[$k]=$j.$k}; $d.firewallRuleName=$fw
        @{Status='Valid';Data=$d;Version=$v}
    }catch{@{Status='Corrupt';Data=(New-State);Version=0}}
}
function Save-State {
    New-Item -ItemType Directory -Path $StateDir -Force|Out-Null; $script:S.stateVersion=$StateVer
    $tmp="$StateFile.tmp.$PID"; $script:S|ConvertTo-Json|Set-Content $tmp -Encoding ASCII
    Move-Item $tmp $StateFile -Force; $script:SS='Valid'
}
function Clear-State {
    Remove-Item $StateFile -Force -ErrorAction SilentlyContinue
    Get-ChildItem $StateDir -Filter 'state.json.tmp.*' -ErrorAction SilentlyContinue|Remove-Item -Force -ErrorAction SilentlyContinue
    if((Test-Path $StateDir) -and !(Get-ChildItem $StateDir -Force)){Remove-Item $StateDir -Force -ErrorAction SilentlyContinue}
}

# Concurrency / path safety
function Enter-One {
    $script:M=[Threading.Mutex]::new($false,"Local\SpotifyUpdateLock-$($Sid.Value)")
    try{$ok=$script:M.WaitOne(0)}catch [Threading.AbandonedMutexException]{$ok=$true}
    if(!$ok){$script:M.Dispose();$script:M=$null}; $ok
}
function Exit-One {if($script:M){try{$script:M.ReleaseMutex()}catch{};$script:M.Dispose();$script:M=$null}}
function Assert-Dir($p){if(Test-Path $p){if((Get-Item $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw "$p is a junction/symlink; refusing to modify it."}}}
function Assert-Paths {Assert-Dir $LocalSpotify; Assert-Dir $UpdateDir}

# Process close: LOCK never releases the temporary firewall while target/unknown Spotify is still running.
function Stop-Spotify {
    $all=@(Get-Process Spotify -ErrorAction SilentlyContinue); if(!$all){return $true}
    $target=@();$unknown=0
    foreach($p in $all){try{$path=$p.Path}catch{$path=$null};if($path -and $path -ieq $AppExe){$target+=$p}elseif(!$path){$unknown++}}
    if($unknown){WARN "$unknown Spotify process(es) have unreadable paths."}
    foreach($p in $target){try{[void]$p.CloseMainWindow()}catch{}}
    $until=(Get-Date).AddSeconds(5); while((Get-Date) -lt $until -and @($target|?{!$_.HasExited})){Start-Sleep -Milliseconds 200}
    @($target|?{!$_.HasExited})|Stop-Process -Force -ErrorAction SilentlyContinue
    foreach($p in @(Get-Process Spotify -ErrorAction SilentlyContinue)){try{$path=$p.Path}catch{$path=$null};if(!$path -or $path -ieq $AppExe){return $false}}
    $true
}

# ACL: only an exact utility-shaped ACE is considered removable.
function Exact-Rules($acl){
    foreach($r in $acl.GetAccessRules($true,$false,[Security.Principal.SecurityIdentifier])){
        if(!$r.IsInherited -and $r.IdentityReference.Value -eq $Sid.Value -and $r.AccessControlType -eq $Deny -and
           $r.FileSystemRights -eq $Rights -and $r.InheritanceFlags -eq $Inherit -and $r.PropagationFlags -eq $NoProp){$r}
    }
}
function Lock-Rule {[Security.AccessControl.FileSystemAccessRule]::new($Sid,$Rights,$Inherit,$NoProp,$Deny)}
function Write-Blocked {
    $p=Join-Path $UpdateDir ('.probe_'+[guid]::NewGuid().ToString('N'))
    try{$f=[IO.File]::Create($p);$f.Dispose();Remove-Item $p -Force -ErrorAction SilentlyContinue;$false}catch [UnauthorizedAccessException]{$true}catch{$false}
}
function Enable-Lock {
    if($script:SS -eq 'Corrupt'){throw 'State file is corrupt. Use UNLOCK -Force for filesystem recovery.'}
    Assert-Dir $LocalSpotify
    if(!(Test-Path $UpdateDir)){New-Item -ItemType Directory $UpdateDir -Force|Out-Null;$script:S.createdUpdateDir=$true;Save-State}
    Assert-Paths; $acl=Get-Acl $UpdateDir; $exact=@(Exact-Rules $acl)
    if(!(Test-Path $Guard) -and !$exact){
        try{$f=[IO.File]::Open($Guard,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$f.Dispose();$script:S.guardCreated=$true;Save-State}catch [IO.IOException]{}
    }
    if(!$exact){$acl.AddAccessRule((Lock-Rule));Set-Acl -Path $UpdateDir -AclObject $acl;$script:S.denyRuleAdded=$true;Save-State}
    if(!@(Exact-Rules (Get-Acl $UpdateDir))){throw 'Exact deny ACE is missing.'}; if(!(Write-Blocked)){throw 'Write probe was not blocked.'}
    OK 'Update directory write lock verified.'
}
function Disable-Lock([bool]$force){
    if(!(Test-Path $UpdateDir)){if($script:SS -eq 'Valid'){$script:S.createdUpdateDir=$false;$script:S.denyRuleAdded=$false;$script:S.guardCreated=$false;Save-State};return $true}
    Assert-Paths; $valid=$script:SS -eq 'Valid'; $exact=@(Exact-Rules (Get-Acl $UpdateDir)); $own=$valid -and $script:S.denyRuleAdded
    if($exact -and ($own -or $force)){
        if($force -and !$own){WARN 'Force: removing one exact utility-shaped deny ACE.'}
        $acl=Get-Acl $UpdateDir;[void]$acl.RemoveAccessRuleSpecific($exact[0]);Set-Acl -Path $UpdateDir -AclObject $acl
        if(@(Exact-Rules (Get-Acl $UpdateDir)).Count -ge $exact.Count){throw 'Deny ACE removal failed.'}
    }elseif($exact){WARN 'Exact deny ACE ownership is unknown; use UNLOCK -Force.';return $false}
    if($valid -and $script:S.denyRuleAdded){$script:S.denyRuleAdded=$false;Save-State}

    if(Test-Path $Guard){$gown=$valid -and $script:S.guardCreated;if($gown -or $force){try{Remove-Item $Guard -Force}catch{WARN 'Guard removal failed.';return $false}}elseif(!$valid){WARN 'Guard ownership is unknown; use UNLOCK -Force.';return $false}}
    if($valid -and $script:S.guardCreated){$script:S.guardCreated=$false;Save-State}
    if($valid -and $script:S.createdUpdateDir){if(!(Get-ChildItem $UpdateDir -Force)){Remove-Item $UpdateDir -Force}else{INFO 'Update directory contains application data; leaving it.'};$script:S.createdUpdateDir=$false;Save-State}
    $true
}

# Firewall. Name is unique/owned; DisplayName is cosmetic.
function Get-FW($name){if(!$name){return $null};try{Get-NetFirewallRule -Name $name -ErrorAction Stop}catch{if($_.CategoryInfo.Category -eq 'ObjectNotFound' -or $_.FullyQualifiedErrorId -match 'NoMatching'){return $null};throw}}
function FW-ConfigOK($r,$exe){
    if(!$r){return $false};try{$a=Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $r -ErrorAction Stop}catch{return $false}
    ([string]$r.Enabled -eq 'True' -and [string]$r.Direction -eq 'Outbound' -and [string]$r.Action -eq 'Block' -and $r.Group -eq $FwGroup -and $a.Program -ieq $exe)
}
function Set-FW($action,$name,$exe){
    try{$r=Get-FW $name;if($action -eq 'Add'){if($r){return (FW-ConfigOK $r $exe)};New-NetFirewallRule -Name $name -DisplayName $FwDisplay -Group $FwGroup -Direction Outbound -Program $exe -Action Block -Profile Any -Enabled True|Out-Null;return (FW-ConfigOK (Get-FW $name) $exe)};if($r){$r|Remove-NetFirewallRule -ErrorAction Stop};!(Get-FW $name)}catch{$false}
}
if($FwAction){if(!$ExePath -or $FwName -notmatch $FwPattern){exit 2};if(Set-FW $FwAction $FwName $ExePath){exit 0}else{exit 1}}
function Is-Admin {$p=[Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent());$p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)}
function Invoke-FW($action,$name){
    if(Is-Admin){return (Set-FW $action $name $AppExe)}
    try{$a=@('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),'-FwAction',$action,'-FwName',$name,'-ExePath',('"{0}"' -f $AppExe));$p=Start-Process ((Get-Process -Id $PID).Path) -ArgumentList $a -Verb RunAs -Wait -PassThru -WindowStyle Hidden;return $p.ExitCode -eq 0}catch{WARN 'UAC cancelled or firewall operation failed.';$false}
}
function Add-FW {
    if(!$script:S.firewallRuleName){$script:S.firewallRuleName='SpotifyUpdateLock-'+[guid]::NewGuid().ToString('N');Save-State} # write-ahead
    $n=$script:S.firewallRuleName;if(Invoke-FW Add $n){OK 'Temporary firewall block active.';return $true}
    try{$exists=[bool](Get-FW $n)}catch{$exists=$true};if(!$exists){$script:S.firewallRuleName='';Save-State};$false
}
function Remove-FW {
    if($script:SS -ne 'Valid' -or !$script:S.firewallRuleName){return $true};$n=$script:S.firewallRuleName
    try{$exists=[bool](Get-FW $n)}catch{$exists=$true};if($exists -and !(Invoke-FW Remove $n)){WARN 'Temporary firewall rule could not be removed.';return $false}
    $script:S.firewallRuleName='';Save-State;OK 'Temporary firewall rule absent.';$true
}

# Operations
function Prepare {
    HEAD 'PREPARE';if(!(Stop-Spotify)){throw 'Spotify is already running or its path could not be confirmed. Close it manually and retry PREPARE.'};Enable-Lock;if(!(Add-FW)){throw 'Temporary network block failed. Do not install the old build yet.'}
    Write-Host 'Install the desired classic Spotify Desktop build, then choose LOCK.';$true
}
function Lock-Update {
    HEAD 'LOCK';if(!(Stop-Spotify)){throw 'Spotify may still be running. Close it manually and retry; firewall remains active.'}
    Enable-Lock;if(!(Test-Path $AppExe)){WARN 'Classic Spotify executable not found; firewall remains active.';return $false}
    $v=(Get-Item $AppExe).VersionInfo.ProductVersion;OK "Spotify $v found.";if(!(Remove-FW)){return $false};HEAD 'UPDATE LOCK ACTIVE';$true
}
function Status {
    HEAD 'STATUS';if(Test-Path $AppExe){Write-Host "Spotify: $((Get-Item $AppExe).VersionInfo.ProductVersion)"}else{Write-Host 'Spotify: classic executable not found'}
    Write-Host "State: $($script:SS)";if($script:SS -eq 'Unsupported'){Write-Host "State version $($script:SV) > supported $StateVer"}
    if(Test-Path $UpdateDir){$rp=((Get-Item $UpdateDir -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0;Write-Host "Update dir reparse: $rp";if(!$rp){Write-Host "Exact deny ACEs: $(@(Exact-Rules (Get-Acl $UpdateDir)).Count)"};Write-Host "Guard: $(Test-Path $Guard)"}
    if($script:SS -eq 'Valid'){Write-Host "Own ACE: $($script:S.denyRuleAdded) | Own guard: $($script:S.guardCreated) | Firewall: $($script:S.firewallRuleName)"}
    try{$g=@(Get-NetFirewallRule -Group $FwGroup -ErrorAction Stop);if($g){$g|Format-Table Name,Enabled,Direction,Action -AutoSize|Out-Host}}catch{};$true
}
function Unlock {
    HEAD 'UNLOCK';$force=[bool]$Force
    if($script:SS -ne 'Valid' -and !$force -and $script:Interactive){$force=(Read-Host 'Ownership unavailable. Use Force cleanup for exact ACE/guard? [y/N]')-match'^(y|yes)$'}
    if($script:SS -eq 'Corrupt' -and !$force){WARN 'Corrupt state: filesystem ownership unknown. Use UNLOCK -Force.';return $false}
    if($script:SS -eq 'Valid' -and $script:S.firewallRuleName){try{$fwThere=[bool](Get-FW $script:S.firewallRuleName)}catch{$fwThere=$true};if($fwThere){[void](Stop-Spotify)}}
    $a=Disable-Lock $force;$f=Remove-FW
    if($script:SS -eq 'Corrupt'){WARN 'Corrupt state kept; inspect firewall group in STATUS before deleting it manually.';return $false}
    if($a -and $f){Clear-State;HEAD 'UNLOCK COMPLETE';return $true};WARN 'UNLOCK incomplete; state kept for retry.';$false
}
function Act($name){
    if(!(Enter-One)){ERR 'Another action is already running.';return $false}
    try{$r=Read-State;$script:S=$r.Data;$script:SS=$r.Status;$script:SV=$r.Version;if($script:SS -eq 'Unsupported' -and $name -ne 'STATUS'){throw 'State was written by a newer version; nothing changed.'};switch($name){PREPARE{return Prepare};LOCK{return Lock-Update};STATUS{return Status};UNLOCK{return Unlock}}}catch{ERR $_.Exception.Message;INFO 'Run STATUS for diagnostics.';$false}finally{Exit-One}
}
function Menu-Option($key,$name,$line1,$line2){
    Write-Host "  ${key}. " -NoNewline -ForegroundColor Cyan; Write-Host $name -NoNewline -ForegroundColor Yellow; Write-Host "  $line1"
    if($line2){Write-Host "               $line2" -ForegroundColor DarkGray}
    Write-Host ''
}
function Menu {
    while($true){
        Clear-Host
        Write-Host ('='*64) -ForegroundColor Cyan
        Write-Host '  Spotify Update Lock' -ForegroundColor White
        Write-Host ('='*64) -ForegroundColor Cyan
        Write-Host ''
        Menu-Option 1 'PREPARE' 'Use BEFORE installing the Spotify version you want.' 'Locks the updater and blocks Spotify from the network.'
        Menu-Option 2 'LOCK   ' 'Use AFTER the installation has finished.' 'Confirms the lock and restores normal network access.'
        Menu-Option 3 'STATUS ' 'Show the current state. Changes nothing.' ''
        Menu-Option 4 'UNLOCK ' 'Undo everything this tool changed (updates work again).' ''
        Menu-Option 5 'EXIT   ' 'Close this window.' ''
        switch(Read-Host 'Choose an option [1-5]'){
            '1'{[void](Act PREPARE)}
            '2'{[void](Act LOCK)}
            '3'{[void](Act STATUS)}
            '4'{[void](Act UNLOCK)}
            '5'{return}
            default{Write-Host 'Invalid option. Type a number from 1 to 5.' -ForegroundColor Yellow}
        }
        Write-Host ''
        [void](Read-Host 'Press Enter to return to the menu')
    }
}

$script:Interactive = -not [bool]$Mode
if($Mode){exit([int](-not(Act $Mode)))};Menu;exit 0
