---
external help file: WindowsMaintenance-help.xml
Module Name: WindowsMaintenance
online version:
schema: 2.0.0
---

# Get-DefaultBackupConfigPath

## SYNOPSIS
Returns the default path of the encrypted-backup config file.

## SYNTAX

```
Get-DefaultBackupConfigPath
```

## DESCRIPTION
Returns %ProgramData%\WindowsMaintenance\backup-config.json -- the config that defines the restic
repository, the paths to back up, and the 1Password op:// secret references. This is the default for the
entry script's -BackupConfigPath parameter; if the file is absent, backup is skipped. See
backup-config.schema.json for the file's shape.

## EXAMPLES

### Example 1
```powershell
Get-DefaultBackupConfigPath
```

Returns the full path to the default encrypted-backup config file.

## PARAMETERS

## INPUTS

### None
## OUTPUTS

### System.String
## NOTES

## RELATED LINKS

[Get-DefaultStatePath](Get-DefaultStatePath.md)

[Get-DefaultManualTasksPath](Get-DefaultManualTasksPath.md)
