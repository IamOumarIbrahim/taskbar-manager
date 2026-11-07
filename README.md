# taskbar-manager

List every Windows 11 taskbar icon from the command line, and move pinned icons into [App Group](https://github.com/iandiv/AppGroup) groups to declutter your taskbar.

## Requirements

- Windows 11
- PowerShell 7
- [App Group](https://github.com/iandiv/AppGroup), with your groups already created and pinned

Listing icons works without App Group. No admin rights are needed.

## Quick start

```powershell
git clone https://github.com/IamOumarIbrahim/taskbar-manager.git
cd taskbar-manager
./taskbar.ps1 list
```

To move icons into groups, copy the example layout and edit it:

```powershell
Copy-Item layout.example.json layout.json
./taskbar.ps1 apply                      # preview
./taskbar.ps1 apply -Execute -SkipUnpin  # update groups only
./taskbar.ps1 apply -Execute             # update groups, then unpin
```

`layout.json` is ignored by git, so your personal layout stays private.

## Layout file

| Field | Required | Description |
| :--- | :--- | :--- |
| `moves[].pin` | Yes | Name of the shortcut in the pinned folder, without `.lnk` |
| `moves[].group` | Yes | App Group group to move it into |
| `moves[].path` | When adding | Shortcut or program for the group to launch. Environment variables work. Leave it out when the app is already in the group |
| `moves[].tooltip` | No | Label for the item. Defaults to `pin` |
| `groupColumns` | No | Columns to set per group, such as `{ "Work": 5 }` |

Use `./taskbar.ps1 apply -Layout path\to\layout.json` to load a layout from another location.

If a group item with the same file name points to a missing file, `path` repairs it in place. An icon is only unpinned after its group entry is saved and points to a file that exists.

## Limits

These come from how Windows and App Group behave:

- **Pinning:** Windows offers scripts an unpin action but no pin action, so new pins are manual.
- **Store apps:** Windows offers no unpin action for packaged apps such as PowerShell.
- **Taskbar order:** the order lives in an undocumented registry value, so drag icons by hand.
- **Group icons:** new items are added at the end, so the group's icon isn't redrawn automatically.

## How App Group stores data

- `%LOCALAPPDATA%\AppGroup\appgroups.json` holds the groups. Each item in `path` is keyed by its file path and has `tooltip`, `args` and `icon`.
- `%LOCALAPPDATA%\AppGroup\Icons\` holds 32×32 PNGs for group items.
- App Group keeps the config in memory, so this tool restarts it with `--silent` when it writes.
- A pinned group is a shortcut that runs `AppGroup.exe "<group name>"`.

## Undo

Each `apply -Execute` saves `appgroups.json`, your pinned shortcuts and the taskbar registry export to `backups/<timestamp>/`.

**To restore App Group:** exit it and copy `appgroups.json` back to `%LOCALAPPDATA%\AppGroup\`.

**To restore pins:** copy `PinnedTaskBar` back to `%APPDATA%\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar`, import `Taskband.reg`, and restart Explorer.

## License

[MIT](LICENSE) © 2026 Oumar Ibrahim
