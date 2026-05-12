import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Services.Keyboard

Item {
  id: root

  property ListModel workspaces: ListModel {}
  property var windows: []
  property int focusedWindowIndex: -1

  signal workspaceChanged
  signal activeWindowChanged
  signal windowListChanged
  signal displayScalesChanged

  property bool initialized: false
  property var workspaceCache: ({})
  property var windowCache: ({})

  Timer {
    id: updateTimer
    interval: 50
    repeat: false
    onTriggered: safeUpdate()
  }

  function _deferredWorkspaceUpdate() {
    safeUpdateWorkspaces();
    workspaceChanged();
  }

  function initialize() {
    if (initialized)
      return;
    try {
      Hyprland.refreshWorkspaces();
      Hyprland.refreshToplevels();
      Qt.callLater(() => {
                     safeUpdateWorkspaces();
                     safeUpdateWindows();
                     queryDisplayScales();
                     queryKeyboardLayout();
                   });
      initialized = true;
      Logger.i("HyprlandService", "Service started");
    } catch (e) {
      Logger.e("HyprlandService", "Failed to initialize:", e);
    }
  }

  function queryDisplayScales() {
    hyprlandMonitorsProcess.running = true;
  }

  Process {
    id: hyprlandMonitorsProcess
    running: false
    command: ["hyprctl", "monitors", "-j"]
    property string accumulatedOutput: ""
    stdout: SplitParser {
      onRead: function (line) {
        hyprlandMonitorsProcess.accumulatedOutput += line;
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 || !accumulatedOutput) {
        Logger.e("HyprlandService", "Failed to query monitors, exit code:", exitCode);
        accumulatedOutput = "";
        return;
      }
      try {
        const monitorsData = JSON.parse(accumulatedOutput);
        const scales = {};
        for (const monitor of monitorsData) {
          if (monitor.name) {
            scales[monitor.name] = {
              "name": monitor.name,
              "scale": monitor.scale || 1.0,
              "width": monitor.width || 0,
              "height": monitor.height || 0,
              "refresh_rate": monitor.refreshRate || 0,
              "x": monitor.x || 0,
              "y": monitor.y || 0,
              "active_workspace": monitor.activeWorkspace ? monitor.activeWorkspace.id : -1,
              "vrr": monitor.vrr || false,
              "focused": monitor.focused || false
            };
          }
        }
        if (CompositorService && CompositorService.onDisplayScalesUpdated) {
          CompositorService.onDisplayScalesUpdated(scales);
        }
      } catch (e) {
        Logger.e("HyprlandService", "Failed to parse monitors:", e);
      } finally {
        accumulatedOutput = "";
      }
    }
  }

  function queryKeyboardLayout() {
    hyprlandDevicesProcess.running = true;
  }

  Process {
    id: hyprlandDevicesProcess
    running: false
    command: ["hyprctl", "devices", "-j"]
    property string accumulatedOutput: ""
    stdout: SplitParser {
      onRead: function (line) {
        hyprlandDevicesProcess.accumulatedOutput += line;
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0 || !accumulatedOutput) {
        Logger.e("HyprlandService", "Failed to query devices, exit code:", exitCode);
        accumulatedOutput = "";
        return;
      }
      try {
        const devicesData = JSON.parse(accumulatedOutput);
        for (const keyboard of devicesData.keyboards) {
          if (keyboard.main) {
            const layoutName = keyboard.active_keymap;
            KeyboardLayoutService.setCurrentLayout(layoutName);
            Logger.d("HyprlandService", "Keyboard layout switched:", layoutName);
          }
        }
      } catch (e) {
        Logger.e("HyprlandService", "Failed to parse devices:", e);
      } finally {
        accumulatedOutput = "";
      }
    }
  }

  function safeUpdate() {
    safeUpdateWindows();
    safeUpdateWorkspaces();
    workspaceChanged();
    windowListChanged();
  }

  function safeUpdateWorkspaces() {
    try {
      workspaces.clear();
      workspaceCache = {};
      if (!Hyprland.workspaces || !Hyprland.workspaces.values)
        return;
      const hlWorkspaces = Hyprland.workspaces.values;
      const occupiedIds = getOccupiedWorkspaceIds();
      for (var i = 0; i < hlWorkspaces.length; i++) {
        const ws = hlWorkspaces[i];
        if (ws.name && ws.name.startsWith("special:"))
          continue;
        const wsData = {
          "id": ws.id,
          "idx": ws.id,
          "name": ws.name || "",
          "output": (ws.monitor && ws.monitor.name) ? ws.monitor.name : "",
          "isActive": ws.active === true,
          "isFocused": ws.focused === true,
          "isUrgent": ws.urgent === true,
          "isOccupied": occupiedIds[ws.id] === true
        };
        workspaceCache[ws.id] = wsData;
        workspaces.append(wsData);
      }
    } catch (e) {
      Logger.e("HyprlandService", "Error updating workspaces:", e);
    }
  }

  function getOccupiedWorkspaceIds() {
    const occupiedIds = {};
    try {
      if (!Hyprland.toplevels || !Hyprland.toplevels.values)
        return occupiedIds;
      const hlToplevels = Hyprland.toplevels.values;
      for (var i = 0; i < hlToplevels.length; i++) {
        const toplevel = hlToplevels[i];
        if (!toplevel) continue;
        try {
          const wsId = toplevel.workspace ? toplevel.workspace.id : null;
          if (wsId !== null && wsId !== undefined)
            occupiedIds[wsId] = true;
        } catch (e) {}
      }
    } catch (e) {}
    return occupiedIds;
  }

  function safeUpdateWindows() {
    try {
      const windowsList = [];
      windowCache = {};
      if (!Hyprland.toplevels || !Hyprland.toplevels.values) {
        windows = [];
        focusedWindowIndex = -1;
        return;
      }
      const hlToplevels = Hyprland.toplevels.values;
      let focusedWindowId = null;
      const activeWorkspaceIds = {};
      if (Hyprland.workspaces && Hyprland.workspaces.values) {
        const hlWorkspaces = Hyprland.workspaces.values;
        for (var j = 0; j < hlWorkspaces.length; j++) {
          if (hlWorkspaces[j].active)
            activeWorkspaceIds[hlWorkspaces[j].id] = true;
        }
      }
      for (var i = 0; i < hlToplevels.length; i++) {
        const toplevel = hlToplevels[i];
        if (!toplevel) continue;
        const windowData = extractWindowData(toplevel);
        if (windowData) {
          if (windowData.isFocused && !activeWorkspaceIds[windowData.workspaceId])
            windowData.isFocused = false;
          const normalized = {
            "id": windowData.id ? String(windowData.id) : "",
            "title": windowData.title ? String(windowData.title) : "",
            "appId": windowData.appId ? String(windowData.appId) : "",
            "workspaceId": (typeof windowData.workspaceId === "number" && !isNaN(windowData.workspaceId)) ? windowData.workspaceId : -1,
            "isFocused": windowData.isFocused === true,
            "output": windowData.output ? String(windowData.output) : "",
            "x": (typeof windowData.x === "number" && !isNaN(windowData.x)) ? windowData.x : 0,
            "y": (typeof windowData.y === "number" && !isNaN(windowData.y)) ? windowData.y : 0
          };
          windowsList.push(normalized);
          windowCache[normalized.id] = normalized;
          if (normalized.isFocused)
            focusedWindowId = normalized.id;
        }
      }
      windows = toSortedWindowList(windowsList);
      let newFocusedIndex = -1;
      if (focusedWindowId) {
        for (let k = 0; k < windows.length; k++) {
          if (windows[k].id === focusedWindowId) {
            newFocusedIndex = k;
            break;
          }
        }
      }
      if (newFocusedIndex !== focusedWindowIndex) {
        focusedWindowIndex = newFocusedIndex;
        activeWindowChanged();
      }
    } catch (e) {
      Logger.e("HyprlandService", "Error updating windows:", e);
    }
  }

  function extractWindowData(toplevel) {
    if (!toplevel) return null;
    try {
      const windowId = safeGetProperty(toplevel, "address", "");
      if (!windowId) return null;
      const appId = getAppId(toplevel);
      const title = getAppTitle(toplevel);
      const wsId = toplevel.workspace ? toplevel.workspace.id : null;
      const focused = toplevel.activated === true;
      const output = toplevel.monitor?.name || "";
      let x = 0;
      let y = 0;
      try {
        const ipcData = toplevel.lastIpcObject;
        if (ipcData && ipcData.at) {
          x = ipcData.at[0];
          y = ipcData.at[1];
        } else if (typeof toplevel.x !== 'undefined') {
          x = toplevel.x;
          y = toplevel.y;
        }
      } catch (e) {}
      return {
        "id": windowId,
        "title": title,
        "appId": appId,
        "workspaceId": wsId || -1,
        "isFocused": focused,
        "output": output,
        "x": (typeof x === "number" && !isNaN(x)) ? x : 0,
        "y": (typeof y === "number" && !isNaN(y)) ? y : 0
      };
    } catch (e) {
      return null;
    }
  }

  function toSortedWindowList(windowList) {
    return windowList.sort((a, b) => {
      if (a.workspaceId !== b.workspaceId) return a.workspaceId - b.workspaceId;
      if (a.x !== b.x) return a.x - b.x;
      if (a.y !== b.y) return a.y - b.y;
      return a.id.localeCompare(b.id);
    });
  }

  function getAppTitle(toplevel) {
    try {
      var title = toplevel.wayland.title;
      if (title) return title;
    } catch (e) {}
    return safeGetProperty(toplevel, "title", "");
  }

  function getAppId(toplevel) {
    if (!toplevel) return "";
    var appId = "";
    try {
      appId = toplevel.wayland.appId;
      if (appId) return appId;
    } catch (e) {}
    appId = safeGetProperty(toplevel, "class", "");
    if (appId) return appId;
    appId = safeGetProperty(toplevel, "initialClass", "");
    if (appId) return appId;
    appId = safeGetProperty(toplevel, "appId", "");
    if (appId) return appId;
    try {
      const ipcData = toplevel.lastIpcObject;
      if (ipcData)
        return String(ipcData.class || ipcData.initialClass || ipcData.appId || ipcData.wm_class || "");
    } catch (e) {}
    return "";
  }

  function safeGetProperty(obj, prop, defaultValue) {
    try {
      const value = obj[prop];
      if (value !== undefined && value !== null)
        return String(value);
    } catch (e) {}
    return defaultValue;
  }

  function handleActiveLayoutEvent(ev) {
    try {
      let beforeParenthesis;
      const parenthesisPos = ev.lastIndexOf('(');
      if (parenthesisPos === -1) {
        beforeParenthesis = ev;
      } else {
        beforeParenthesis = ev.substring(0, parenthesisPos);
      }
      const layoutNameStart = beforeParenthesis.lastIndexOf(',') + 1;
      const layoutName = ev.substring(layoutNameStart);
      if (layoutName.toLowerCase() === "error") {
        Logger.d("HyprlandService", "Ignoring bogus 'error' layout from activelayout event");
        return;
      }
      KeyboardLayoutService.setCurrentLayout(layoutName);
      Logger.d("HyprlandService", "Keyboard layout switched:", layoutName);
    } catch (e) {
      Logger.e("HyprlandService", "Error handling activelayout:", e);
    }
  }

  Connections {
    target: Hyprland.workspaces
    enabled: initialized
    function onValuesChanged() {
      Qt.callLater(_deferredWorkspaceUpdate);
    }
  }

  Connections {
    target: Hyprland.toplevels
    enabled: initialized
    function onValuesChanged() {
      updateTimer.restart();
    }
  }

  Connections {
    target: Hyprland
    enabled: initialized
    function onRawEvent(event) {
      Hyprland.refreshWorkspaces();
      Hyprland.refreshToplevels();
      Qt.callLater(_deferredWorkspaceUpdate);
      updateTimer.restart();
      const monitorsEvents = ["configreloaded", "monitoradded", "monitorremoved", "monitoraddedv2", "monitorremovedv2"];
      if (monitorsEvents.includes(event.name))
        Qt.callLater(queryDisplayScales);
      if (event.name == "activelayout")
        handleActiveLayoutEvent(event.data);
    }
  }

  // ── All functions below patched for Hyprland 0.55 Lua dispatch syntax ──

  function switchToWorkspace(workspace) {
    try {
      const target = workspace.name ? workspace.name : String(workspace.idx);
      Quickshell.execDetached(["sh", "-c", "hyprctl dispatch 'hl.dsp.focus({workspace=\"" + target + "\"})'"]); 
    } catch (e) {
      Logger.e("HyprlandService", "Failed to switch workspace:", e);
    }
  }

  function focusWindow(window) {
    try {
      if (!window || !window.id) {
        Logger.w("HyprlandService", "Invalid window object for focus");
        return;
      }
      const windowId = window.id.toString();
      Quickshell.execDetached(["sh", "-c", "hyprctl dispatch 'hl.dsp.focus({address=\"0x" + windowId + "\"})'"]); 
    } catch (e) {
      Logger.e("HyprlandService", "Failed to focus window:", e);
    }
  }

  function closeWindow(window) {
    try {
      const windowId = window.id.toString();
      Quickshell.execDetached(["sh", "-c", "hyprctl dispatch 'hl.dsp.window.close({address=\"0x" + windowId + "\"})'"]); 
    } catch (e) {
      Logger.e("HyprlandService", "Failed to close window:", e);
    }
  }

  function turnOffMonitors() {
    try {
      Quickshell.execDetached(["sh", "-c", "hyprctl dispatch 'hl.dsp.dpms(\"off\")'"]);
    } catch (e) {
      Logger.e("HyprlandService", "Failed to turn off monitors:", e);
    }
  }

  function turnOnMonitors() {
    try {
      Quickshell.execDetached(["sh", "-c", "hyprctl dispatch 'hl.dsp.dpms(\"on\")'"]);
    } catch (e) {
      Logger.e("HyprlandService", "Failed to turn on monitors:", e);
    }
  }

  function logout() {
    try {
      Quickshell.execDetached(["sh", "-c", "hyprctl dispatch 'hl.dsp.exit()'"]);
    } catch (e) {
      Logger.e("HyprlandService", "Failed to logout:", e);
    }
  }

  function cycleKeyboardLayout() {
    try {
      Quickshell.execDetached(["hyprctl", "switchxkblayout", "all", "next"]);
    } catch (e) {
      Logger.e("HyprlandService", "Failed to cycle keyboard layout:", e);
    }
  }

  function getFocusedScreen() {
    const hyprMon = Hyprland.focusedMonitor;
    if (hyprMon) {
      const monitorName = hyprMon.name;
      for (let i = 0; i < Quickshell.screens.length; i++) {
        if (Quickshell.screens[i].name === monitorName)
          return Quickshell.screens[i];
      }
    }
    return null;
  }

  function spawn(command) {
    try {
      const cmd = command.join(" ");
      Quickshell.execDetached(["sh", "-c", "hyprctl dispatch 'hl.dsp.exec_cmd(\"" + cmd + "\")'"]); 
    } catch (e) {
      Logger.e("HyprlandService", "Failed to spawn command:", e);
    }
  }
}
