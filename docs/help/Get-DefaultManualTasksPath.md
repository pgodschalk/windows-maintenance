---
external help file: WindowsMaintenance-help.xml
Module Name: WindowsMaintenance
online version:
schema: 2.0.0
---

# Get-DefaultManualTasksPath

## SYNOPSIS
Returns the default path of the manual-tasks config file.

## SYNTAX

```
Get-DefaultManualTasksPath
```

## DESCRIPTION
Returns %ProgramData%\WindowsMaintenance\manual-tasks.json -- the config that lists the things the tool
cannot action itself (firmware/BIOS, etc.) and surfaces at the end of a run. This is the default for the
entry script's -ManualTasksPath parameter. See manual-tasks.schema.json for the file's shape.

## EXAMPLES

### Example 1
```powershell
Get-DefaultManualTasksPath
```

Returns the full path to the default manual-tasks config file.

## PARAMETERS

## INPUTS

### None
## OUTPUTS

### System.String
## NOTES

## RELATED LINKS

[Get-DefaultStatePath](Get-DefaultStatePath.md)

[Get-DefaultBackupConfigPath](Get-DefaultBackupConfigPath.md)
