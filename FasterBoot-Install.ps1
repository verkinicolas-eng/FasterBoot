#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
  FasterBoot - Installation des 3 couches de nettoyage automatique
  Necessite les droits administrateur.

  Couche 1 : Shutdown - nettoyage a chaque extinction (GPO Shutdown Script)
  Couche 2 : Idle     - nettoyage apres 10 min d'inactivite
  Couche 3 : Startup  - surveillance du demarrage a chaque connexion
#>

$shutdownScript = Join-Path $PSScriptRoot 'FasterBoot-Shutdown.ps1'
$mainScript = Join-Path $PSScriptRoot 'FasterBoot.ps1'

if (-not (Test-Path $shutdownScript)) {
    Write-Host '  ERREUR: FasterBoot-Shutdown.ps1 introuvable.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '       FasterBoot - Installation des 3 couches' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host ''

# ================================================================
# COUCHE 1 : Shutdown (GPO Shutdown Script)
# ================================================================

Write-Host '  [1/3] Shutdown cleanup...' -ForegroundColor Yellow

$gpoDir = 'C:\Windows\System32\GroupPolicy\Machine\Scripts\Shutdown'
if (-not (Test-Path $gpoDir)) {
    New-Item -ItemType Directory -Path $gpoDir -Force | Out-Null
}
Copy-Item -Path $shutdownScript -Destination (Join-Path $gpoDir 'FasterBoot-Shutdown.ps1') -Force

$scriptsIni = Join-Path $gpoDir 'scripts.ini'
$iniContent = "[Shutdown]`r`n0CmdLine=FasterBoot-Shutdown.ps1`r`n0Parameters="
Set-Content -Path $scriptsIni -Value $iniContent -Encoding Unicode

# Registre GPO Scripts
$regBase = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Shutdown'
# Trouver le prochain index
$nextIdx = 0
if (Test-Path $regBase) {
    $existing = Get-ChildItem -Path $regBase -ErrorAction SilentlyContinue
    if ($existing) {
        # Verifier si FasterBoot est deja installe
        foreach ($item in $existing) {
            $children = Get-ChildItem -Path $item.PSPath -ErrorAction SilentlyContinue
            foreach ($child in $children) {
                $s = (Get-ItemProperty -Path $child.PSPath -Name 'Script' -ErrorAction SilentlyContinue).Script
                if ($s -like '*FasterBoot*') {
                    $nextIdx = [int]$item.PSChildName
                    break
                }
            }
        }
        if ($nextIdx -eq 0) {
            $nextIdx = ($existing | ForEach-Object { [int]$_.PSChildName } | Sort-Object -Descending | Select-Object -First 1) + 1
        }
    }
}

foreach ($base in @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Shutdown',
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Scripts\Shutdown'
)) {
    $idxPath = Join-Path $base $nextIdx
    $entryPath = Join-Path $idxPath '0'
    New-Item -Path $idxPath -Force | Out-Null
    New-ItemProperty -Path $idxPath -Name 'GPO-ID' -Value 'LocalGPO' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $idxPath -Name 'SOM-ID' -Value 'Local' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $idxPath -Name 'FileSysPath' -Value 'C:\Windows\System32\GroupPolicy\Machine\Scripts' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $idxPath -Name 'DisplayName' -Value 'Local Group Policy' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $idxPath -Name 'GPOName' -Value 'Local Group Policy' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $idxPath -Name 'PSScriptOrder' -Value 1 -PropertyType DWord -Force | Out-Null
    New-Item -Path $entryPath -Force | Out-Null
    New-ItemProperty -Path $entryPath -Name 'Script' -Value 'FasterBoot-Shutdown.ps1' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $entryPath -Name 'Parameters' -Value '' -PropertyType String -Force | Out-Null
    New-ItemProperty -Path $entryPath -Name 'IsPowershell' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -Path $entryPath -Name 'ExecTime' -Value 0 -PropertyType QWord -Force | Out-Null
}

gpupdate /force 2>&1 | Out-Null
Write-Host '  [OK] Nettoyage a chaque extinction installe (GPO Shutdown Script)' -ForegroundColor Green

# ================================================================
# COUCHE 2 : Idle (10 min inactivite)
# ================================================================

Write-Host '  [2/3] Idle cleanup...' -ForegroundColor Yellow

$idleAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $shutdownScript + '"')
$idleTrigger = New-ScheduledTaskTrigger -Daily -At '00:00'
$idleSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
$idleSettings.RunOnlyIfIdle = $true
$idleSettings.IdleSettings.IdleDuration = 'PT10M'
$idleSettings.IdleSettings.WaitTimeout = 'PT8H'
$idleSettings.IdleSettings.StopOnIdleEnd = $true
$idleSettings.IdleSettings.RestartOnIdle = $true

Register-ScheduledTask -TaskName 'FasterBoot_Idle' -Action $idleAction -Trigger $idleTrigger -Settings $idleSettings -Description 'FasterBoot - Nettoyage pendant inactivite (10 min). Se stoppe si le user revient.' -Force | Out-Null
Write-Host '  [OK] Nettoyage pendant inactivite installe (10 min)' -ForegroundColor Green

# ================================================================
# COUCHE 3 : Startup Guard (connexion)
# ================================================================

Write-Host '  [3/3] Startup guard...' -ForegroundColor Yellow

if (Test-Path $mainScript) {
    $monitorAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $mainScript + '" -Surveiller')
    # On lance -Surveiller qui cree sa propre tache. Ici on cree juste la tache monitor directement.
}

# Creer le script monitor inline
$monitorScriptPath = Join-Path $PSScriptRoot 'FasterBoot_Monitor.ps1'
$monitorContent = @'
$dataDir = Join-Path $PSScriptRoot 'FasterBoot_Data'
$historyFile = Join-Path $dataDir 'boot_history.csv'
$startupSnapshotFile = Join-Path $dataDir 'startup_snapshot.json'
$alertFile = Join-Path $dataDir 'alertes.txt'

if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

# Enregistrer le temps de boot
try {
    $event = Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
        Id = 100
    } -MaxEvents 1 -ErrorAction Stop

    $xml = [xml]$event.ToXml()
    $bootTime = $null; $mainPath = $null; $postBoot = $null

    foreach ($data in $xml.Event.EventData.Data) {
        switch ($data.Name) {
            'BootTime'         { $bootTime = [int64]$data.'#text' }
            'MainPathBootTime' { $mainPath = [int64]$data.'#text' }
            'BootPostBootTime' { $postBoot = [int64]$data.'#text' }
        }
    }

    if ($bootTime) {
        $bootSec = [math]::Round($bootTime / 1000, 1)
        $mainSec = if ($mainPath) { [math]::Round($mainPath / 1000, 1) } else { '' }
        $postSec = if ($postBoot) { [math]::Round($postBoot / 1000, 1) } else { '' }
        $score = if ($bootSec -le 15) { 'A+' }
                 elseif ($bootSec -le 25) { 'A' }
                 elseif ($bootSec -le 40) { 'B' }
                 elseif ($bootSec -le 60) { 'C' }
                 elseif ($bootSec -le 90) { 'D' }
                 else { 'F' }

        if (-not (Test-Path $historyFile)) {
            'Date,BootTimeSec,MainPathSec,PostBootSec,Score' | Out-File -FilePath $historyFile -Encoding UTF8
        }
        ((Get-Date).ToString('yyyy-MM-dd HH:mm') + ',' + $bootSec + ',' + $mainSec + ',' + $postSec + ',' + $score) |
            Out-File -FilePath $historyFile -Append -Encoding UTF8

        if ($bootSec -gt 90) {
            ((Get-Date).ToString() + ' | ALERTE: Boot lent (' + $bootSec + ' sec)') |
                Out-File -FilePath $alertFile -Append -Encoding UTF8
        }
    }
} catch {}

# Detecter les nouveaux programmes au demarrage
if (Test-Path $startupSnapshotFile) {
    $previous = Get-Content $startupSnapshotFile -Raw | ConvertFrom-Json
    $prevNames = @($previous.RegistryHKCU | ForEach-Object { $_.Name })

    $currentEntries = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
    if ($currentEntries) {
        $currentNames = @($currentEntries.PSObject.Properties |
            Where-Object { $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$' } |
            ForEach-Object { $_.Name })

        $newEntries = $currentNames | Where-Object { $_ -notin $prevNames }
        foreach ($new in $newEntries) {
            ((Get-Date).ToString() + ' | NOUVEAU AU DEMARRAGE: ' + $new) |
                Out-File -FilePath $alertFile -Append -Encoding UTF8
        }
    }
}

# Nettoyage temp
Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
'@

$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[System.IO.File]::WriteAllText($monitorScriptPath, $monitorContent, $utf8Bom)

$guardAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $monitorScriptPath + '"')
$guardTriggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$guardTriggerWeekly = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '08:00'
$guardSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

Register-ScheduledTask -TaskName 'FasterBoot_Monitor' -Action $guardAction -Trigger @($guardTriggerLogon, $guardTriggerWeekly) -Settings $guardSettings -Description 'FasterBoot - Surveillance du boot et detection de nouveaux programmes au demarrage' -Force | Out-Null
Write-Host '  [OK] Surveillance du demarrage installee (chaque connexion)' -ForegroundColor Green

# ================================================================
# RESUME
# ================================================================

Write-Host ''
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host '       Installation terminee - 3 couches actives' -ForegroundColor Green
Write-Host '  ============================================================' -ForegroundColor Green
Write-Host ''
Write-Host '  Couche 1 : Extinction  -> Nettoyage dans le processus d arret' -ForegroundColor White
Write-Host '  Couche 2 : Inactivite  -> Nettoyage apres 10 min sans activite' -ForegroundColor White
Write-Host '  Couche 3 : Connexion   -> Surveillance + enregistrement du boot' -ForegroundColor White
Write-Host ''
Write-Host '  Pour desinstaller : .\AnnulerOptimisations.ps1' -ForegroundColor Gray
Write-Host ''
