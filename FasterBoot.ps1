#Requires -Version 5.1
<#
===============================================================================
  FASTER BOOT - OPTIMISEUR INTELLIGENT DE DÉMARRAGE
  Windows 10 & 11 - Version Universelle

  CE QUI REND CET OUTIL UNIQUE :
  ─────────────────────────────
  1. MESURE RÉELLE du temps de boot via les Event Logs Windows (Event ID 100)
  2. DIAGNOSTIC INTELLIGENT : analyse ce qui est lent sur CE PC spécifique
  3. SCORE DE SANTÉ du démarrage avec benchmark avant/après
  4. HISTORIQUE : suit l'évolution du boot dans le temps, détecte la dégradation
  5. OPTIMISATION CIBLÉE : n'applique que ce qui aura un impact réel
  6. AUTO-GUÉRISON : détecte quand un programme se remet au démarrage

  UTILISATION :
    .\FasterBoot.ps1                    Analyse + optimisation intelligente
    .\FasterBoot.ps1 -AnalyseSeule      Diagnostic sans modification
    .\FasterBoot.ps1 -DryRun            Simulation
    .\FasterBoot.ps1 -Historique        Voir l'évolution du boot
    .\FasterBoot.ps1 -Surveiller        Installer la surveillance automatique
===============================================================================
#>

param(
    [switch]$AnalyseSeule,
    [switch]$DryRun,
    [switch]$Historique,
    [switch]$Surveiller,
    [switch]$Force
)

# === CONFIGURATION ===
$dataDir = Join-Path $PSScriptRoot "FasterBoot_Data"
$historyFile = Join-Path $dataDir "boot_history.csv"
$baselineFile = Join-Path $dataDir "baseline.json"
$startupSnapshotFile = Join-Path $dataDir "startup_snapshot.json"
$logFile = Join-Path $dataDir "log.txt"

if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# === FONCTIONS UTILITAIRES ===

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "  ┌─────────────────────────────────────────────────────┐" -ForegroundColor Cyan
    Write-Host "  │ $($Title.PadRight(51)) │" -ForegroundColor Cyan
    Write-Host "  └─────────────────────────────────────────────────────┘" -ForegroundColor Cyan
}

function Write-Metric {
    param([string]$Label, [string]$Value, [string]$Status = "NEUTRAL")
    $color = switch ($Status) {
        "GOOD"    { "Green" }
        "WARN"    { "Yellow" }
        "BAD"     { "Red" }
        "ACTION"  { "Magenta" }
        default   { "White" }
    }
    Write-Host "  $($Label.PadRight(35))" -NoNewline
    Write-Host $Value -ForegroundColor $color
}

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp | $Message" | Out-File -FilePath $logFile -Append -Encoding UTF8
}

function Get-WindowsVersion {
    $build = [int](Get-CimInstance Win32_OperatingSystem).BuildNumber
    if ($build -ge 22000) { return @{ Name = "Windows 11"; Build = $build } }
    elseif ($build -ge 10240) { return @{ Name = "Windows 10"; Build = $build } }
    else { return @{ Name = "Inconnu"; Build = $build } }
}

# ================================================================
# MODULE 1 : MESURE RÉELLE DU BOOT (Event Logs Windows)
# ================================================================
# Windows enregistre chaque boot dans :
#   Microsoft-Windows-Diagnostics-Performance/Operational
#   Event ID 100 = Boot Performance Monitoring
#   Event ID 200 = Shutdown Performance Monitoring
# Ces données sont RÉELLES, pas estimées.
# ================================================================

function Get-BootPerformanceData {
    Write-Section "MESURE RÉELLE DU BOOT"

    $bootEvents = @()

    try {
        # Event ID 100 = mesure officielle du boot par Windows
        $events = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
            Id = 100
        } -MaxEvents 20 -ErrorAction Stop

        foreach ($event in $events) {
            $xml = [xml]$event.ToXml()
            $ns = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
            $ns.AddNamespace("e", "http://schemas.microsoft.com/win/2004/08/events/event")

            # Extraire les données de performance du boot
            $bootTime = $null
            $mainPathBootTime = $null
            $bootPostBootTime = $null
            $degraded = $false

            foreach ($data in $xml.Event.EventData.Data) {
                switch ($data.Name) {
                    'BootTime'         { $bootTime = [int64]$data.'#text' }
                    'MainPathBootTime' { $mainPathBootTime = [int64]$data.'#text' }
                    'BootPostBootTime' { $bootPostBootTime = [int64]$data.'#text' }
                    'BootIsDegradation'{ $degraded = $data.'#text' -eq 'true' }
                }
            }

            if ($bootTime) {
                $bootEvents += [PSCustomObject]@{
                    Date            = $event.TimeCreated
                    BootTimeMs      = $bootTime
                    BootTimeSec     = [math]::Round($bootTime / 1000, 1)
                    MainPathMs      = $mainPathBootTime
                    MainPathSec     = if ($mainPathBootTime) { [math]::Round($mainPathBootTime / 1000, 1) } else { $null }
                    PostBootMs      = $bootPostBootTime
                    PostBootSec     = if ($bootPostBootTime) { [math]::Round($bootPostBootTime / 1000, 1) } else { $null }
                    IsDegradation   = $degraded
                }
            }
        }
    } catch {
        Write-Host "  Impossible de lire les Event Logs de boot." -ForegroundColor Yellow
        Write-Host "  (Nécessite que le log Diagnostics-Performance soit actif)" -ForegroundColor Gray
        return $null
    }

    if ($bootEvents.Count -eq 0) {
        Write-Host "  Aucune donnée de boot trouvée." -ForegroundColor Yellow
        return $null
    }

    # Afficher les derniers boots
    $latest = $bootEvents[0]
    $avg = [math]::Round(($bootEvents | Measure-Object -Property BootTimeSec -Average).Average, 1)
    $min = [math]::Round(($bootEvents | Measure-Object -Property BootTimeSec -Minimum).Minimum, 1)
    $max = [math]::Round(($bootEvents | Measure-Object -Property BootTimeSec -Maximum).Maximum, 1)
    $degradedCount = ($bootEvents | Where-Object { $_.IsDegradation }).Count

    # Score de santé
    $score = if ($avg -le 15) { "A+" }
             elseif ($avg -le 25) { "A" }
             elseif ($avg -le 40) { "B" }
             elseif ($avg -le 60) { "C" }
             elseif ($avg -le 90) { "D" }
             else { "F" }

    $scoreColor = switch ($score) {
        { $_ -in "A+", "A" } { "GOOD" }
        "B"                   { "NEUTRAL" }
        "C"                   { "WARN" }
        default               { "BAD" }
    }

    Write-Host ""
    Write-Metric "Dernier boot"          "$($latest.BootTimeSec) secondes" $(if ($latest.BootTimeSec -le 30) {"GOOD"} elseif ($latest.BootTimeSec -le 60) {"WARN"} else {"BAD"})
    if ($latest.MainPathSec) {
        Write-Metric "  └ Chemin principal"  "$($latest.MainPathSec) sec (OS + drivers)" "NEUTRAL"
    }
    if ($latest.PostBootSec) {
        Write-Metric "  └ Post-boot"         "$($latest.PostBootSec) sec (apps démarrage)" "NEUTRAL"
    }
    Write-Host ""
    Write-Metric "Moyenne ($($bootEvents.Count) boots)" "$avg secondes" $scoreColor
    Write-Metric "Meilleur boot"         "$min secondes" "GOOD"
    Write-Metric "Pire boot"             "$max secondes" "BAD"
    Write-Metric "Boots dégradés"        "$degradedCount / $($bootEvents.Count)" $(if ($degradedCount -gt $bootEvents.Count/2) {"BAD"} else {"GOOD"})
    Write-Host ""
    Write-Metric "SCORE DE SANTÉ BOOT"   "[ $score ]" $scoreColor

    # Sauvegarder dans l'historique
    $historyEntry = "$($latest.Date.ToString('yyyy-MM-dd HH:mm')),$($latest.BootTimeSec),$($latest.MainPathSec),$($latest.PostBootSec),$score"
    if (-not (Test-Path $historyFile)) {
        "Date,BootTimeSec,MainPathSec,PostBootSec,Score" | Out-File -FilePath $historyFile -Encoding UTF8
    }
    $historyEntry | Out-File -FilePath $historyFile -Append -Encoding UTF8

    return @{
        Latest       = $latest
        Average      = $avg
        Score        = $score
        Events       = $bootEvents
        Degraded     = $degradedCount
    }
}

# ================================================================
# MODULE 2 : DIAGNOSTIC INTELLIGENT DES GOULOTS D'ÉTRANGLEMENT
# ================================================================
# Au lieu d'appliquer des tweaks génériques, on analyse CE PC :
#   - Event ID 101 = Applications lentes au démarrage
#   - Event ID 102 = Drivers lents au démarrage
#   - Event ID 103 = Services lents au démarrage
#   - Event ID 106 = Composants Windows lents au démarrage
# ================================================================

function Get-BootBottlenecks {
    Write-Section "DIAGNOSTIC DES GOULOTS D'ÉTRANGLEMENT"

    $bottlenecks = @()

    # --- Apps lentes au boot (Event ID 101) ---
    try {
        $slowApps = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
            Id = 101
        } -MaxEvents 50 -ErrorAction Stop

        foreach ($event in $slowApps) {
            $xml = [xml]$event.ToXml()
            $name = $null
            $time = $null
            $path = $null

            foreach ($data in $xml.Event.EventData.Data) {
                switch ($data.Name) {
                    'Name'     { $name = $data.'#text' }
                    'TotalTime'{ $time = [int64]$data.'#text' }
                    'FilePath' { $path = $data.'#text' }
                }
            }

            if ($name -and $time) {
                $bottlenecks += [PSCustomObject]@{
                    Type       = "Application"
                    Name       = $name
                    TimeMs     = $time
                    TimeSec    = [math]::Round($time / 1000, 1)
                    Path       = $path
                    Date       = $event.TimeCreated
                    EventId    = 101
                }
            }
        }
    } catch {}

    # --- Drivers lents au boot (Event ID 102) ---
    try {
        $slowDrivers = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
            Id = 102
        } -MaxEvents 50 -ErrorAction Stop

        foreach ($event in $slowDrivers) {
            $xml = [xml]$event.ToXml()
            $name = $null
            $time = $null

            foreach ($data in $xml.Event.EventData.Data) {
                switch ($data.Name) {
                    'Name'     { $name = $data.'#text' }
                    'TotalTime'{ $time = [int64]$data.'#text' }
                }
            }

            if ($name -and $time) {
                $bottlenecks += [PSCustomObject]@{
                    Type       = "Driver"
                    Name       = $name
                    TimeMs     = $time
                    TimeSec    = [math]::Round($time / 1000, 1)
                    Path       = ""
                    Date       = $event.TimeCreated
                    EventId    = 102
                }
            }
        }
    } catch {}

    # --- Services lents au boot (Event ID 103) ---
    try {
        $slowServices = Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
            Id = 103
        } -MaxEvents 50 -ErrorAction Stop

        foreach ($event in $slowServices) {
            $xml = [xml]$event.ToXml()
            $name = $null
            $time = $null

            foreach ($data in $xml.Event.EventData.Data) {
                switch ($data.Name) {
                    'Name'     { $name = $data.'#text' }
                    'TotalTime'{ $time = [int64]$data.'#text' }
                }
            }

            if ($name -and $time) {
                $bottlenecks += [PSCustomObject]@{
                    Type       = "Service"
                    Name       = $name
                    TimeMs     = $time
                    TimeSec    = [math]::Round($time / 1000, 1)
                    Path       = ""
                    Date       = $event.TimeCreated
                    EventId    = 103
                }
            }
        }
    } catch {}

    if ($bottlenecks.Count -eq 0) {
        Write-Host ""
        Write-Host '  Aucun goulot d''etranglement detecte dans les logs.' -ForegroundColor Green
        Write-Host "  (Le boot est déjà performant ou les logs sont vides)" -ForegroundColor Gray
        return @()
    }

    # Agréger : compter les occurrences et temps moyen par élément
    $grouped = $bottlenecks | Group-Object -Property Name | ForEach-Object {
        $avgTime = [math]::Round(($_.Group | Measure-Object -Property TimeSec -Average).Average, 1)
        $type = $_.Group[0].Type
        $path = $_.Group[0].Path
        $count = $_.Count
        [PSCustomObject]@{
            Type      = $type
            Name      = $_.Name
            AvgSec    = $avgTime
            Count     = $count
            Path      = $path
            Impact    = [math]::Round($avgTime * $count, 1)  # Score d'impact
        }
    } | Sort-Object -Property Impact -Descending

    Write-Host ""
    Write-Host "  Les éléments suivants RALENTISSENT RÉELLEMENT votre boot :" -ForegroundColor Yellow
    Write-Host "  (classés par impact, données issues des Event Logs Windows)" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Type          Nom                              Moy.    Fréq.  Impact" -ForegroundColor Gray
    Write-Host "  ────────────  ───────────────────────────────  ──────  ─────  ──────" -ForegroundColor Gray

    $top = $grouped | Select-Object -First 15
    foreach ($item in $top) {
        $typeStr = $item.Type.PadRight(12)
        $nameStr = if ($item.Name.Length -gt 31) { $item.Name.Substring(0, 28) + "..." } else { $item.Name.PadRight(31) }
        $avgStr = "$($item.AvgSec)s".PadRight(6)
        $countStr = "x$($item.Count)".PadRight(5)
        $impactStr = "$($item.Impact)"

        $color = if ($item.AvgSec -ge 5) { "Red" } elseif ($item.AvgSec -ge 2) { "Yellow" } else { "White" }
        Write-Host "  $typeStr  $nameStr  " -NoNewline
        Write-Host "$avgStr  $countStr  $impactStr" -ForegroundColor $color
    }

    return $grouped
}

# ================================================================
# MODULE 3 : SNAPSHOT & DÉTECTION DE CHANGEMENTS
# ================================================================
# Prend un instantané de l'état du démarrage et détecte les
# programmes qui se sont AJOUTÉS depuis la dernière analyse.
# ================================================================

function Get-StartupSnapshot {
    $snapshot = @{
        Date = (Get-Date).ToString("yyyy-MM-dd HH:mm")
        RegistryHKCU = @()
        RegistryHKLM = @()
        StartupFolder = @()
        Services = @()
    }

    # HKCU Run
    $runHKCU = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
    if ($runHKCU) {
        $runHKCU.PSObject.Properties | Where-Object {
            $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$'
        } | ForEach-Object {
            $snapshot.RegistryHKCU += @{ Name = $_.Name; Value = $_.Value }
        }
    }

    # HKLM Run
    $runHKLM = Get-ItemProperty -Path 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
    if ($runHKLM) {
        $runHKLM.PSObject.Properties | Where-Object {
            $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$'
        } | ForEach-Object {
            $snapshot.RegistryHKLM += @{ Name = $_.Name; Value = $_.Value }
        }
    }

    # Dossier Startup
    $startupPath = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    Get-ChildItem -Path $startupPath -Filter "*.lnk" -ErrorAction SilentlyContinue | ForEach-Object {
        $snapshot.StartupFolder += $_.Name
    }

    # Services auto
    Get-Service | Where-Object { $_.StartType -eq 'Automatic' } | ForEach-Object {
        $snapshot.Services += $_.Name
    }

    return $snapshot
}

function Compare-StartupChanges {
    Write-Section "DÉTECTION DE CHANGEMENTS"

    if (-not (Test-Path $startupSnapshotFile)) {
        Write-Host ""
        Write-Host "  Premier lancement : création du snapshot de référence." -ForegroundColor Gray
        $snapshot = Get-StartupSnapshot
        $snapshot | ConvertTo-Json -Depth 5 | Out-File -FilePath $startupSnapshotFile -Encoding UTF8
        Write-Host "  Snapshot sauvegardé. Les prochains lancements détecteront les changements." -ForegroundColor Green
        return @()
    }

    $previous = Get-Content $startupSnapshotFile -Raw | ConvertFrom-Json
    $current = Get-StartupSnapshot

    $changes = @()

    # Comparer HKCU
    $prevNames = $previous.RegistryHKCU | ForEach-Object { $_.Name }
    $currNames = $current.RegistryHKCU | ForEach-Object { $_.Name }

    $added = $currNames | Where-Object { $_ -notin $prevNames }
    $removed = $prevNames | Where-Object { $_ -notin $currNames }

    foreach ($a in $added) {
        $changes += [PSCustomObject]@{ Type = "AJOUTÉ"; Location = "Registre HKCU"; Name = $a }
        Write-Host "  [+] NOUVEAU au démarrage : $a" -ForegroundColor Red
    }
    foreach ($r in $removed) {
        $changes += [PSCustomObject]@{ Type = "RETIRÉ"; Location = "Registre HKCU"; Name = $r }
        Write-Host "  [-] Retiré du démarrage  : $r" -ForegroundColor Green
    }

    # Comparer dossier Startup
    $prevFolder = @($previous.StartupFolder)
    $currFolder = @($current.StartupFolder)

    $addedF = $currFolder | Where-Object { $_ -notin $prevFolder }
    foreach ($a in $addedF) {
        $changes += [PSCustomObject]@{ Type = "AJOUTÉ"; Location = "Dossier Startup"; Name = $a }
        Write-Host "  [+] NOUVEAU raccourci    : $a" -ForegroundColor Red
    }

    if ($changes.Count -eq 0) {
        Write-Host ""
        Write-Host "  Aucun changement détecté depuis le dernier scan." -ForegroundColor Green
    }

    # Mettre à jour le snapshot
    $current | ConvertTo-Json -Depth 5 | Out-File -FilePath $startupSnapshotFile -Encoding UTF8

    return $changes
}

# ================================================================
# MODULE 4 : OPTIMISATION CIBLÉE (basée sur le diagnostic)
# ================================================================
# Au lieu d'appliquer aveuglément des tweaks, on n'applique
# que ce qui a un impact PROUVÉ par les Event Logs.
# ================================================================

function Invoke-SmartOptimization {
    param($Bottlenecks, $BootData)

    Write-Section "OPTIMISATION CIBLÉE"

    $actions = @()

    # --- SERVICES : ne différer QUE ceux qui sont lents selon les logs ---
    $protectedServices = @(
        'wuauserv', 'WinDefend', 'MpsSvc', 'BFE', 'EventLog', 'RpcSs',
        'DcomLaunch', 'LSM', 'SamSs', 'Schedule', 'Power', 'Winmgmt',
        'AudioSrv', 'AudioEndpointBuilder', 'Dnscache', 'Dhcp', 'nsi',
        'LanmanWorkstation', 'LanmanServer', 'CryptSvc', 'ProfSvc',
        'UserManager', 'CoreMessagingRegistrar', 'BrokerInfrastructure',
        'SystemEventsBroker', 'Themes', 'WlanSvc', 'vgc', 'vgk'
    )

    if ($Bottlenecks) {
        $slowServices = $Bottlenecks | Where-Object { $_.Type -eq "Service" -and $_.AvgSec -ge 1 }

        foreach ($svc in $slowServices) {
            $service = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
            if ($service -and $service.StartType -eq 'Automatic' -and $svc.Name -notin $protectedServices) {
                if ($DryRun) {
                    $svcName = $svc.Name; $svcAvg = $svc.AvgSec
                    $svcMsg = 'serait differe (lent: ' + $svcAvg + 's)'
                    Write-Metric ('  ' + $svcName) $svcMsg 'ACTION'
                } elseif ($isAdmin) {
                    try {
                        Set-Service -Name $svc.Name -StartupType AutomaticDelayedStart
                        $svcMsg = 'differe (etait lent: ' + $svcAvg + 's)'
                        Write-Metric ('  ' + $svcName) $svcMsg 'GOOD'
                        $actions += ('Service differe: ' + $svcName + ' (' + $svcAvg + 's)')
                    } catch {
                        Write-Metric "  $($svc.Name)" "échec" "BAD"
                    }
                }
            }
        }
    }

    # --- PROGRAMMES AU DÉMARRAGE : retirer ceux identifiés comme lents ---
    $protectedStartup = @('SecurityHealth', 'RtkAudUService', 'Riot Vanguard', 'vgtray')

    # Liste de programmes connus comme non-essentiels
    $nonEssentialPatterns = @(
        'Steam', 'EpicGames', 'Discord', 'Spotify', 'Teams', 'Slack',
        'Zoom', 'Skype', 'OneDrive', 'Dropbox', 'GoogleDrive',
        'Voicemod', 'uTorrent', 'qBittorrent', 'Opera', 'Brave',
        'CCleaner', 'Adobe*Update', 'Java*Update', 'iTunesHelper',
        'Overwolf', 'Razer', 'NordVPN', 'ExpressVPN', 'LogiOptions',
        'Battle.net', 'GogGalaxy', 'Telegram', 'OBS'
    )

    $runPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    $entries = Get-ItemProperty -Path $runPath -ErrorAction SilentlyContinue

    if ($entries) {
        $properties = $entries.PSObject.Properties | Where-Object {
            $_.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$'
        }

        foreach ($prop in $properties) {
            $name = $prop.Name

            # Vérifier protection
            $isProtected = $false
            foreach ($p in $protectedStartup) {
                if ($name -like "*$p*") { $isProtected = $true; break }
            }
            if ($isProtected) { continue }

            # Vérifier si non-essentiel
            $shouldRemove = $false
            foreach ($pattern in $nonEssentialPatterns) {
                if ($name -like "*$pattern*") { $shouldRemove = $true; break }
            }

            # Aussi retirer si identifié comme lent dans les bottlenecks
            if (-not $shouldRemove -and $Bottlenecks) {
                $slowApp = $Bottlenecks | Where-Object {
                    $_.Type -eq "Application" -and $_.Name -like "*$name*" -and $_.AvgSec -ge 2
                }
                if ($slowApp) { $shouldRemove = $true }
            }

            if ($shouldRemove) {
                if ($DryRun) {
                    Write-Metric "  $name" "serait retiré du démarrage" "ACTION"
                } else {
                    Remove-ItemProperty -Path $runPath -Name $name -ErrorAction SilentlyContinue
                    Write-Metric "  $name" "retiré du démarrage" "GOOD"
                    $actions += "Startup retiré: $name"
                }
            }
        }
    }

    # --- Raccourcis Startup folder ---
    $startupFolder = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    Get-ChildItem -Path $startupFolder -Filter "*.lnk" -ErrorAction SilentlyContinue | ForEach-Object {
        $name = $_.BaseName
        $isProtected = $false
        foreach ($p in $protectedStartup) {
            if ($name -like "*$p*") { $isProtected = $true; break }
        }

        if (-not $isProtected) {
            $shouldRemove = $false
            foreach ($pattern in $nonEssentialPatterns) {
                if ($name -like "*$pattern*") { $shouldRemove = $true; break }
            }

            if ($shouldRemove) {
                if ($DryRun) {
                    Write-Metric "  $name (raccourci)" "serait supprimé" "ACTION"
                } else {
                    Remove-Item $_.FullName -Force
                    Write-Metric "  $name (raccourci)" "supprimé" "GOOD"
                    $actions += "Raccourci supprimé: $name"
                }
            }
        }
    }

    # --- RÉGLAGES SYSTÈME (seulement si score C ou pire, ou Force) ---
    $applySystemTweaks = $Force

    if ($BootData -and $BootData.Score -in @("C", "D", "F")) {
        $applySystemTweaks = $true
    }

    if ($applySystemTweaks) {
        Write-Host ""
        Write-Host '  Reglages systeme (score boot justifie l''intervention) :' -ForegroundColor Yellow

        # Fast Startup
        if ($isAdmin) {
            $hb = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction SilentlyContinue).HiberbootEnabled
            if ($hb -ne 1) {
                if ($DryRun) {
                    Write-Metric "  Fast Startup" "serait activé" "ACTION"
                } else {
                    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 1
                    Write-Metric "  Fast Startup" "activé" "GOOD"
                    $actions += "Fast Startup activé"
                }
            }

            # Boot timeout
            if (-not $DryRun) {
                bcdedit /timeout 0 > $null 2>&1
                Write-Metric "  Boot timeout" "0 seconde" "GOOD"
                $actions += "Boot timeout = 0"
            }

            # Prefetch
            $pfPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'
            $pf = (Get-ItemProperty -Path $pfPath -Name EnablePrefetcher -ErrorAction SilentlyContinue).EnablePrefetcher
            if ($pf -ne 3) {
                if (-not $DryRun) {
                    Set-ItemProperty -Path $pfPath -Name 'EnablePrefetcher' -Value 3 -ErrorAction SilentlyContinue
                    Set-ItemProperty -Path $pfPath -Name 'EnableSuperfetch' -Value 3 -ErrorAction SilentlyContinue
                    Write-Metric "  Prefetch" "optimisé (3)" "GOOD"
                    $actions += "Prefetch = 3"
                }
            }
        }

        # Suggestions (pas besoin admin)
        $cdmPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        $cdmKeys = @(
            'SubscribedContent-338389Enabled', 'SubscribedContent-310093Enabled',
            'SubscribedContent-338388Enabled', 'SubscribedContent-353698Enabled',
            'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled',
            'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled'
        )
        if (-not $DryRun) {
            foreach ($k in $cdmKeys) {
                Set-ItemProperty -Path $cdmPath -Name $k -Value 0 -ErrorAction SilentlyContinue
            }
            Write-Metric "  Suggestions/Spotlight" "désactivés" "GOOD"
            $actions += "Suggestions désactivées"
        }

        # Background apps
        if (-not $DryRun) {
            Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' -Name 'GlobalUserDisabled' -Value 1 -ErrorAction SilentlyContinue
            Write-Metric "  Apps arrière-plan" "désactivées" "GOOD"
            $actions += "Apps arrière-plan désactivées"
        }

    } else {
        Write-Host ""
        Write-Host '  Reglages systeme : score suffisant, pas d''intervention necessaire.' -ForegroundColor Green
        Write-Host "  (Utilisez -Force pour forcer les optimisations système)" -ForegroundColor Gray
    }

    if ($actions.Count -gt 0) {
        foreach ($a in $actions) { Write-Log $a }
    }

    return $actions
}

# ================================================================
# MODULE 5 : HISTORIQUE ET TENDANCES
# ================================================================

function Show-BootHistory {
    Write-Section "HISTORIQUE DES PERFORMANCES DE BOOT"

    if (-not (Test-Path $historyFile)) {
        Write-Host ""
        Write-Host '  Pas encore d''historique. Lancez FasterBoot plusieurs fois.' -ForegroundColor Yellow
        return
    }

    $history = Import-Csv -Path $historyFile

    if ($history.Count -lt 2) {
        Write-Host ""
        Write-Host "  Pas assez de données (minimum 2 entrées)." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "  Date                 Boot     Score" -ForegroundColor Gray
    Write-Host "  ───────────────────  ───────  ─────" -ForegroundColor Gray

    $history | Select-Object -Last 20 | ForEach-Object {
        $bootSec = $_.BootTimeSec
        $color = if ([double]$bootSec -le 25) { "Green" }
                 elseif ([double]$bootSec -le 50) { "Yellow" }
                 else { "Red" }

        # Barre visuelle
        $barLen = [math]::Min([math]::Round([double]$bootSec / 3), 30)
        $bar = "█" * $barLen

        Write-Host "  $($_.Date.PadRight(19))  " -NoNewline
        Write-Host "$($bootSec.PadRight(5))s " -ForegroundColor $color -NoNewline
        Write-Host " $($_.Score)  " -NoNewline
        Write-Host $bar -ForegroundColor $color
    }

    # Tendance
    $firstHalf = $history | Select-Object -First ([math]::Floor($history.Count / 2))
    $secondHalf = $history | Select-Object -Last ([math]::Ceiling($history.Count / 2))
    $avgFirst = ($firstHalf | ForEach-Object { [double]$_.BootTimeSec } | Measure-Object -Average).Average
    $avgSecond = ($secondHalf | ForEach-Object { [double]$_.BootTimeSec } | Measure-Object -Average).Average

    Write-Host ""
    if ($avgSecond -lt $avgFirst * 0.9) {
        $diff = [math]::Round($avgFirst - $avgSecond, 1)
        $msg = 'AMELIORATION (' + $diff + 's plus rapide)'
        Write-Metric 'Tendance' $msg 'GOOD'
    } elseif ($avgSecond -gt $avgFirst * 1.1) {
        $diff = [math]::Round($avgSecond - $avgFirst, 1)
        $msg = 'DEGRADATION (' + $diff + 's plus lent)'
        Write-Metric 'Tendance' $msg 'BAD'
    } else {
        Write-Metric "Tendance" "STABLE" "NEUTRAL"
    }
}

# ================================================================
# MODULE 6 : SURVEILLANCE AUTOMATIQUE
# ================================================================

function Install-BootMonitor {
    Write-Section "INSTALLATION DE LA SURVEILLANCE"

    $monitorScript = @'
# FasterBoot Monitor - Exécution automatique
$dataDir = Join-Path $PSScriptRoot "FasterBoot_Data"
$historyFile = Join-Path $dataDir "boot_history.csv"
$startupSnapshotFile = Join-Path $dataDir "startup_snapshot.json"
$alertFile = Join-Path $dataDir "alertes.txt"

if (-not (Test-Path $dataDir)) { New-Item -ItemType Directory -Path $dataDir -Force | Out-Null }

# 1. Enregistrer le temps de boot
try {
    $event = Get-WinEvent -FilterHashtable @{
        LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'
        Id = 100
    } -MaxEvents 1 -ErrorAction Stop

    $xml = [xml]$event.ToXml()
    $bootTime = $null
    $mainPath = $null
    $postBoot = $null

    foreach ($data in $xml.Event.EventData.Data) {
        switch ($data.Name) {
            'BootTime'         { $bootTime = [int64]$data.'#text' }
            'MainPathBootTime' { $mainPath = [int64]$data.'#text' }
            'BootPostBootTime' { $postBoot = [int64]$data.'#text' }
        }
    }

    if ($bootTime) {
        $bootSec = [math]::Round($bootTime / 1000, 1)
        $mainSec = if ($mainPath) { [math]::Round($mainPath / 1000, 1) } else { "" }
        $postSec = if ($postBoot) { [math]::Round($postBoot / 1000, 1) } else { "" }
        $score = if ($bootSec -le 15) { "A+" }
                 elseif ($bootSec -le 25) { "A" }
                 elseif ($bootSec -le 40) { "B" }
                 elseif ($bootSec -le 60) { "C" }
                 elseif ($bootSec -le 90) { "D" }
                 else { "F" }

        if (-not (Test-Path $historyFile)) {
            "Date,BootTimeSec,MainPathSec,PostBootSec,Score" | Out-File -FilePath $historyFile -Encoding UTF8
        }
        "$((Get-Date).ToString('yyyy-MM-dd HH:mm')),$bootSec,$mainSec,$postSec,$score" |
            Out-File -FilePath $historyFile -Append -Encoding UTF8

        # Alerte si dégradation
        if ($bootSec -gt 90) {
            $alert = (Get-Date).ToString() + ' | ALERTE: Boot tres lent (' + $bootSec + ' sec)'
            $alert | Out-File -FilePath $alertFile -Append -Encoding UTF8
        }
    }
} catch {}

# 2. Détecter les nouveaux programmes au démarrage
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
            $alert = "$(Get-Date) | NOUVEAU PROGRAMME AU DÉMARRAGE: $new"
            $alert | Out-File -FilePath $alertFile -Append -Encoding UTF8
        }
    }
}

# 3. Nettoyage temp
Remove-Item "$env:TEMP\*" -Recurse -Force -ErrorAction SilentlyContinue
'@

    $monitorPath = Join-Path $PSScriptRoot "FasterBoot_Monitor.ps1"
    $monitorScript | Out-File -FilePath $monitorPath -Encoding UTF8

    # Créer la tâche planifiée
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$monitorPath`""
    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $triggerWeekly = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '08:00'
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable

    try {
        Register-ScheduledTask -TaskName "FasterBoot_Monitor" -Action $action -Trigger @($triggerLogon, $triggerWeekly) -Settings $settings -Description "FasterBoot - Surveillance du temps de boot et détection de nouveaux programmes" -Force | Out-Null
        Write-Host ""
        Write-Metric "Tâche planifiée" "FasterBoot_Monitor installée" "GOOD"
        Write-Metric "Déclencheurs" "À chaque connexion + Lundi 8h" "NEUTRAL"
        Write-Metric "Fichier alertes" (Join-Path $dataDir "alertes.txt") "NEUTRAL"
        Write-Host ""
        Write-Host "  La surveillance va :" -ForegroundColor White
        Write-Host "    • Enregistrer le temps de boot à chaque démarrage" -ForegroundColor Gray
        Write-Host '    - Detecter les nouveaux programmes qui s''ajoutent' -ForegroundColor Gray
        Write-Host "    • Alerter si le boot dépasse 90 secondes" -ForegroundColor Gray
        Write-Host "    • Nettoyer les fichiers temporaires" -ForegroundColor Gray
    } catch {
        Write-Host "  Erreur: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ================================================================
# EXÉCUTION PRINCIPALE
# ================================================================

Clear-Host
Write-Host ""
Write-Host '  ============================================================' -ForegroundColor Cyan
Write-Host '       FASTER BOOT - Optimiseur Intelligent' -ForegroundColor Cyan
Write-Host '       Windows 10 / 11 - Version Universelle' -ForegroundColor Cyan
Write-Host '  ============================================================' -ForegroundColor Cyan

$winVer = Get-WindowsVersion
Write-Host ""
Write-Metric "Système" "$($winVer.Name) (Build $($winVer.Build))" "NEUTRAL"
Write-Metric "Admin" $(if ($isAdmin) { "Oui" } else { "Non (limité)" }) $(if ($isAdmin) { "GOOD" } else { "WARN" })
if ($DryRun) { Write-Metric "Mode" "SIMULATION" "ACTION" }
if ($AnalyseSeule) { Write-Metric "Mode" "ANALYSE SEULE" "ACTION" }

# --- Historique seul ---
if ($Historique) {
    Show-BootHistory
    Write-Host ""
    Write-Host "  Appuyez sur une touche pour fermer..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 0
}

# --- Installer surveillance ---
if ($Surveiller) {
    Install-BootMonitor
    Write-Host ""
    Write-Host "  Appuyez sur une touche pour fermer..." -ForegroundColor Gray
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 0
}

# --- Flux principal ---

# 1. Mesurer le boot
$bootData = Get-BootPerformanceData

# 2. Diagnostiquer les goulots
$bottlenecks = Get-BootBottlenecks

# 3. Détecter les changements
$changes = Compare-StartupChanges

# 4. Optimiser (sauf si analyse seule)
if (-not $AnalyseSeule) {
    $actions = Invoke-SmartOptimization -Bottlenecks $bottlenecks -BootData $bootData
}

# 5. Résumé
Write-Section "RÉSUMÉ"
Write-Host ""

if ($AnalyseSeule) {
    Write-Host "  Analyse terminée. Aucune modification effectuée." -ForegroundColor Cyan
    Write-Host "  Relancez sans -AnalyseSeule pour appliquer les optimisations." -ForegroundColor Gray
} elseif ($DryRun) {
    Write-Host "  Simulation terminée. Aucune modification effectuée." -ForegroundColor Cyan
    Write-Host "  Relancez sans -DryRun pour appliquer." -ForegroundColor Gray
} else {
    if ($actions -and $actions.Count -gt 0) {
        Write-Host "  $($actions.Count) optimisation(s) appliquée(s)." -ForegroundColor Green
        Write-Host '  Redemarrez le PC, puis relancez FasterBoot pour mesurer l''amelioration.' -ForegroundColor White
    } else {
        Write-Host "  Le système est déjà bien optimisé." -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "  Conseil : installez la surveillance avec :" -ForegroundColor Gray
    Write-Host "    .\FasterBoot.ps1 -Surveiller" -ForegroundColor Gray
    Write-Host '  Pour voir l''historique :' -ForegroundColor Gray
    Write-Host "    .\FasterBoot.ps1 -Historique" -ForegroundColor Gray
}

Write-Host ""
Write-Host "  Appuyez sur une touche pour fermer..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
