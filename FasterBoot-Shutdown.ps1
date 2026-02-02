#Requires -Version 5.1
<#
  FasterBoot - Nettoyage pre-arret
  Se lance automatiquement avant chaque arret/redemarrage du PC.
  Nettoie tout ce qui ralentirait le prochain boot.
#>

$logDir = Join-Path $PSScriptRoot 'FasterBoot_Data'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$logFile = Join-Path $logDir 'shutdown_log.txt'

function Log {
    param([string]$Msg)
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    ($ts + ' | ' + $Msg) | Out-File -FilePath $logFile -Append -Encoding UTF8
}

Log '=== Nettoyage pre-arret ==='

# 1. Fichiers temporaires utilisateur
$tempPaths = @(
    $env:TEMP,
    (Join-Path $env:LOCALAPPDATA 'Temp')
)
$freedTotal = 0
foreach ($p in $tempPaths) {
    if (Test-Path $p) {
        $before = (Get-ChildItem -Path $p -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        Remove-Item (Join-Path $p '*') -Recurse -Force -ErrorAction SilentlyContinue
        $after = (Get-ChildItem -Path $p -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        $freedTotal += ($before - $after)
    }
}

# 2. Fichiers temporaires systeme (si admin)
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($isAdmin) {
    $sysTemp = Join-Path $env:WINDIR 'Temp'
    if (Test-Path $sysTemp) {
        $before = (Get-ChildItem -Path $sysTemp -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        Remove-Item (Join-Path $sysTemp '*') -Recurse -Force -ErrorAction SilentlyContinue
        $after = (Get-ChildItem -Path $sysTemp -Recurse -Force -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum
        $freedTotal += ($before - $after)
    }
}

$freedMB = [math]::Round($freedTotal / 1MB, 1)
Log ('Temp nettoye : ' + $freedMB + ' Mo liberes')

# 3. Cache DNS (le prochain boot reconstruira un cache propre)
ipconfig /flushdns 2>&1 | Out-Null
Log 'Cache DNS vide'

# 4. Caches navigateurs (uniquement le cache HTTP, pas les cookies/sessions)
$browserCaches = @(
    @{ Name = 'Chrome';  Path = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Cache\Cache_Data' },
    @{ Name = 'Chrome';  Path = Join-Path $env:LOCALAPPDATA 'Google\Chrome\User Data\Default\Code Cache' },
    @{ Name = 'Edge';    Path = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Cache\Cache_Data' },
    @{ Name = 'Edge';    Path = Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data\Default\Code Cache' },
    @{ Name = 'Brave';   Path = Join-Path $env:LOCALAPPDATA 'BraveSoftware\Brave-Browser\User Data\Default\Cache\Cache_Data' },
    @{ Name = 'Firefox'; Path = '' }
)

foreach ($b in $browserCaches) {
    if ($b.Name -eq 'Firefox') {
        $ffProfiles = Join-Path $env:APPDATA 'Mozilla\Firefox\Profiles'
        if (Test-Path $ffProfiles) {
            Get-ChildItem -Path $ffProfiles -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                $ffCache = Join-Path $_.FullName 'cache2\entries'
                if (Test-Path $ffCache) {
                    Remove-Item (Join-Path $ffCache '*') -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            Log 'Cache Firefox nettoye'
        }
    } else {
        if (Test-Path $b.Path) {
            Remove-Item (Join-Path $b.Path '*') -Recurse -Force -ErrorAction SilentlyContinue
            Log ('Cache ' + $b.Name + ' nettoye')
        }
    }
}

# 5. Thumbnails Windows (se regenerent automatiquement au besoin)
$thumbPath = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows\Explorer'
if (Test-Path $thumbPath) {
    Get-ChildItem -Path $thumbPath -Filter 'thumbcache_*.db' -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    Log 'Thumbnail cache nettoye'
}

# 6. Fichiers de crash dumps (inutiles sauf debug)
$dumpPaths = @(
    (Join-Path $env:LOCALAPPDATA 'CrashDumps'),
    (Join-Path $env:WINDIR 'Minidump')
)
foreach ($dp in $dumpPaths) {
    if (Test-Path $dp) {
        Remove-Item (Join-Path $dp '*') -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Log 'Crash dumps nettoyes'

# 7. Recent files list (accelere le chargement de l'explorateur)
$recentPath = Join-Path $env:APPDATA 'Microsoft\Windows\Recent\AutomaticDestinations'
if (Test-Path $recentPath) {
    Get-ChildItem -Path $recentPath -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-7) } |
        ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
    Log 'Vieux fichiers recents nettoyes (> 7 jours)'
}

# 8. Prefetch cleanup des anciennes entrees (> 30 jours, si admin)
if ($isAdmin) {
    $prefetchPath = Join-Path $env:WINDIR 'Prefetch'
    if (Test-Path $prefetchPath) {
        $oldPf = Get-ChildItem -Path $prefetchPath -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-30) }
        $oldCount = ($oldPf | Measure-Object).Count
        $oldPf | ForEach-Object { Remove-Item $_.FullName -Force -ErrorAction SilentlyContinue }
        if ($oldCount -gt 0) {
            Log ('Prefetch : ' + $oldCount + ' anciennes entrees supprimees (> 30 jours)')
        }
    }

    # 9. Delivery Optimization cache
    try {
        Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue
        Log 'Cache Delivery Optimization nettoye'
    } catch {}

    # 10. Windows Update download cache (anciennes mises a jour)
    $wuPath = Join-Path $env:WINDIR 'SoftwareDistribution\Download'
    if (Test-Path $wuPath) {
        Get-ChildItem -Path $wuPath -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) } |
            ForEach-Object { Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue }
        Log 'Vieux fichiers Windows Update nettoyes (> 14 jours)'
    }
}

# 11. Vider la corbeille (fichiers > 3 jours dans la corbeille)
if ($isAdmin) {
    try {
        Clear-RecycleBin -Force -ErrorAction SilentlyContinue
        Log 'Corbeille videe'
    } catch {}
}

# 12. Forcer un flush memoire pour que le prochain Superfetch demarre propre
[System.GC]::Collect()
Log 'GC force'

Log '=== Nettoyage termine ==='
