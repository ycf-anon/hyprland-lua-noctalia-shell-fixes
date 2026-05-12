# Hyprland 0.55 + Lua Fix Guide (Noctalia Shell v4)

Hyprland 0.55 dropped the old `hyprlang .conf` dispatch behavior in favor of **Lua-based dispatch execution**.

This change breaks compatibility with **Noctalia Shell v4**, which still uses the old `hyprctl dispatch` syntax internally.

This repository contains:
- Patched `HyprlandService.qml`
- A full fix guide for restoring functionality in Noctalia Shell v4

---

## What Broke and Why

### Hyprland ≤ 0.54 (Old Behavior)

Hyprland used simple string-based dispatch commands:

```bash
hyprctl dispatch exec firefox
hyprctl dispatch workspace 2
hyprctl dispatch exit
```

---

### Hyprland ≥ 0.55 (New Behavior)

Hyprland now executes Lua-based dispatch calls:

```bash
hyprctl dispatch 'hl.dsp.exec_cmd("firefox")'
hyprctl dispatch 'hl.dsp.focus({workspace="2"})'
hyprctl dispatch 'hl.dsp.exit()'
```

---

### Why Noctalia Shell v4 Breaks

Noctalia Shell v4 still uses the old syntax inside:

```
HyprlandService.qml
```

As a result, several features stop working.

---

## Broken Features

| Feature | Issue |
|--------|------|
| App Launcher | Apps do not launch when clicked |
| Workspace Switcher | Workspace buttons do nothing |
| Window Focus | Clicking grouped windows fails |
| Close Window | Context menu close does not work |
| Monitor Power | DPMS off/on broken |
| Logout Menu | Session exit does not work |

---

## The Fix

You need to patch this system file:

```
/etc/xdg/quickshell/noctalia-shell/Services/Compositor/HyprlandService.qml
```

---

### Apply Patch (System File)

Because this is a system path, you must use `pkexec`:

```bash
pkexec cp HyprlandService.qml /etc/xdg/quickshell/noctalia-shell/Services/Compositor/HyprlandService.qml
```

---

### Reload Noctalia Shell

After applying the patch:

```bash
killall qs; sleep 1; qs -c noctalia-shell
```

---

## What This Patch Fixes

The patched `HyprlandService.qml` restores compatibility with Hyprland 0.55+ Lua dispatch.

### Fixed Functions

- spawn() → Launch apps from launcher
- switchToWorkspace() → Workspace bar buttons
- focusWindow() → Focus windows in grouped view
- closeWindow() → Close windows from context menu
- turnOffMonitors() → DPMS monitor off
- turnOnMonitors() → DPMS monitor on
- logout() → Session logout / exit

---

## Summary

This fix restores full Noctalia Shell v4 functionality on Hyprland 0.55+ by updating deprecated `hyprctl dispatch` calls to the new Lua-based dispatch system.
