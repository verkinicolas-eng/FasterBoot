<p align="center">
  <img src="docs/assets/banner.png" alt="FasterBoot Banner" width="700"/>
</p>

<h1 align="center">FasterBoot</h1>

<p align="center">
  <strong>The first Windows boot optimizer that measures before it optimizes.</strong>
  <br/>
  <em>By NVK Labs</em>
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-Apache%202.0-blue.svg" alt="License"/></a>
  <img src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6?logo=windows" alt="Windows 10 | 11"/>
  <img src="https://img.shields.io/badge/PowerShell-5.1+-5391FE?logo=powershell&logoColor=white" alt="PowerShell 5.1+"/>
  <img src="https://img.shields.io/badge/Dependencies-None-green" alt="No dependencies"/>
</p>

---

## The Problem

Every Windows optimizer out there does the same thing: blindly disable 50 services, delete startup programs, and hope it gets faster. They have no idea what is **actually slow** on **your** specific machine.

**FasterBoot takes a different approach: measure first, optimize second.**

## How It Works

Windows already knows exactly what slows down your boot. It records every single boot in the Event Logs with millisecond precision:

| Event ID | What Windows Records |
|----------|---------------------|
| **100** | Total boot time (MainPath + PostBoot breakdown) |
| **101** | Slow applications at startup (name + exact duration) |
| **102** | Slow drivers at startup (name + exact duration) |
| **103** | Slow services at startup (name + exact duration) |

FasterBoot reads this data and builds a **precise diagnostic** of what is slow on **your PC**, then applies **targeted fixes** only where they will have a real impact.

## What Makes FasterBoot Different

| Feature | Traditional Optimizers | FasterBoot |
|---------|----------------------|------------|
| **Diagnosis** | None — applies generic tweaks | Reads Windows Event Logs for real boot metrics |
| **Targeting** | Same 50 tweaks on every PC | Only fixes what is **proven slow** on this PC |
| **Measurement** | No before/after | Boot time measured in ms, scored A+ to F |
| **Tracking** | One-shot, fire and forget | Historical CSV with trend detection |
| **Monitoring** | None | Scheduled task detects regressions & new startup intrusions |
| **System tweaks** | Always applied | Only applied if boot score is C or worse |
| **Safety** | Hope for the best | Protected whitelist, snapshot diff, full rollback script |

## Quick Start

### 1. Download

```powershell
git clone https://github.com/verkinicolas-eng/FasterBoot.git
cd FasterBoot
```

Or [download the ZIP](https://github.com/verkinicolas-eng/FasterBoot/archive/refs/heads/main.zip) and extract it.

### 2. Diagnose (no changes made)

Open **PowerShell as Administrator**, then:

```powershell
.\FasterBoot.ps1 -AnalyseSeule
```

This will show:
- Your **real boot time** as measured by Windows
- A **health score** from A+ to F
- The **exact bottlenecks** (which services, apps, drivers are slow and by how much)
- Any **new programs** that added themselves to startup since last scan

### 3. Simulate (optional)

```powershell
.\FasterBoot.ps1 -DryRun
```

Shows what **would** be changed, without touching anything.

### 4. Optimize

```powershell
.\FasterBoot.ps1
```

Applies targeted optimizations based on the diagnostic. Reboot, then run `-AnalyseSeule` again to measure the improvement.

### 5. Monitor (recommended)

```powershell
.\FasterBoot.ps1 -Surveiller
```

Installs a scheduled task that:
- Records boot time at every startup
- Detects new programs sneaking into startup
- Alerts if boot time exceeds 90 seconds
- Cleans temp files

### 6. Track over time

```powershell
.\FasterBoot.ps1 -Historique
```

Shows an ASCII bar chart of boot time history with trend detection (improving / degrading / stable).

## Example Output

```
  ┌─────────────────────────────────────────────────────┐
  │ MESURE RÉELLE DU BOOT                               │
  └─────────────────────────────────────────────────────┘

  Dernier boot                       23.4 secondes
    └ Chemin principal               14.1 sec (OS + drivers)
    └ Post-boot                      9.3 sec (apps démarrage)

  Moyenne (12 boots)                 28.7 secondes
  Meilleur boot                      19.2 secondes
  Pire boot                          45.1 secondes
  Boots dégradés                     2 / 12

  SCORE DE SANTÉ BOOT                [ B ]

  ┌─────────────────────────────────────────────────────┐
  │ DIAGNOSTIC DES GOULOTS D'ÉTRANGLEMENT               │
  └─────────────────────────────────────────────────────┘

  Type          Nom                              Moy.    Fréq.  Impact
  ────────────  ───────────────────────────────  ──────  ─────  ──────
  Service       McAfee WebAdvisor               8.3s    x12    99.6
  Application   OneDrive.exe                    4.1s    x10    41.0
  Driver        nvlddmkm.sys                    3.2s    x8     25.6
  Service       WSearch                         2.8s    x12    33.6
```

## Parameters

| Parameter | Description |
|-----------|-------------|
| `-AnalyseSeule` | Diagnostic only, no modifications |
| `-DryRun` | Simulate — shows what would be done |
| `-Force` | Apply system tweaks even if boot score is good |
| `-Historique` | Display boot time history and trends |
| `-Surveiller` | Install automatic monitoring scheduled task |

## Health Scores

| Score | Boot Time | Action |
|-------|-----------|--------|
| **A+** | ≤ 15s | No system tweaks needed |
| **A** | ≤ 25s | No system tweaks needed |
| **B** | ≤ 40s | No system tweaks needed |
| **C** | ≤ 60s | System tweaks applied automatically |
| **D** | ≤ 90s | System tweaks applied automatically |
| **F** | > 90s | System tweaks applied + alert generated |

## What Gets Optimized

### Startup Programs
- Detects non-essential programs in registry (`HKCU\...\Run`) and Startup folder
- Removes them from startup (programs stay installed)
- **Never touches**: audio drivers, Windows security, anti-cheat engines

### Services (only those proven slow by Event Logs)
- Switches slow services to **Delayed Start** (they start after the desktop)
- **No service is ever disabled** — just delayed
- Auto-detects OEM bloatware (HP, Dell, Lenovo, Asus, Acer, MSI)

### System Settings (only if score is C or worse)
- Enables Fast Startup (hybrid boot)
- Sets boot timeout to 0
- Optimizes Prefetch/Superfetch
- Disables Windows suggestions and Spotlight
- Disables background Store apps

## Safety

- **Whitelist protection**: essential programs and services are never touched
- **Snapshot diffing**: detects what changed since last run
- **Full logging**: every action is logged with timestamp
- **Rollback script**: `AnnulerOptimisations.ps1` reverts everything
- **DryRun mode**: simulate before applying
- **No external dependencies**: pure PowerShell 5.1, ships with Windows

## Compatibility

- Windows 10 version 1809+
- Windows 11 (all versions)
- Works without admin (limited) or with admin (full)
- PowerShell 5.1 (built into Windows, no install needed)

## File Structure

```
FasterBoot/
├── FasterBoot.ps1              # Main script (all-in-one)
├── AnnulerOptimisations.ps1    # Full rollback script
├── LICENSE                     # Apache 2.0
├── README.md                   # This file
├── CONTRIBUTING.md             # Contribution guidelines
└── docs/
    └── architecture.md         # Technical documentation
```

When FasterBoot runs, it creates a `FasterBoot_Data/` folder:

```
FasterBoot_Data/
├── boot_history.csv            # Boot time history
├── startup_snapshot.json       # Startup state snapshot
├── alertes.txt                 # Degradation alerts
└── log.txt                     # Action log
```

## Contributing

Contributions are welcome! See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

## License

Copyright 2026 NVK Labs

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
