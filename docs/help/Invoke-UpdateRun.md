---
external help file: WindowsMaintenance-help.xml
Module Name: WindowsMaintenance
online version:
schema: 2.0.0
---

# Invoke-UpdateRun

## SYNOPSIS
Runs one maintenance invocation against a set of injected provider ports.

## SYNTAX

```
Invoke-UpdateRun [[-Providers] <Object[]>] [-Clock] <Object> [-StateStore] <Object> [-EventSink] <Object>
 [-Presenter] <Object> [-Environment] <Object> [[-HostName] <String>] [-ProgressAction <ActionPreference>]
 [-WhatIf] [-Confirm] [<CommonParameters>]
```

## DESCRIPTION
The use-case orchestrator (the imperative shell). It displays the last run, runs each provider
resiliently -- a provider that throws becomes a Failed result and never aborts the others -- folds the
per-provider results into a RunReport, persists a trimmed last-invocation record, and emits exactly one
canonical wide event. If a reboot is required and the session is interactive it prompts through the
presenter. It returns the RunReport (or a RunResult on the elevation/fail-fast path), with the emitted
event attached as a WideEvent property.

You normally do not call this directly: `Invoke-WindowsMaintenance.ps1` builds the dependencies with
New-WindowsMaintenanceComposition and calls it. Call it yourself only when composing the module by hand
or testing with fake ports.

## EXAMPLES

### Example 1
```powershell
$c = New-WindowsMaintenanceComposition -ScriptVersion '1.0.0'
$report = Invoke-UpdateRun -Providers $c.Providers -Clock $c.Clock -StateStore $c.StateStore `
  -EventSink $c.EventSink -Presenter $c.Presenter -Environment $c.Environment -HostName $c.HostName
$report.OverallOutcome
```

Wires the default dependencies with New-WindowsMaintenanceComposition and runs them, returning the
RunReport for the invocation.

## PARAMETERS

### -Clock
An IClock port -- a `[pscustomobject]` with a `Now` scriptblock returning the current `[datetimeoffset]`.

```yaml
Type: Object
Parameter Sets: (All)
Aliases:

Required: True
Position: 1
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Confirm
Prompts you for confirmation before running the cmdlet.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: cf

Required: False
Position: Named
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Environment
The Environment value object produced by Get-EnvironmentInfo (OS build, elevation, interactivity, locale).

```yaml
Type: Object
Parameter Sets: (All)
Aliases:

Required: True
Position: 5
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -EventSink
An IEventSink port (an `Emit` scriptblock) that receives the single canonical wide event for the run.

```yaml
Type: Object
Parameter Sets: (All)
Aliases:

Required: True
Position: 3
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -HostName
The machine name recorded as the event's `host` field. Defaults to the COMPUTERNAME environment variable.

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

### -Presenter
An IPresenter port with ShowLastRun/ShowProgress/ShowSummary/ShowAlert (stderr) and ConfirmReboot members.

```yaml
Type: Object
Parameter Sets: (All)
Aliases:

Required: True
Position: 4
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -Providers
The ordered list of IUpdateProvider ports to run. Each is a closure record carrying a Target plus GetPlan
and Apply scriptblocks; order is execution order. An empty list yields a NothingToDo run.

```yaml
Type: Object[]
Parameter Sets: (All)
Aliases:

Required: False
Position: 0
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -StateStore
An IStateStore port (Load/Save scriptblocks) that reads and writes the trimmed last-invocation record.

```yaml
Type: Object
Parameter Sets: (All)
Aliases:

Required: True
Position: 2
Default value: None
Accept pipeline input: False
Accept wildcard characters: False
```

### -WhatIf
Shows what would happen if the cmdlet runs.
The cmdlet is not run.

```yaml
Type: SwitchParameter
Parameter Sets: (All)
Aliases: wi

Required: False
Position: Named
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
Under -WhatIf each provider's Apply is gated by ShouldProcess, so nothing is changed and every target
reports NothingToDo.

## RELATED LINKS

[New-WindowsMaintenanceComposition](New-WindowsMaintenanceComposition.md)
