---
Module Name: WindowsMaintenance
Module Guid: 5c3a2ea7-0127-4bc3-89ed-f3f9e38b7954
Download Help Link: https://pgodschalk.github.io/windows-maintenance/
Help Version: 1.0.2
Locale: en-US
---

# WindowsMaintenance Module
## Description
Updatable help for the WindowsMaintenance module's public commands. The tool is normally run via the
Invoke-WindowsMaintenance.ps1 entry script (run `Get-Help ./Invoke-WindowsMaintenance.ps1`); the commands
below are the programmatic surface for driving or composing it yourself.

## WindowsMaintenance Cmdlets
### [Get-DefaultBackupConfigPath](Get-DefaultBackupConfigPath.md)
Returns the default path of the encrypted-backup config file.

### [Get-DefaultManualTasksPath](Get-DefaultManualTasksPath.md)
Returns the default path of the manual-tasks config file.

### [Get-DefaultStatePath](Get-DefaultStatePath.md)
Returns the default path of the last-invocation state file.

### [Invoke-UpdateRun](Invoke-UpdateRun.md)
Runs one maintenance invocation against a set of injected provider ports.

### [New-WindowsMaintenanceComposition](New-WindowsMaintenanceComposition.md)
Builds the wired set of dependencies that Invoke-UpdateRun needs.
