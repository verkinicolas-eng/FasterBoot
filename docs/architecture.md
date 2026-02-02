# FasterBoot - Technical Architecture

## Design Philosophy

**Measure first, optimize second.**

Unlike every other Windows optimizer, FasterBoot does not apply generic tweaks. It uses data that Windows already collects natively to build a precise diagnostic, then applies targeted fixes.

## Modules

### Module 1: Boot Performance Measurement

**Source**: `Microsoft-Windows-Diagnostics-Performance/Operational` Event Log

| Event ID | Data Extracted |
|----------|---------------|
| 100 | `BootTime`, `MainPathBootTime`, `BootPostBootTime`, `BootIsDegradation` |
| 101 | Slow application name, `TotalTime`, `FilePath` |
| 102 | Slow driver name, `TotalTime` |
| 103 | Slow service name, `TotalTime` |

The XML payload of each event is parsed to extract performance metrics. Boot times are converted from milliseconds to seconds for display.

**Health Score Algorithm:**

```
A+  ≤ 15s
A   ≤ 25s
B   ≤ 40s
C   ≤ 60s    → triggers system tweaks
D   ≤ 90s    → triggers system tweaks
F   > 90s    → triggers system tweaks + alert
```

### Module 2: Bottleneck Identification

Events 101-103 are aggregated by name. For each item:
- **AvgSec**: average duration across all occurrences
- **Count**: number of times it appeared in boot logs
- **Impact**: `AvgSec * Count` — a composite score ranking real impact

Items are sorted by Impact descending. Only items with `AvgSec >= 1s` (services) or `AvgSec >= 2s` (applications) are candidates for optimization.

### Module 3: Startup Snapshot & Change Detection

A JSON snapshot captures:
- `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` entries
- `HKLM\Software\Microsoft\Windows\CurrentVersion\Run` entries
- Startup folder `.lnk` files
- Services with `StartType = Automatic`

On subsequent runs, the current state is diffed against the snapshot. New entries are flagged as potential intrusions.

### Module 4: Smart Optimization Engine

Optimization decisions are data-driven:

1. **Services**: Only services identified as slow by Event ID 103 (AvgSec >= 1s) are switched to `AutomaticDelayedStart`. Protected services are never touched.

2. **Startup Programs**: Programs in the known non-essential list are removed. Additionally, any application identified as slow by Event ID 101 (AvgSec >= 2s) is removed.

3. **System Tweaks**: Only applied if the health score is C or worse (or `-Force` flag). Includes:
   - Fast Startup (HiberbootEnabled)
   - Boot timeout (bcdedit)
   - Prefetch/Superfetch optimization
   - Background apps, suggestions, Spotlight

### Module 5: Historical Tracking

Boot data is appended to `boot_history.csv` with columns:
```
Date, BootTimeSec, MainPathSec, PostBootSec, Score
```

Trend detection splits history in two halves and compares averages:
- `avgSecondHalf < avgFirstHalf * 0.9` → Improving
- `avgSecondHalf > avgFirstHalf * 1.1` → Degrading
- Otherwise → Stable

### Module 6: Automated Monitoring

A scheduled task (`FasterBoot_Monitor`) runs at logon and weekly:
1. Records boot time from Event ID 100
2. Diffs startup state against snapshot
3. Writes alerts to `alertes.txt` if boot > 90s or new startup entries
4. Cleans temp files

### Module 7: 3-Layer Automatic Cleaning System

Installed via `FasterBoot-Install.ps1`. Three complementary cleaning layers keep the system fast continuously.

#### Layer 1: Shutdown Cleanup (GPO Shutdown Script)

**Mechanism**: Windows Group Policy Shutdown Script — executes inside the Windows shutdown process itself, like Windows Update.

**Registry keys**:
- `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\Scripts\Shutdown`
- `HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\State\Machine\Scripts\Shutdown`

**File location**: `C:\Windows\System32\GroupPolicy\Machine\Scripts\Shutdown\FasterBoot-Shutdown.ps1`

**What it cleans**:
| Target | Details |
|--------|---------|
| User temp (`$env:TEMP`) | All files |
| System temp (`C:\Windows\Temp`) | All files |
| Browser HTTP caches | Chrome, Edge, Firefox, Brave `Cache\Cache_Data` |
| DNS cache | `ipconfig /flushdns` |
| Thumbnail cache | `$env:LOCALAPPDATA\Microsoft\Windows\Explorer\thumbcache_*` |
| Crash dumps | `C:\Windows\Minidump`, `C:\Windows\MEMORY.DMP` |
| Old Prefetch | Files older than 30 days in `C:\Windows\Prefetch` |
| Windows Update cache | `C:\Windows\SoftwareDistribution\Download` files > 14 days |
| Delivery Optimization | `C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache` |
| Recycle bin | `Clear-RecycleBin -Force` |

**Impact**: Next boot loads a clean, lighter system. No user interaction needed.

#### Layer 2: Idle Cleanup

**Mechanism**: Windows Task Scheduler with idle trigger conditions.

**Settings**:
- `RunOnlyIfIdle = $true`
- `IdleDuration = PT10M` (triggers after 10 min without keyboard/mouse)
- `WaitTimeout = PT8H` (waits up to 8 hours for idle)
- `StopOnIdleEnd = $true` (stops immediately if user returns)
- `RestartOnIdle = $true` (resumes when user leaves again)

**Script**: Same `FasterBoot-Shutdown.ps1` — full cleanup during idle time.

**Impact**: Zero impact on usage. Runs silently, stops instantly when needed.

#### Layer 3: Startup Guard

**Mechanism**: Scheduled task at logon + weekly Monday 8:00.

**What it does**:
1. Records boot time from Event ID 100 to `boot_history.csv`
2. Compares current `HKCU\...\Run` entries against `startup_snapshot.json`
3. Logs new intrusions to `alertes.txt`
4. Generates alert if boot time > 90 seconds
5. Cleans temp files

**Impact**: Catches programs sneaking back into startup after updates.

## Security Model

### Protected Whitelists

**Services never touched:**
```
wuauserv, WinDefend, MpsSvc, BFE, EventLog, RpcSs, DcomLaunch, LSM,
SamSs, Schedule, Power, Winmgmt, AudioSrv, AudioEndpointBuilder,
Dnscache, Dhcp, nsi, LanmanWorkstation, LanmanServer, CryptSvc,
ProfSvc, UserManager, CoreMessagingRegistrar, BrokerInfrastructure,
SystemEventsBroker, Themes, WlanSvc, vgc, vgk
```

**Startup programs never touched:**
```
SecurityHealth, WindowsDefender, RtkAudUService, Riot Vanguard,
vgtray, EasyAntiCheat, BEService, cFosSpeed, Nahimic
```

### Admin Boundary

- `HKCU` modifications: no admin required
- `HKLM` modifications: admin required, checked at runtime
- `bcdedit`: admin required, checked at runtime
- `Set-Service`: admin required, checked at runtime

All admin operations fail gracefully with a warning when run without elevation.

## Data Flow

```
                    Windows Event Logs
                    (ID 100-103)
                          │
                          ▼
                ┌─────────────────┐
                │  Module 1       │
                │  Boot Metrics   │──────► boot_history.csv
                └────────┬────────┘
                         │
                         ▼
                ┌─────────────────┐
                │  Module 2       │
                │  Bottlenecks    │──────► Impact ranking
                └────────┬────────┘
                         │
                         ▼
                ┌─────────────────┐
                │  Module 3       │
                │  Snapshot Diff  │──────► startup_snapshot.json
                └────────┬────────┘
                         │
                         ▼
                ┌─────────────────┐
                │  Module 4       │
                │  Smart Optimize │──────► log.txt
                └────────┬────────┘
                         │
                         ▼
                ┌─────────────────┐
                │  Module 5       │
                │  History/Trends │──────► ASCII graph
                └─────────────────┘
```
