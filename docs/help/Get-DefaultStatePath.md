---
external help file: WindowsMaintenance-help.xml
Module Name: WindowsMaintenance
online version:
schema: 2.0.0
---

# Get-DefaultStatePath

## SYNOPSIS
Returns the default path of the last-invocation state file.

## SYNTAX

```
Get-DefaultStatePath
```

## DESCRIPTION
Returns %ProgramData%\WindowsMaintenance\last-invocation.json -- the machine-scoped file where the trimmed
last-run record is stored. This is the default for the entry script's -StatePath parameter.

## EXAMPLES

### Example 1
```powershell
Get-DefaultStatePath
```

Returns the full path to the default last-invocation state file.

## PARAMETERS

## INPUTS

### None
## OUTPUTS

### System.String
## NOTES

## RELATED LINKS

[Get-DefaultManualTasksPath](Get-DefaultManualTasksPath.md)

[Get-DefaultBackupConfigPath](Get-DefaultBackupConfigPath.md)
