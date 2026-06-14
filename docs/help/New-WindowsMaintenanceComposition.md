---
external help file: WindowsMaintenance-help.xml
Module Name: WindowsMaintenance
online version:
schema: 2.0.0
---

# New-WindowsMaintenanceComposition

## SYNOPSIS
Builds the wired set of dependencies that Invoke-UpdateRun needs.

## SYNTAX

```
New-WindowsMaintenanceComposition [[-ScriptVersion] <String>] [[-WingetPackageId] <String[]>]
 [[-WingetExcludeId] <String[]>] [-WingetMachineScope] [-IncludeDrivers]
 [[-BackupConfigPath] <String>] [[-ManualTasksPath] <String>] [[-StatePath] <String>]
 [[-EventLogName] <String>] [[-EventLogSource] <String>] [-Quiet] [-ProgressAction <ActionPreference>]
 [<CommonParameters>]
```

## DESCRIPTION
The composition root -- the one place that knows the concrete adapters. It reads the host environment,
builds the ordered provider list (Windows Update, winget, Defender signatures, the silent alert-only
maintenance checks, the encrypted backup, then one manual-advisory provider per configured manual task),
and constructs the clock, state store, event sink, and presenter. It returns a single object whose
members (`Providers`, `Clock`, `StateStore`, `EventSink`, `Presenter`, `Environment`, `HostName`) are
passed straight to Invoke-UpdateRun.

## EXAMPLES

### Example 1
```powershell
$c = New-WindowsMaintenanceComposition -ScriptVersion '1.1.0' -WingetExcludeId 'Foo.Bar'
$c.Providers.Count
```

Builds the default composition while pinning the winget package `Foo.Bar` so it is never upgraded.

## PARAMETERS

### -BackupConfigPath
Path to the encrypted-backup config. Defaults to %ProgramData%\WindowsMaintenance\backup-config.json; if
the file is absent, the backup provider stays silent.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -EventLogName
Windows Event Log to write the canonical wide event to. Defaults to 'WindowsMaintenance'.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 7
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -EventLogSource
Event Log source name for the wide event. Defaults to 'WindowsMaintenance'.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 8
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -IncludeDrivers
Also install driver updates from Windows Update. Off by default (drivers are managed separately).

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ManualTasksPath
Path to the manual-tasks JSON config. Defaults to %ProgramData%\WindowsMaintenance\manual-tasks.json.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 5
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Quiet
Suppress console narration so stdout carries only machine output. Used by the entry script's -Json switch.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ScriptVersion
Version string recorded as `env.script_version` in the wide event. The entry script passes the module version.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 0
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -StatePath
Path to the last-invocation state file. Defaults to %ProgramData%\WindowsMaintenance\last-invocation.json.

```yaml
Type: String
Parameter Sets: (All)
Aliases:

Required: False
Position: 6
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -WingetExcludeId
Package IDs to hold back / pin so they are never upgraded, e.g. 'Foo.Bar'.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -WingetMachineScope
Pass --scope machine to winget upgrades.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases:

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -WingetPackageId
Restrict winget to these exact package IDs. Omit (the default) to upgrade every package winget reports.

```yaml
Type: String[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -ProgressAction
The standard `-ProgressAction` common parameter; controls how progress records are handled.

```yaml
Type: ActionPreference
Parameter Sets: (All)
Aliases: proga

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### CommonParameters
This cmdlet supports the common parameters: -Debug, -ErrorAction, -ErrorVariable, -InformationAction, -InformationVariable, -OutVariable, -OutBuffer, -PipelineVariable, -Verbose, -WarningAction, and -WarningVariable. For more information, see [about_CommonParameters](http://go.microsoft.com/fwlink/?LinkID=113216).

## INPUTS

### None
## OUTPUTS

### System.Object
## NOTES
Building the composition is cheap and side-effect-free apart from reading host environment facts; the
providers do their work later, inside Invoke-UpdateRun.

## RELATED LINKS

[Invoke-UpdateRun](Invoke-UpdateRun.md)
