#Requires -Version 7
<#
.SYNOPSIS
    List every taskbar icon and move pinned icons into App Group groups.

.EXAMPLE
    ./taskbar.ps1 list
    ./taskbar.ps1 apply                        # dry run
    ./taskbar.ps1 apply -Execute -SkipUnpin    # update groups only
    ./taskbar.ps1 apply -Execute               # update groups, then unpin
    ./taskbar.ps1 add -Group Work -Path app.lnk -Execute   # add an app that isn't pinned
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('list', 'apply', 'add')]
    [string]$Command = 'list',

    [string]$Layout = (Join-Path $PSScriptRoot 'layout.json'),

    # add: App Group group, shortcut or program to put in it, optional label
    [string]$Group,
    [string]$Path,
    [string]$Tooltip,

    [switch]$Execute,

    [switch]$SkipUnpin
)

$ErrorActionPreference = 'Stop'

$PinnedDir = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
$AppGroupDir = Join-Path $env:LOCALAPPDATA 'AppGroup'
$ConfigPath = Join-Path $AppGroupDir 'appgroups.json'
$IconsDir = Join-Path $AppGroupDir 'Icons'
$AppGroupExe = 'C:\Program Files\App Group\AppGroup.exe'

function Get-TaskbarIcons {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $classCondition = [Windows.Automation.PropertyCondition]::new(
        [Windows.Automation.AutomationElement]::ClassNameProperty, 'Shell_TrayWnd')
    $tray = [Windows.Automation.AutomationElement]::RootElement.FindFirst(
        [Windows.Automation.TreeScope]::Children, $classCondition)
    if (-not $tray) { throw 'The taskbar could not be found.' }

    $buttons = $tray.FindAll([Windows.Automation.TreeScope]::Descendants,
        [Windows.Automation.Condition]::TrueCondition) |
        ForEach-Object { $_.Current } |
        Where-Object { $_.AutomationId -like 'Appid:*' } |
        Sort-Object { $_.BoundingRectangle.X }

    $position = 0
    foreach ($button in $buttons) {
        $position++
        $rawName = $button.Name
        $name = $rawName -replace '\s+-\s+\d+ running windows?', '' -replace '\s+pinned$', ''
        [pscustomobject]@{
            Position = $position
            Name     = $name
            Pinned   = $rawName -match 'pinned$'
            Running  = $rawName -match 'running window'
            AppId    = $button.AutomationId -replace '^Appid:', ''
        }
    }
}

function Read-AppGroupConfig {
    Get-Content -LiteralPath $ConfigPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
}

function Find-Group($Config, [string]$GroupName) {
    $Config.PSObject.Properties.Value | Where-Object { $_.groupName -eq $GroupName } | Select-Object -First 1
}

function Find-Member($Group, [string]$ItemPath) {
    $leaf = Split-Path $ItemPath -Leaf
    $Group.path.PSObject.Properties | Where-Object { (Split-Path $_.Name -Leaf) -eq $leaf } | Select-Object -First 1
}

function Repair-Member($Group, [string]$ItemPath) {
    $member = Find-Member $Group $ItemPath
    if (-not $member -or $member.Name -eq $ItemPath -or (Test-Path -LiteralPath $member.Name)) { return }

    # Rebuild the list so the repaired item keeps its place in the group icon.
    $rebuilt = [ordered]@{}
    foreach ($property in $Group.path.PSObject.Properties) {
        $key = if ($property.Name -eq $member.Name) { $ItemPath } else { $property.Name }
        $rebuilt[$key] = $property.Value
    }
    $Group.path = [pscustomobject]$rebuilt
}

function Save-MemberIcon([string]$ItemPath) {
    Add-Type -AssemblyName System.Drawing
    $source = $ItemPath
    if ($ItemPath -like '*.lnk') {
        $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($ItemPath)
        $iconFile = [Environment]::ExpandEnvironmentVariables(($shortcut.IconLocation -replace ',-?\d+$', ''))
        $source = if ($iconFile -and (Test-Path -LiteralPath $iconFile)) { $iconFile } else { $shortcut.TargetPath }
    }

    $icon = if ($source -like '*.ico') {
        [System.Drawing.Icon]::new($source, 32, 32)
    } else {
        [System.Drawing.Icon]::ExtractAssociatedIcon($source)
    }
    $bitmap = [System.Drawing.Bitmap]::new($icon.ToBitmap(), 32, 32)

    $hashBytes = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($ItemPath))
    $hash = ([Convert]::ToHexString($hashBytes)).Substring(0, 16).ToLower()
    $iconPath = Join-Path $IconsDir "$(Split-Path $ItemPath -Leaf)_$hash.png"
    $bitmap.Save($iconPath, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    $icon.Dispose()
    return $iconPath
}

function Get-Plan($Moves, $Config) {
    foreach ($move in $Moves) {
        $path = if ($move.path) { [Environment]::ExpandEnvironmentVariables($move.path) } else { $null }
        $group = Find-Group $Config $move.group
        if (-not $group) { throw "Group '$($move.group)' does not exist in App Group." }

        $shortcutPath = Join-Path $PinnedDir "$($move.pin).lnk"
        if (-not (Test-Path -LiteralPath $shortcutPath)) {
            Write-Host "skip  $($move.pin): not pinned"
            continue
        }
        if ($path -and -not (Test-Path -LiteralPath $path)) { throw "Missing target for '$($move.pin)': $path" }

        $alreadyInGroup = if ($path) { [bool](Find-Member $group $path) } else { $false }
        if (-not $path) {
            $alreadyInGroup = [bool](Find-Member $group "$($move.pin).lnk")
            if (-not $alreadyInGroup) { throw "'$($move.pin)' has no path and is not in '$($move.group)'." }
        }

        [pscustomobject]@{
            Pin            = $move.pin
            Group          = $move.group
            Path           = $path
            Tooltip        = if ($move.tooltip) { $move.tooltip } else { $move.pin }
            AlreadyInGroup = $alreadyInGroup
        }
    }
}

function Save-AppGroupConfig($Config) {
    $json = $Config | ConvertTo-Json -Depth 20
    $null = $json | ConvertFrom-Json -Depth 20
    $tempPath = "$ConfigPath.tmp"
    [IO.File]::WriteAllText($tempPath, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tempPath -Destination $ConfigPath -Force
}

function Update-Groups($Plan, $Config, $ColumnChanges) {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backupDir = Join-Path $PSScriptRoot "backups\$stamp"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    Copy-Item -LiteralPath $ConfigPath -Destination $backupDir
    Copy-Item -LiteralPath $PinnedDir -Destination (Join-Path $backupDir 'PinnedTaskBar') -Recurse -Force
    reg export 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' (Join-Path $backupDir 'Taskband.reg') /y | Out-Null

    foreach ($entry in $Plan) {
        $group = Find-Group $Config $entry.Group
        if ($entry.AlreadyInGroup) {
            if ($entry.Path) { Repair-Member $group $entry.Path }
            continue
        }
        $member = [pscustomobject]@{ tooltip = $entry.Tooltip; args = ''; icon = Save-MemberIcon $entry.Path }
        $group.path | Add-Member -NotePropertyName $entry.Path -NotePropertyValue $member
    }
    foreach ($change in $ColumnChanges.PSObject.Properties) {
        (Find-Group $Config $change.Name).groupCol = $change.Value
    }

    # App Group keeps the config in memory, so restart it around the write.
    Get-Process -Name AppGroup -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    Save-AppGroupConfig $Config
    Start-Process -FilePath $AppGroupExe -ArgumentList '--silent' -WorkingDirectory (Split-Path $AppGroupExe)
}

function Remove-Pin([string]$Name) {
    $folder = (New-Object -ComObject Shell.Application).Namespace($PinnedDir)
    $item = $folder.ParseName("$Name.lnk")
    if (-not $item) { throw "Pinned shortcut not found: $Name" }
    $verb = $item.Verbs() | Where-Object { ($_.Name -replace '&', '') -eq 'Unpin from taskbar' }
    if (-not $verb) { throw "Windows does not offer an unpin action for: $Name" }
    $verb.DoIt()
}

if ($Command -eq 'list') {
    Get-TaskbarIcons | Format-Table Position, Name, Pinned, Running, AppId -AutoSize
    return
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "App Group data was not found at $ConfigPath. Install App Group and create a group first."
}

if ($Command -eq 'add') {
    # Windows has no scriptable pin action, but a group is already pinned, so
    # adding the app to a group puts it on the taskbar.
    if (-not $Group -or -not $Path) { throw 'add needs -Group and -Path.' }
    $itemPath = [Environment]::ExpandEnvironmentVariables($Path)
    if (-not (Test-Path -LiteralPath $itemPath)) { throw "Not found: $itemPath" }
    $itemPath = (Resolve-Path -LiteralPath $itemPath).Path
    $config = Read-AppGroupConfig
    $target = Find-Group $config $Group
    if (-not $target) { throw "Group '$Group' does not exist in App Group." }
    $label = if ($Tooltip) { $Tooltip } else { [IO.Path]::GetFileNameWithoutExtension($itemPath) }
    $plan = @([pscustomobject]@{
            Pin            = $label
            Group          = $Group
            Path           = $itemPath
            Tooltip        = $label
            AlreadyInGroup = [bool](Find-Member $target $itemPath)
        })
    $plan | Format-Table Pin, Group, AlreadyInGroup -AutoSize
    if (-not $Execute) {
        Write-Host 'Dry run. Add -Execute to apply.'
        return
    }
    Update-Groups $plan $config ([pscustomobject]@{})
    if (-not (Find-Member (Find-Group (Read-AppGroupConfig) $Group) $itemPath)) {
        throw "'$label' is missing from '$Group' after saving."
    }
    Write-Host "added  $label -> $Group"
    return
}

if (-not (Test-Path -LiteralPath $Layout)) {
    throw "Layout not found: $Layout. Copy layout.example.json to layout.json and edit it."
}

$layoutData = Get-Content -LiteralPath $Layout -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
$config = Read-AppGroupConfig
$plan = @(Get-Plan $layoutData.moves $config)
$plan | Format-Table Pin, Group, AlreadyInGroup -AutoSize

if (-not $Execute) {
    Write-Host 'Dry run. Add -Execute to apply.'
    return
}

Update-Groups $plan $config $layoutData.groupColumns

$saved = Read-AppGroupConfig
foreach ($entry in $plan) {
    $memberPath = if ($entry.Path) { $entry.Path } else { "$($entry.Pin).lnk" }
    $member = Find-Member (Find-Group $saved $entry.Group) $memberPath
    if (-not $member) {
        throw "'$($entry.Pin)' is missing from '$($entry.Group)'. Nothing was unpinned."
    }
    if (-not (Test-Path -LiteralPath $member.Name)) {
        throw "'$($entry.Pin)' in '$($entry.Group)' points to a missing file: $($member.Name). Nothing was unpinned."
    }
}
Write-Host 'Groups saved and verified.'

if ($SkipUnpin) { return }

foreach ($entry in $plan) {
    Remove-Pin $entry.Pin
    Write-Host "unpinned  $($entry.Pin)"
}
Start-Sleep -Seconds 2
Get-TaskbarIcons | Format-Table Position, Name, Pinned, Running -AutoSize
