# Contributing to FasterBoot

Thank you for your interest in contributing to FasterBoot!

## How to Contribute

1. **Fork** the repository
2. **Create a branch** for your feature: `git checkout -b feature/my-feature`
3. **Make your changes** following the guidelines below
4. **Test** on both Windows 10 and Windows 11 if possible
5. **Submit a Pull Request** with a clear description

## Guidelines

### Code Style
- PowerShell 5.1 compatible (no PowerShell 7+ features)
- Use `Write-Host` with `-ForegroundColor` for user-facing output
- Use `Write-Log` for action logging
- Comment in English for code, French is acceptable for user-facing strings

### Safety Rules
- **Never disable a service** — only delay start
- **Never modify HKLM** without admin check
- **Always check the protected whitelist** before modifying anything
- **Always provide a rollback path** for any new optimization
- **Always use `-ErrorAction SilentlyContinue`** for non-critical operations

### Testing
- Test with `-DryRun` before testing live
- Test with and without admin rights
- Test on a clean Windows 10 and Windows 11 install if possible
- Verify that `AnnulerOptimisations.ps1` correctly reverses your changes

### Adding New Optimizations
1. Add Event Log analysis first (prove the bottleneck exists)
2. Add the optimization with proper admin/whitelist checks
3. Add the rollback in `AnnulerOptimisations.ps1`
4. Update the README if needed

## Reporting Issues

- Include your Windows version and build number
- Include the output of `.\FasterBoot.ps1 -AnalyseSeule`
- Describe what you expected vs what happened

## License

By contributing, you agree that your contributions will be licensed under Apache 2.0.
