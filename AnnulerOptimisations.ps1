#Requires -Version 5.1
<#
===============================================================================
  ANNULER LES OPTIMISATIONS - WINDOWS 10 & 11

  Ce script remet TOUT à l'état par défaut de Windows.
  Exécuter en tant qu'administrateur pour un rollback complet.
===============================================================================
#>

Write-Host ""
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host "  ANNULATION DES OPTIMISATIONS" -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Yellow
Write-Host ""

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# --- Fast Startup -> désactiver ---
if ($isAdmin) {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 -ErrorAction SilentlyContinue
    Write-Host "  [OK] Fast Startup désactivé (valeur par défaut)" -ForegroundColor Green
}

# --- Boot timeout -> 30 secondes ---
if ($isAdmin) {
    bcdedit /timeout 30 > $null 2>&1
    Write-Host "  [OK] Boot timeout remis à 30 secondes" -ForegroundColor Green
}

# --- Apps arrière-plan -> réactivées ---
Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications' -Name 'GlobalUserDisabled' -Value 0 -ErrorAction SilentlyContinue
Write-Host "  [OK] Apps en arrière-plan réactivées" -ForegroundColor Green

# --- Suggestions -> réactivées ---
$cdmPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
$keys = @(
    'SubscribedContent-338389Enabled', 'SubscribedContent-310093Enabled',
    'SubscribedContent-338388Enabled', 'SubscribedContent-353698Enabled',
    'SoftLandingEnabled', 'SystemPaneSuggestionsEnabled',
    'RotatingLockScreenEnabled', 'RotatingLockScreenOverlayEnabled'
)
foreach ($k in $keys) {
    Set-ItemProperty -Path $cdmPath -Name $k -Value 1 -ErrorAction SilentlyContinue
}
Write-Host "  [OK] Suggestions Windows et Spotlight réactivés" -ForegroundColor Green

# --- Services différés -> remis en Automatic ---
if ($isAdmin) {
    $logFile = Join-Path $PSScriptRoot "log_optimisation.txt"
    if (Test-Path $logFile) {
        $lines = Get-Content $logFile | Where-Object { $_ -match '^\[SERVICE\] Différé : .+\((.+)\)' }
        foreach ($line in $lines) {
            if ($line -match '\(([^)]+)\)$') {
                $svcName = $Matches[1]
                try {
                    Set-Service -Name $svcName -StartupType Automatic -ErrorAction Stop
                    Write-Host "  [OK] Service $svcName remis en Automatic" -ForegroundColor Green
                } catch {
                    Write-Host "  [SKIP] Service $svcName introuvable" -ForegroundColor Yellow
                }
            }
        }
    } else {
        Write-Host "  [INFO] Pas de log trouvé - services non restaurés automatiquement" -ForegroundColor Yellow
        Write-Host "         Ouvrez services.msc pour les remettre manuellement" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "  Redémarrez le PC pour appliquer." -ForegroundColor White
Write-Host ""
Write-Host "  Appuyez sur une touche pour fermer..." -ForegroundColor Gray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
