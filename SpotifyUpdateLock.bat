@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Spotify Update Lock

rem ============================================================
rem SpotifyUpdateLock.bat
rem Independent third-party utility for controlling the updater
rem of Spotify Desktop on Windows.
rem
rem PREPARE - Run before installing/launching the target build.
rem           Creates the updater lock and a temporary outbound
rem           firewall rule before Spotify can start.
rem
rem LOCK    - Run after installation. Confirms Spotify.exe,
rem           shows its version, reinforces the updater ACL, then
rem           removes the temporary firewall rule.
rem
rem STATUS  - Read-only diagnostics.
rem
rem UNLOCK  - Restores the ACL captured before PREPARE and removes
rem           only the firewall rule created by this utility.
rem ============================================================

rem --- Spotify target configuration ----------------------------------------
set "APP_DISPLAY_NAME=Spotify Desktop"
set "APP_PROCESS=Spotify.exe"
set "APP_EXE=%APPDATA%\Spotify\Spotify.exe"
set "UPDATE_DIR=%LOCALAPPDATA%\Spotify\Update"

rem --- Utility state --------------------------------------------------------
set "STATE_DIR=%LOCALAPPDATA%\SpotifyUpdateLock"
set "ACL_BACKUP=%STATE_DIR%\UpdateAcl.clixml"
set "CREATED_UPDATE_FLAG=%STATE_DIR%\CreatedUpdateDirectory.flag"
set "PREPARED_FLAG=%STATE_DIR%\Prepared.flag"
set "FW_RULE=SpotifyUpdateLock - Temporary Preinstall Block"
set "FW_GROUP=SpotifyUpdateLock"
set "MODE=%~1"

rem --- Elevate once ---------------------------------------------------------
fltmc >nul 2>&1
if "%errorlevel%"=="0" goto :ELEVATED

echo.
echo Administrative privileges are required.
echo Requesting elevation once...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "Start-Process -FilePath '%~f0' -ArgumentList '%MODE%' -Verb RunAs"
exit /b

:ELEVATED
if /I "%MODE%"=="PREPARE" goto :PREPARE
if /I "%MODE%"=="LOCK" goto :LOCK
if /I "%MODE%"=="STATUS" goto :STATUS
if /I "%MODE%"=="UNLOCK" goto :UNLOCK
if defined MODE (
    echo.
    echo Unknown command: %MODE%
    echo Usage: %~nx0 PREPARE ^| LOCK ^| STATUS ^| UNLOCK
    echo.
    pause
)

:MENU
set "MODE="
cls
echo ============================================================
echo                 Spotify Update Lock
echo ============================================================
echo.
echo  1. PREPARE  - before installing the target Spotify build
echo  2. LOCK     - after Spotify is installed
echo  3. STATUS   - diagnostics only
echo  4. UNLOCK   - restore original state
echo  5. Exit
echo.
choice /C 12345 /N /M "Choose [1-5]: "
if errorlevel 5 exit /b 0
if errorlevel 4 goto :UNLOCK
if errorlevel 3 goto :STATUS
if errorlevel 2 goto :LOCK
if errorlevel 1 goto :PREPARE

:PREPARE
cls
echo ============================================================
echo PREPARE - pre-install protection
echo ============================================================
echo.
echo Spotify update directory:
echo   %UPDATE_DIR%
echo.
echo Temporarily blocked executable:
echo   %APP_EXE%
echo.

if not exist "%STATE_DIR%" mkdir "%STATE_DIR%" >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Could not create state directory:
    echo         %STATE_DIR%
    goto :FAIL
)

if not exist "%UPDATE_DIR%" (
    mkdir "%UPDATE_DIR%" >nul 2>&1
    if errorlevel 1 (
        echo [ERROR] Could not create the update directory.
        goto :FAIL
    )
    >"%CREATED_UPDATE_FLAG%" echo Created by SpotifyUpdateLock
    echo [OK] Update directory created before Spotify installation.
) else (
    echo [OK] Update directory already exists.
)

if not exist "%ACL_BACKUP%" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "$ErrorActionPreference='Stop'; Get-Acl -LiteralPath $env:UPDATE_DIR | Export-Clixml -LiteralPath $env:ACL_BACKUP"
    if errorlevel 1 (
        echo [ERROR] Could not save the original ACL.
        goto :FAIL
    )
    echo [OK] Original ACL backed up.
) else (
    echo [OK] Existing ACL backup preserved.
)

call :APPLY_ACL
if errorlevel 1 goto :FAIL

call :ADD_FIREWALL
if errorlevel 1 goto :FAIL

>"%PREPARED_FLAG%" echo Prepared

echo.
echo ============================================================
echo PRE-INSTALL PROTECTION: ACTIVE
echo ============================================================
echo.
echo Install the desired Spotify Desktop build now.
echo If Spotify launches automatically, its standard executable path
echo is temporarily blocked from outbound network access.
echo.
echo Keep this window open.
echo After installation, return here and choose LOCK from the menu.
echo Do not use Spotify normally before LOCK finishes.
echo.
pause
goto :MENU

:LOCK
cls
echo ============================================================
echo LOCK - post-install verification
echo ============================================================
echo.

if not exist "%PREPARED_FLAG%" (
    echo [WARNING] PREPARE state was not found.
    echo The updater-directory lock will still be applied,
    echo but pre-install protection cannot be confirmed.
    echo.
)

taskkill /IM "%APP_PROCESS%" /F >nul 2>&1

if not exist "%UPDATE_DIR%" (
    mkdir "%UPDATE_DIR%" >nul 2>&1
    if errorlevel 1 (
        echo [ERROR] Could not create the update directory.
        goto :FAIL
    )
)

if not exist "%STATE_DIR%" mkdir "%STATE_DIR%" >nul 2>&1
if not exist "%ACL_BACKUP%" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "$ErrorActionPreference='Stop'; Get-Acl -LiteralPath $env:UPDATE_DIR | Export-Clixml -LiteralPath $env:ACL_BACKUP"
    if errorlevel 1 (
        echo [ERROR] Could not save the current ACL before locking.
        goto :FAIL
    )
    echo [OK] ACL backup created.
)

call :APPLY_ACL
if errorlevel 1 goto :FAIL

if exist "%APP_EXE%" (
    echo.
    echo [OK] Spotify executable found:
    echo      %APP_EXE%
    echo.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "$v=(Get-Item -LiteralPath $env:APP_EXE).VersionInfo; Write-Host ('Product version: ' + $v.ProductVersion); Write-Host ('File version:    ' + $v.FileVersion)"
) else (
    echo.
    echo [WARNING] Spotify.exe was not found at the expected path:
    echo           %APP_EXE%
    echo.
    echo The update directory remains locked and the temporary firewall
    echo rule will NOT be removed. Install Spotify Desktop and run LOCK again.
    echo.
    pause
    goto :MENU
)

call :REMOVE_FIREWALL
if errorlevel 1 (
    echo.
    echo [WARNING] Updater-directory ACL is active, but the temporary
    echo firewall rule could not be removed automatically.
    echo Run STATUS to inspect it.
    goto :FAIL
)

echo.
echo ============================================================
echo SPOTIFY UPDATER-DIRECTORY LOCK: ACTIVE
echo TEMPORARY FIREWALL BLOCK: REMOVED
echo ============================================================
echo.
echo Spotify may now be launched normally.
echo.
pause
goto :MENU

:STATUS
cls
echo ============================================================
echo STATUS - no changes will be made
echo ============================================================
echo.
echo Spotify executable:
if exist "%APP_EXE%" (
    echo   FOUND: %APP_EXE%
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "$v=(Get-Item -LiteralPath $env:APP_EXE).VersionInfo; Write-Host ('  Product version: ' + $v.ProductVersion); Write-Host ('  File version:    ' + $v.FileVersion)"
) else (
    echo   NOT FOUND at expected desktop path.
)

echo.
tasklist /FI "IMAGENAME eq %APP_PROCESS%" 2>nul | find /I "%APP_PROCESS%" >nul
if not errorlevel 1 (
    echo Spotify process: RUNNING
) else (
    echo Spotify process: NOT RUNNING
)

echo.
echo Update directory:
if exist "%UPDATE_DIR%" (
    echo   EXISTS: %UPDATE_DIR%
) else (
    echo   MISSING
)

echo.
echo Matching DENY ACL entries for the current user:
if exist "%UPDATE_DIR%" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
      "$me=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name; $r=(Get-Acl -LiteralPath $env:UPDATE_DIR).Access | Where-Object { $_.IdentityReference -eq $me -and $_.AccessControlType -eq 'Deny' }; if($r){$r | Format-Table IdentityReference,FileSystemRights,InheritanceFlags,AccessControlType -AutoSize}else{Write-Host '  NONE'}"
) else (
    echo   NONE - directory does not exist.
)

echo.
echo ACL backup:
if exist "%ACL_BACKUP%" (
    echo   PRESENT: %ACL_BACKUP%
) else (
    echo   NOT PRESENT
)

echo.
echo Temporary firewall rule:
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$r=Get-NetFirewallRule -DisplayName $env:FW_RULE -ErrorAction SilentlyContinue; if($r){$r | Select-Object DisplayName,Enabled,Direction,Action | Format-Table -AutoSize}else{Write-Host '  NOT PRESENT'}"

echo.
if exist "%PREPARED_FLAG%" (
    echo PREPARE state: RECORDED
) else (
    echo PREPARE state: NOT RECORDED
)

echo.
pause
goto :MENU

:UNLOCK
cls
echo ============================================================
echo UNLOCK - restore state
echo ============================================================
echo.

taskkill /IM "%APP_PROCESS%" /F >nul 2>&1

call :REMOVE_FIREWALL
if errorlevel 1 (
    echo [WARNING] Could not confirm removal of the firewall rule.
)

if exist "%ACL_BACKUP%" (
    if exist "%UPDATE_DIR%" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
          "$ErrorActionPreference='Stop'; $a=Import-Clixml -LiteralPath $env:ACL_BACKUP; Set-Acl -LiteralPath $env:UPDATE_DIR -AclObject $a"
        if errorlevel 1 (
            echo [ERROR] Could not restore the original update-directory ACL.
            echo State files were preserved for recovery.
            goto :FAIL
        )
        echo [OK] Original update-directory ACL restored.
    ) else (
        echo [INFO] Update directory no longer exists; ACL restore skipped.
    )
) else (
    echo [INFO] No ACL backup exists. No ACL was restored.
)

if exist "%CREATED_UPDATE_FLAG%" if exist "%UPDATE_DIR%" (
    rd "%UPDATE_DIR%" >nul 2>&1
    if exist "%UPDATE_DIR%" (
        echo [INFO] Update directory was created by this utility but is
        echo        not empty, so it was left in place.
    ) else (
        echo [OK] Empty update directory created by this utility removed.
    )
)

del /Q "%PREPARED_FLAG%" "%CREATED_UPDATE_FLAG%" "%ACL_BACKUP%" >nul 2>&1
rd "%STATE_DIR%" >nul 2>&1

echo.
echo ============================================================
echo UNLOCK COMPLETE
echo ============================================================
echo.
echo The SpotifyUpdateLock firewall rule was removed and the saved original
necho ACL was restored when available. No registry policy keys were touched.
echo.
pause
goto :MENU

:APPLY_ACL
echo.
echo Applying updater-directory ACL...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$p=$env:UPDATE_DIR;" ^
  "$id=[System.Security.Principal.WindowsIdentity]::GetCurrent().Name;" ^
  "$acl=Get-Acl -LiteralPath $p;" ^
  "$rights=[System.Security.AccessControl.FileSystemRights]::Write -bor [System.Security.AccessControl.FileSystemRights]::Delete -bor [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles;" ^
  "$inh=[System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit;" ^
  "$prop=[System.Security.AccessControl.PropagationFlags]::None;" ^
  "$deny=[System.Security.AccessControl.AccessControlType]::Deny;" ^
  "$existing=$acl.Access | Where-Object { $_.IdentityReference -eq $id -and $_.AccessControlType -eq 'Deny' -and ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Write) };" ^
  "if(-not $existing){$rule=New-Object System.Security.AccessControl.FileSystemAccessRule($id,$rights,$inh,$prop,$deny); $acl.AddAccessRule($rule) | Out-Null; Set-Acl -LiteralPath $p -AclObject $acl};" ^
  "$check=(Get-Acl -LiteralPath $p).Access | Where-Object { $_.IdentityReference -eq $id -and $_.AccessControlType -eq 'Deny' -and ($_.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::Write) }; if(-not $check){throw 'DENY ACE verification failed'}"
if errorlevel 1 (
    echo [ERROR] Failed to apply or verify the update-directory ACL.
    exit /b 1
)
echo [OK] Current user denied write/delete access to the update directory.
exit /b 0

:ADD_FIREWALL
echo.
echo Creating temporary outbound firewall block...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "Get-NetFirewallRule -DisplayName $env:FW_RULE -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue;" ^
  "New-NetFirewallRule -DisplayName $env:FW_RULE -Group $env:FW_GROUP -Direction Outbound -Program $env:APP_EXE -Action Block -Profile Any -Enabled True | Out-Null;" ^
  "if(-not (Get-NetFirewallRule -DisplayName $env:FW_RULE -ErrorAction SilentlyContinue)){throw 'Firewall rule verification failed'}"
if errorlevel 1 (
    echo [ERROR] Failed to create the temporary firewall rule.
    exit /b 1
)
echo [OK] Temporary firewall block active.
exit /b 0

:REMOVE_FIREWALL
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop'; $r=Get-NetFirewallRule -DisplayName $env:FW_RULE -ErrorAction SilentlyContinue; if($r){$r | Remove-NetFirewallRule -ErrorAction Stop}; if(Get-NetFirewallRule -DisplayName $env:FW_RULE -ErrorAction SilentlyContinue){throw 'Rule still present'}"
if errorlevel 1 exit /b 1
echo [OK] Temporary firewall rule absent.
exit /b 0

:FAIL
echo.
echo Operation did not complete successfully.
echo Use STATUS from the menu to inspect the current state.
echo.
pause
goto :MENU
