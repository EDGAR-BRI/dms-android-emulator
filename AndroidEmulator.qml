import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Modules.Plugins

PluginComponent {
    id: root

    pluginId: "androidEmulator"

    readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
    readonly property string helperPath: pluginDir + "/avd_helper.py"

    property var avds: []
    property var adbDevices: []
    property var sdkPaths: ({})
    property int runningCount: 0
    property int deviceCount: 0
    property bool isBusy: false
    property string busyLabel: ""
    property string statusError: ""
    property bool initialLoaded: false

    readonly property string customSdkPath: pluginData.customSdkPath ? String(pluginData.customSdkPath).trim() : ""
    readonly property string configuredDefaultAvd: pluginData.defaultAvd ? String(pluginData.defaultAvd) : ""
    readonly property string defaultAvd: {
        if (configuredDefaultAvd && avds.some(a => a.id === configuredDefaultAvd))
            return configuredDefaultAvd;
        return avds.length > 0 ? avds[0].id : "";
    }

    readonly property var runningAvds: avds.filter(a => a.running)
    readonly property var runningPids: runningAvds.map(a => Number(a.pid) || 0).filter(p => p > 0)
    readonly property string watchedPidsKey: runningPids.join(",")
    readonly property bool anyBooting: runningAvds.some(a => !a.boot_completed)
    property int bootPollTicks: 0

    readonly property var activeDevice: {
        const readyEmu = adbDevices.find(d => d.state === "device" && d.is_emulator);
        if (readyEmu)
            return readyEmu;
        const anyReady = adbDevices.find(d => d.state === "device");
        return anyReady || null;
    }

    function buildHelperCmd(extraArgs) {
        const cmd = ["python3", root.helperPath];
        if (root.customSdkPath !== "") {
            cmd.push("--sdk", root.customSdkPath);
        }
        for (let i = 0; i < extraArgs.length; i++) {
            cmd.push(String(extraArgs[i]));
        }
        return cmd;
    }

    function refreshStatus() {
        if (statusProc.running)
            return;
        statusProc.command = buildHelperCmd(["status"]);
        statusProc.running = true;
    }

    function runHelperAction(args, label, toastOnSuccess, silent) {
        if (actionProc.running) {
            ToastService.showInfo("Hay una operación en curso, espera un momento...");
            return;
        }
        root.isBusy = true;
        root.busyLabel = label || "Procesando...";
        actionProc.pendingSuccessToast = toastOnSuccess || "";
        actionProc.silentMode = Boolean(silent);
        actionProc.command = buildHelperCmd(args);
        actionProc.running = true;
    }

    function launchAvd(avdId, mode) {
        if (!avdId)
            return;
        const m = mode || "normal";
        const modeText = m === "cold" ? " (Cold Boot)" : (m === "wipe" ? " (Wipe Data)" : (m === "no-window" ? " (Headless)" : ""));
        const avd = avds.find(a => a.id === avdId);
        const label = avd ? avd.display_name : avdId;
        root.bootPollTicks = 0;
        runHelperAction(["launch", avdId, m], "Iniciando " + label + "...", "Iniciando emulador " + label + modeText);
    }

    function stopAvd(target) {
        if (!target)
            return;
        const avd = avds.find(a => a.id === target || a.serial === target);
        const label = avd ? avd.display_name : target;
        runHelperAction(["stop", target], "Deteniendo " + label + "...", "Deteniendo emulador " + label);
    }

    function toggleAvd(avdId, mode) {
        const avd = avds.find(a => a.id === avdId);
        if (avd && avd.running) {
            stopAvd(avd.serial || avd.id);
        } else {
            launchAvd(avdId, mode || "normal");
        }
    }

    function toggleDefaultAvd() {
        if (runningAvds.length > 0 && (!configuredDefaultAvd || runningAvds.some(a => a.id === defaultAvd))) {
            const target = runningAvds.find(a => a.id === defaultAvd) || runningAvds[0];
            stopAvd(target.serial || target.id);
            return;
        }
        if (defaultAvd !== "") {
            launchAvd(defaultAvd, "normal");
        } else {
            ToastService.showError("No se encontraron emuladores AVD configurados");
        }
    }

    function stopAll() {
        if (runningAvds.length === 0) {
            ToastService.showInfo("No hay emuladores en ejecución");
            return;
        }
        for (let i = 0; i < runningAvds.length; i++) {
            const target = runningAvds[i].serial || runningAvds[i].id;
            Quickshell.execDetached(buildHelperCmd(["stop", target]));
        }
        ToastService.showInfo("Deteniendo " + runningAvds.length + " emulador(es)...");
        delayedRefreshTimer.restart();
    }

    function cleanLocks(avdId) {
        if (!avdId)
            return;
        runHelperAction(["clean-locks", avdId], "Limpiando bloqueos...", "Archivos .lock limpiados para " + avdId);
    }

    function saveAvdConfig(avdId, patchObj) {
        if (!avdId || !patchObj)
            return;
        runHelperAction(
            ["update-config", avdId, JSON.stringify(patchObj)],
            "Guardando configuración...",
            "Configuración guardada en " + avdId
        );
    }

    function runAdbAction(serial, action, arg) {
        const args = ["adb-action", serial || "", action];
        if (arg !== undefined && arg !== null && String(arg) !== "")
            args.push(String(arg));
        runHelperAction(args, "Ejecutando ADB: " + action, "");
    }

    function setDefaultAvd(avdId) {
        if (pluginService && pluginService.savePluginData) {
            pluginService.savePluginData(pluginId, "defaultAvd", avdId);
        }
    }

    function setCustomSdkPath(pathStr) {
        if (pluginService && pluginService.savePluginData) {
            pluginService.savePluginData(pluginId, "customSdkPath", pathStr);
            Qt.callLater(refreshStatus);
        }
    }

    function openPluginSettings() {
        if (PopoutService && PopoutService.closeControlCenter) {
            PopoutService.closeControlCenter();
        }
        if (PluginService) {
            PluginService.pendingSettingsRevealPluginId = pluginId;
        }
        if (PopoutService && PopoutService.openSettingsWithTab) {
            PopoutService.openSettingsWithTab("plugins");
        }
    }

    Component.onCompleted: {
        Qt.callLater(refreshStatus);
    }

    onPluginDataChanged: {
        Qt.callLater(refreshStatus);
    }

    onWatchedPidsKeyChanged: {
        syncPidWatcher();
    }

    function syncPidWatcher() {
        if (pidWatchProc.running) {
            pidWatchProc.running = false;
        }
        if (root.runningPids.length === 0)
            return;
        const args = ["wait-exit"].concat(root.runningPids.map(p => String(p)));
        pidWatchProc.command = buildHelperCmd(args);
        pidWatchProc.running = true;
    }

    // Only runs briefly while a newly launched emulator is still booting (stops completely once boot_completed is true)
    Timer {
        id: bootTimer
        interval: 2500
        repeat: true
        running: root.anyBooting && root.bootPollTicks < 40
        onTriggered: {
            root.bootPollTicks += 1;
            root.refreshStatus();
        }
    }

    // Kernel pidfd watcher: 0% CPU, no timer loop. Wakes up only at the exact moment an emulator PID exits.
    Process {
        id: pidWatchProc
        running: false
        onExited: {
            if (root.runningPids.length > 0) {
                Qt.callLater(root.refreshStatus);
            }
        }
    }

    Timer {
        id: delayedRefreshTimer
        interval: 1200
        repeat: false
        onTriggered: root.refreshStatus()
    }

    Process {
        id: statusProc
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const raw = (text || "").trim();
                if (!raw)
                    return;
                try {
                    const parsed = JSON.parse(raw);
                    if (parsed && parsed.ok) {
                        root.avds = parsed.avds || [];
                        root.adbDevices = parsed.adb_devices || [];
                        root.sdkPaths = parsed.paths || {};
                        root.runningCount = Number(parsed.running_count) || 0;
                        root.deviceCount = Number(parsed.device_count) || 0;
                        root.statusError = "";
                        root.initialLoaded = true;
                    } else if (parsed && parsed.error) {
                        root.statusError = String(parsed.error);
                    }
                } catch (e) {
                    root.statusError = "Error leyendo estado de AVDs";
                }
            }
        }
    }

    Process {
        id: actionProc
        property string pendingSuccessToast: ""
        property bool silentMode: false
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                root.isBusy = false;
                root.busyLabel = "";
                const raw = (text || "").trim();
                if (raw) {
                    try {
                        const res = JSON.parse(raw);
                        if (res.ok) {
                            if (!actionProc.silentMode) {
                                const msg = actionProc.pendingSuccessToast || res.message || "";
                                if (msg)
                                    ToastService.showInfo(msg);
                            }
                        } else if (!res.cancelled && (res.error || res.message)) {
                            ToastService.showError(String(res.error || res.message));
                        }
                    } catch (e) {
                        if (!actionProc.silentMode && actionProc.pendingSuccessToast)
                            ToastService.showInfo(actionProc.pendingSuccessToast);
                    }
                }
                actionProc.pendingSuccessToast = "";
                actionProc.silentMode = false;
                delayedRefreshTimer.restart();
            }
        }
        onExited: exitCode => {
            if (root.isBusy) {
                root.isBusy = false;
                root.busyLabel = "";
            }
            if (exitCode !== 0 && !actionProc.silentMode) {
                delayedRefreshTimer.restart();
            }
        }
    }

    IpcHandler {
        target: "androidEmulator"

        function toggleDefault(): string {
            root.toggleDefaultAvd();
            return "toggled";
        }

        function launch(avdId: string): string {
            if (!avdId)
                return "error:missing_avd";
            root.launchAvd(avdId, "normal");
            return "launching:" + avdId;
        }

        function stop(target: string): string {
            if (!target)
                return "error:missing_target";
            root.stopAvd(target);
            return "stopping:" + target;
        }

        function stopAll(): string {
            root.stopAll();
            return "stopping_all";
        }

        function refresh(): string {
            root.refreshStatus();
            return "refreshing";
        }

        function openSettings(): string {
            root.openPluginSettings();
            return "opening_settings";
        }

        function status(): string {
            return JSON.stringify({
                runningCount: root.runningCount,
                deviceCount: root.deviceCount,
                defaultAvd: root.defaultAvd,
                avds: root.avds.map(a => ({
                    id: a.id,
                    display_name: a.display_name,
                    running: a.running,
                    serial: a.serial,
                    hidden_window: a.hidden_window
                }))
            });
        }
    }
}
