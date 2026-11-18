import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: root
    pluginId: "androidEmulator"

    readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
    readonly property var daemonInstance: pluginService && pluginService.pluginDaemonInstances ? pluginService.pluginDaemonInstances[pluginId] : null

    readonly property var avds: daemonInstance ? daemonInstance.avds : []
    readonly property var adbDevices: daemonInstance ? daemonInstance.adbDevices : []
    readonly property var sdkPaths: daemonInstance ? daemonInstance.sdkPaths : ({})
    readonly property string defaultAvd: daemonInstance ? daemonInstance.defaultAvd : ""

    // GitHub update state
    property string updateStatus: "idle"
    property string updateMsg: ""
    property string commitHash: ""
    property int newCommitsCount: 0

    // AVD Config Editor state
    property string editingAvdId: ""
    property int editRamMb: 2048
    property int editCpuCores: 2
    property string editGpuMode: "auto"
    property bool editDeviceFrame: true
    property bool editKeyboard: true
    property bool editColdBoot: false

    // ADB Tools state
    property string selectedAdbSerial: ""
    readonly property var readyDevices: adbDevices.filter(d => d.state === "device")
    readonly property var activeAdbDevice: {
        if (readyDevices.length === 0)
            return null;
        return readyDevices.find(d => d.serial === selectedAdbSerial) || readyDevices[0];
    }

    function loadAvdIntoEditor(avd) {
        if (!avd)
            return;
        editingAvdId = avd.id;
        editRamMb = avd.ram_mb || 2048;
        editCpuCores = avd.cpu_cores || 2;
        editGpuMode = avd.gpu_mode || "auto";
        editDeviceFrame = Boolean(avd.device_frame);
        editKeyboard = Boolean(avd.keyboard);
        editColdBoot = Boolean(avd.cold_boot);
    }

    onAvdsChanged: {
        if (avds.length > 0 && editingAvdId === "") {
            const initial = avds.find(a => a.id === defaultAvd) || avds[0];
            loadAvdIntoEditor(initial);
        } else if (editingAvdId !== "") {
            const current = avds.find(a => a.id === editingAvdId);
            if (!current && avds.length > 0)
                loadAvdIntoEditor(avds[0]);
        }
    }

    Process {
        id: checkProc
        command: [root.pluginDir + "/update_helper.sh", "check"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const out = (text || "").trim();
                const parts = out.split("|");
                if (parts[0] === "UPDATE_AVAILABLE") {
                    root.updateStatus = "available";
                    root.newCommitsCount = parseInt(parts[1]) || 1;
                    root.updateMsg = "Hay " + (parts[1] || "1") + " mejora disponible en GitHub: " + (parts[2] || "");
                } else if (parts[0] === "UP_TO_DATE") {
                    root.updateStatus = "up_to_date";
                    root.commitHash = parts[1] || "";
                    root.updateMsg = "El plugin está actualizado a la última versión (" + (parts[1] || "") + ").";
                } else if (parts[0] === "ERROR") {
                    root.updateStatus = "error";
                    root.updateMsg = parts[1] || "No se pudo conectar con GitHub.";
                }
            }
        }
        onExited: exitCode => {
            if (exitCode !== 0 && root.updateStatus === "checking") {
                root.updateStatus = "error";
                root.updateMsg = "Error al conectar con GitHub";
            }
        }
    }

    Process {
        id: applyProc
        command: [root.pluginDir + "/update_helper.sh", "update"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const out = (text || "").trim();
                if (out.indexOf("SUCCESS") !== -1) {
                    root.updateStatus = "done";
                    root.updateMsg = "¡Plugin actualizado con éxito! Reiniciando DMS...";
                } else if (out.indexOf("ERROR") !== -1) {
                    root.updateStatus = "error";
                    root.updateMsg = out;
                }
            }
        }
    }

    Process {
        id: pickApkProc
        property bool installAfterPick: false
        command: ["python3", root.pluginDir + "/avd_helper.py", "pick-apk"]
        running: false
        stdout: StdioCollector {
            onStreamFinished: {
                const raw = (text || "").trim();
                const shouldInstall = pickApkProc.installAfterPick;
                pickApkProc.installAfterPick = false;
                if (!raw)
                    return;
                try {
                    const res = JSON.parse(raw);
                    if (res.ok && res.path) {
                        apkPathInput.text = String(res.path);
                        if (shouldInstall && root.daemonInstance && root.activeAdbDevice) {
                            ToastService.showInfo("Instalando " + String(res.path).split("/").pop() + "...");
                            root.daemonInstance.runAdbAction(root.activeAdbDevice.serial, "install-apk", String(res.path));
                        }
                    }
                } catch (e) {}
            }
        }
    }

    function browseForApk(autoInstall) {
        if (pickApkProc.running)
            return;
        pickApkProc.installAfterPick = Boolean(autoInstall);
        pickApkProc.running = true;
    }

    function checkForUpdates() {
        if (root.updateStatus === "checking" || root.updateStatus === "updating")
            return;
        root.updateStatus = "checking";
        root.updateMsg = "Buscando actualizaciones en GitHub...";
        checkProc.running = true;
    }

    function applyUpdate() {
        if (root.updateStatus === "updating")
            return;
        root.updateStatus = "updating";
        root.updateMsg = "Descargando e instalando actualización...";
        applyProc.running = true;
    }

    Timer {
        id: autoCheckTimer
        interval: 800
        repeat: false
        onTriggered: root.checkForUpdates()
    }

    function reloadNested(parentItem) {
        if (!parentItem || !parentItem.children)
            return;
        for (let i = 0; i < parentItem.children.length; i++) {
            const ch = parentItem.children[i];
            if (!ch)
                continue;
            if (typeof ch.loadValue === "function" && ch.settingKey !== undefined) {
                ch.loadValue();
                if (root.pluginService && ch.isInitialized !== undefined && !ch.isInitialized) {
                    ch.value = root.loadValue(ch.settingKey, ch.defaultValue);
                    ch.isInitialized = true;
                }
            } else {
                reloadNested(ch);
            }
        }
    }

    onPluginServiceChanged: {
        if (pluginService) {
            Qt.callLater(() => root.reloadNested(root));
        }
    }

    Component.onCompleted: {
        Qt.callLater(() => root.reloadNested(root));
        if (daemonInstance)
            daemonInstance.refreshStatus();
        if (avds.length > 0) {
            const initial = avds.find(a => a.id === defaultAvd) || avds[0];
            loadAvdIntoEditor(initial);
        }
        autoCheckTimer.start();
    }

    component SettingsCard: StyledRect {
        id: cardRect
        width: parent.width
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        function loadValue() {
            root.reloadNested(cardRect);
        }
    }

    component ActionChip: StyledRect {
        id: chipRect
        property string labelText: ""
        property string iconName: ""
        property bool activeChip: false
        property bool dangerChip: false
        property bool enabledChip: true
        signal clicked()

        height: 32
        width: chipInner.implicitWidth + 22
        radius: 16
        opacity: enabledChip ? 1.0 : 0.45
        color: {
            if (dangerChip)
                return chipMa.pressed ? Qt.darker(Theme.error, 1.2) : Qt.rgba(0.95, 0.28, 0.34, chipMa.containsMouse ? 0.25 : 0.15);
            if (activeChip)
                return chipMa.pressed ? Qt.darker(Theme.primary, 1.2) : Theme.primary;
            return chipMa.pressed ? Qt.rgba(1, 1, 1, 0.16) : (chipMa.containsMouse ? Qt.rgba(1, 1, 1, 0.11) : Qt.rgba(1, 1, 1, 0.06));
        }
        border.width: 1
        border.color: dangerChip ? Theme.error : (activeChip ? Theme.primary : Qt.rgba(1, 1, 1, 0.16))

        Row {
            id: chipInner
            anchors.centerIn: parent
            spacing: 6

            DankIcon {
                visible: chipRect.iconName !== ""
                name: chipRect.iconName
                size: 16
                color: chipRect.dangerChip ? Theme.error : (chipRect.activeChip ? Theme.buttonText : Theme.surfaceText)
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: chipRect.labelText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: chipRect.activeChip ? Font.Bold : Font.Medium
                color: chipRect.dangerChip ? Theme.error : (chipRect.activeChip ? Theme.buttonText : Theme.surfaceText)
                anchors.verticalCenter: parent.verticalCenter
            }
        }

        MouseArea {
            id: chipMa
            anchors.fill: parent
            hoverEnabled: true
            enabled: chipRect.enabledChip
            cursorShape: chipRect.enabledChip ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: chipRect.clicked()
        }
    }

    component BindCode: StyledRect {
        id: codeBox
        property string titleText: ""
        property string code: ""

        width: parent.width
        height: codeCol.implicitHeight + Theme.spacingM * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainer
        border.width: 1
        border.color: Theme.withAlpha(Theme.outline, 0.25)

        Column {
            id: codeCol
            anchors.left: parent.left
            anchors.right: copyBtn.left
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Theme.spacingM
            anchors.rightMargin: Theme.spacingS
            spacing: 4

            StyledText {
                visible: codeBox.titleText !== ""
                text: codeBox.titleText
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Bold
                color: Theme.primary
            }

            TextEdit {
                width: parent.width
                text: codeBox.code
                readOnly: true
                selectByMouse: true
                wrapMode: TextEdit.Wrap
                font.family: Theme.monoFontFamily
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceText
                selectionColor: Theme.primary
                selectedTextColor: Theme.surface
            }
        }

        DankActionButton {
            id: copyBtn
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: Theme.spacingXS
            iconName: "content_copy"
            iconSize: Theme.iconSize - 6
            buttonSize: 28
            tooltipText: "Copiar al portapapeles"
            onClicked: {
                Quickshell.execDetached(["sh", "-c", "printf %s \"$1\" | dms cl copy", "_", codeBox.code]);
                ToastService.showInfo("Atajos copiados al portapapeles");
            }
        }
    }

    StyledText {
        width: parent.width
        text: "Android Emulator & ADB Manager"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Inicia, detén y configura tus emuladores de Android Studio (AVDs) y controla dispositivos por ADB sin abrir Android Studio."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    // 0. ACTUALIZACIONES DEL PLUGIN (GITHUB)
    SettingsCard {
        height: updateCol.implicitHeight + Theme.spacingL * 2
        border.color: root.updateStatus === "available" ? "#4dabf7" : Theme.outline
        border.width: root.updateStatus === "available" ? 1.5 : 1

        Column {
            id: updateCol
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            Row {
                width: parent.width
                spacing: Theme.spacingM

                Column {
                    width: parent.width - updateActionsRow.width - Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4

                    Row {
                        spacing: 8
                        DankIcon {
                            name: root.updateStatus === "available" ? "system_update" : (root.updateStatus === "checking" || root.updateStatus === "updating" ? "sync" : (root.updateStatus === "error" ? "error" : "check_circle"))
                            size: 20
                            color: root.updateStatus === "available" ? "#4dabf7" : (root.updateStatus === "error" ? Theme.error : "#2ed573")
                            anchors.verticalCenter: parent.verticalCenter
                        }

                        StyledText {
                            text: "Versión Instalada: v1.0.0"
                            font.pixelSize: Theme.fontSizeMedium
                            font.weight: Font.Bold
                            color: Theme.surfaceText
                            anchors.verticalCenter: parent.verticalCenter
                        }
                    }

                    StyledText {
                        width: parent.width
                        text: root.updateMsg !== "" ? root.updateMsg : "Comprueba y descarga actualizaciones directamente desde GitHub sin usar la terminal."
                        font.pixelSize: Theme.fontSizeSmall
                        color: root.updateStatus === "available" ? "#4dabf7" : Theme.surfaceVariantText
                        wrapMode: Text.WordWrap
                    }
                }

                Row {
                    id: updateActionsRow
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingS

                    ActionChip {
                        iconName: "refresh"
                        labelText: root.updateStatus === "checking" ? "Comprobando..." : "Comprobar"
                        enabledChip: root.updateStatus !== "checking" && root.updateStatus !== "updating"
                        onClicked: root.checkForUpdates()
                    }

                    ActionChip {
                        iconName: "download"
                        labelText: root.updateStatus === "updating" ? "Actualizando..." : "Actualizar"
                        activeChip: root.updateStatus === "available"
                        enabledChip: root.updateStatus === "available" && root.updateStatus !== "updating"
                        onClicked: root.applyUpdate()
                    }
                }
            }
        }
    }

    // 1. EMULADORES DISPONIBLES (CONTROL EN VIVO)
    SettingsCard {
        height: avdsCol.implicitHeight + Theme.spacingL * 2

        Column {
            id: avdsCol
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            Row {
                width: parent.width
                spacing: Theme.spacingS

                StyledText {
                    width: parent.width - avdsHeaderActions.width - Theme.spacingS
                    text: "Emuladores Android (AVD)"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }

                Row {
                    id: avdsHeaderActions
                    spacing: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter

                    ActionChip {
                        iconName: "sync"
                        labelText: "Refrescar"
                        onClicked: {
                            if (root.daemonInstance)
                                root.daemonInstance.refreshStatus();
                        }
                    }

                    ActionChip {
                        visible: root.daemonInstance && root.daemonInstance.runningCount > 0
                        iconName: "stop"
                        labelText: "Detener todos"
                        dangerChip: true
                        onClicked: {
                            if (root.daemonInstance)
                                root.daemonInstance.stopAll();
                        }
                    }
                }
            }

            StyledText {
                visible: root.avds.length === 0
                width: parent.width
                text: "No se encontraron AVDs en ~/.android/avd. Verifica que creaste al menos un dispositivo virtual o revisa la ruta del Android SDK."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            Repeater {
                model: root.avds

                StyledRect {
                    id: avdCard
                    required property var modelData
                    readonly property bool isDefault: modelData.id === root.defaultAvd
                    readonly property bool isRunning: Boolean(modelData.running)
                    readonly property bool isHidden: Boolean(modelData.hidden_window)

                    width: parent.width
                    height: avdCardCol.implicitHeight + Theme.spacingM * 2
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainer
                    border.width: isRunning ? 1.5 : 1
                    border.color: isRunning ? Theme.primary : Theme.withAlpha(Theme.outline, 0.25)

                    Column {
                        id: avdCardCol
                        anchors.fill: parent
                        anchors.margins: Theme.spacingM
                        spacing: Theme.spacingS

                        Row {
                            width: parent.width
                            spacing: Theme.spacingS

                            Rectangle {
                                width: 10
                                height: 10
                                radius: 5
                                anchors.verticalCenter: parent.verticalCenter
                                color: avdCard.isRunning ? (avdCard.modelData.boot_completed ? "#2ed573" : "#ffa502") : Theme.surfaceVariantText
                            }

                            Column {
                                width: parent.width - avdStatusBadge.width - 10 - Theme.spacingS * 2
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 2

                                StyledText {
                                    text: avdCard.modelData.display_name + " (" + avdCard.modelData.id + ")" + (avdCard.isDefault ? "  ★ Favorito" : "")
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.Bold
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    text: {
                                        const specs = [
                                            avdCard.modelData.target_label || "Android",
                                            avdCard.modelData.abi || "x86_64",
                                            (avdCard.modelData.ram_mb || 2048) + " MB RAM",
                                            (avdCard.modelData.cpu_cores || 2) + " CPU",
                                            "GPU: " + (avdCard.modelData.gpu_mode || "auto")
                                        ];
                                        if (avdCard.isRunning && avdCard.modelData.serial)
                                            specs.unshift(avdCard.modelData.serial);
                                        return specs.join(" • ");
                                    }
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                            }

                            StyledRect {
                                id: avdStatusBadge
                                anchors.verticalCenter: parent.verticalCenter
                                height: 24
                                width: badgeTxt.implicitWidth + 16
                                radius: 12
                                color: avdCard.isRunning ? Qt.rgba(0.18, 0.84, 0.45, 0.16) : Qt.rgba(1, 1, 1, 0.06)

                                StyledText {
                                    id: badgeTxt
                                    anchors.centerIn: parent
                                    text: avdCard.isRunning ? (avdCard.isHidden ? "Activo (Oculto)" : "En ejecución") : "Detenido"
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    font.weight: Font.Medium
                                    color: avdCard.isRunning ? "#2ed573" : Theme.surfaceVariantText
                                }
                            }
                        }

                        StyledText {
                            visible: avdCard.isRunning && avdCard.isHidden
                            width: parent.width
                            text: "Nota: Este emulador está corriendo sin ventana propia (-qt-hide-window de Android Studio). Usa 'Mostrar Pantalla (scrcpy)' para verlo o 'Reiniciar con Ventana'."
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: "#ffa502"
                            wrapMode: Text.WordWrap
                        }

                        Flow {
                            width: parent.width
                            spacing: Theme.spacingS

                            ActionChip {
                                visible: !avdCard.isRunning
                                iconName: "play_arrow"
                                labelText: "Iniciar"
                                activeChip: true
                                onClicked: {
                                    if (root.daemonInstance)
                                        root.daemonInstance.launchAvd(avdCard.modelData.id, "normal");
                                }
                            }

                            ActionChip {
                                visible: !avdCard.isRunning
                                iconName: "ac_unit"
                                labelText: "Cold Boot"
                                onClicked: {
                                    if (root.daemonInstance)
                                        root.daemonInstance.launchAvd(avdCard.modelData.id, "cold");
                                }
                            }

                            ActionChip {
                                visible: !avdCard.isRunning
                                iconName: "visibility_off"
                                labelText: "Headless"
                                onClicked: {
                                    if (root.daemonInstance)
                                        root.daemonInstance.launchAvd(avdCard.modelData.id, "no-window");
                                }
                            }

                            ActionChip {
                                visible: avdCard.isRunning && avdCard.modelData.serial !== ""
                                iconName: "cast"
                                labelText: "Mostrar Pantalla (scrcpy)"
                                activeChip: true
                                onClicked: {
                                    if (root.daemonInstance)
                                        root.daemonInstance.runAdbAction(avdCard.modelData.serial, "scrcpy", "");
                                }
                            }

                            ActionChip {
                                visible: avdCard.isRunning
                                iconName: "stop"
                                labelText: "Detener"
                                dangerChip: true
                                onClicked: {
                                    if (root.daemonInstance)
                                        root.daemonInstance.stopAvd(avdCard.modelData.serial || avdCard.modelData.id);
                                }
                            }

                            ActionChip {
                                iconName: "tune"
                                labelText: "Editar Hardware"
                                onClicked: root.loadAvdIntoEditor(avdCard.modelData)
                            }

                            ActionChip {
                                visible: !avdCard.isDefault
                                iconName: "star"
                                labelText: "Hacer Favorito"
                                onClicked: {
                                    if (root.daemonInstance) {
                                        root.daemonInstance.setDefaultAvd(avdCard.modelData.id);
                                        ToastService.showInfo("Favorito establecido: " + avdCard.modelData.display_name);
                                    }
                                }
                            }

                            ActionChip {
                                visible: avdCard.modelData.stale_locks
                                iconName: "lock_open"
                                labelText: "Limpiar Locks"
                                onClicked: {
                                    if (root.daemonInstance)
                                        root.daemonInstance.cleanLocks(avdCard.modelData.id);
                                }
                            }

                            ActionChip {
                                visible: !avdCard.isRunning
                                iconName: "delete_sweep"
                                labelText: "Wipe Data"
                                dangerChip: true
                                onClicked: {
                                    if (root.daemonInstance)
                                        root.daemonInstance.launchAvd(avdCard.modelData.id, "wipe");
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // 2. EDITOR GRÁFICO DE HARDWARE DEL AVD (config.ini)
    SettingsCard {
        visible: root.avds.length > 0
        height: editorCol.implicitHeight + Theme.spacingL * 2

        Column {
            id: editorCol
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Editor de Hardware y Arranque del Emulador (config.ini)"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                text: "Los cambios se aplicarán la próxima vez que inicies el emulador (sin necesidad de abrir Android Studio)."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            // Selector de AVD
            Flow {
                width: parent.width
                spacing: Theme.spacingS

                Repeater {
                    model: root.avds
                    ActionChip {
                        required property var modelData
                        iconName: "smartphone"
                        labelText: modelData.display_name
                        activeChip: root.editingAvdId === modelData.id
                        onClicked: root.loadAvdIntoEditor(modelData)
                    }
                }
            }

            // Memoria RAM
            Column {
                width: parent.width
                spacing: Theme.spacingXS

                StyledText {
                    text: "Memoria RAM asignada (hw.ramSize): " + root.editRamMb + " MB"
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                }

                Flow {
                    width: parent.width
                    spacing: Theme.spacingS

                    Repeater {
                        model: [
                            { "mb": 2048, "label": "2 GB (2048 MB)" },
                            { "mb": 4096, "label": "4 GB (4096 MB)" },
                            { "mb": 6144, "label": "6 GB (6144 MB)" },
                            { "mb": 8192, "label": "8 GB (8192 MB)" }
                        ]
                        ActionChip {
                            required property var modelData
                            labelText: modelData.label
                            activeChip: root.editRamMb === modelData.mb
                            onClicked: root.editRamMb = modelData.mb
                        }
                    }
                }
            }

            // Núcleos CPU
            Column {
                width: parent.width
                spacing: Theme.spacingXS

                StyledText {
                    text: "Núcleos de CPU (hw.cpu.ncore): " + root.editCpuCores
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                }

                Flow {
                    width: parent.width
                    spacing: Theme.spacingS

                    Repeater {
                        model: [2, 4, 6, 8]
                        ActionChip {
                            required property int modelData
                            labelText: modelData + " núcleos"
                            activeChip: root.editCpuCores === modelData
                            onClicked: root.editCpuCores = modelData
                        }
                    }
                }
            }

            // Modo GPU
            Column {
                width: parent.width
                spacing: Theme.spacingXS

                StyledText {
                    text: "Aceleración Gráfica GPU (hw.gpu.mode)"
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.surfaceText
                }

                Flow {
                    width: parent.width
                    spacing: Theme.spacingS

                    Repeater {
                        model: [
                            { "id": "auto", "label": "Auto" },
                            { "id": "host", "label": "Host (GPU nativa)" },
                            { "id": "swiftshader_indirect", "label": "Software (SwiftShader)" },
                            { "id": "angle_indirect", "label": "ANGLE" }
                        ]
                        ActionChip {
                            required property var modelData
                            labelText: modelData.label
                            activeChip: root.editGpuMode === modelData.id
                            onClicked: root.editGpuMode = modelData.id
                        }
                    }
                }
            }

            // Opciones booleanas
            Row {
                width: parent.width
                spacing: Theme.spacingM

                Column {
                    width: parent.width - frameToggle.width - Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    StyledText {
                        text: "Mostrar marco del teléfono (Device Frame)"
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                    }
                }
                DankToggle {
                    id: frameToggle
                    checked: root.editDeviceFrame
                    onToggled: isChecked => root.editDeviceFrame = isChecked
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingM

                Column {
                    width: parent.width - kbToggle.width - Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    StyledText {
                        text: "Habilitar teclado físico del PC (hw.keyboard)"
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                    }
                }
                DankToggle {
                    id: kbToggle
                    checked: root.editKeyboard
                    onToggled: isChecked => root.editKeyboard = isChecked
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingM

                Column {
                    width: parent.width - coldToggle.width - Theme.spacingM
                    anchors.verticalCenter: parent.verticalCenter
                    StyledText {
                        text: "Forzar Cold Boot por defecto (sin snapshot)"
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceText
                    }
                }
                DankToggle {
                    id: coldToggle
                    checked: root.editColdBoot
                    onToggled: isChecked => root.editColdBoot = isChecked
                }
            }

            Row {
                width: parent.width
                spacing: Theme.spacingS

                ActionChip {
                    iconName: "save"
                    labelText: "Guardar cambios en " + (root.editingAvdId || "AVD")
                    activeChip: true
                    onClicked: {
                        if (root.daemonInstance && root.editingAvdId !== "") {
                            root.daemonInstance.saveAvdConfig(root.editingAvdId, {
                                "ram_mb": root.editRamMb,
                                "cpu_cores": root.editCpuCores,
                                "gpu_mode": root.editGpuMode,
                                "device_frame": root.editDeviceFrame,
                                "keyboard": root.editKeyboard,
                                "cold_boot": root.editColdBoot
                            });
                        }
                    }
                }
            }
        }
    }

    // 3. CENTRO DE HERRAMIENTAS ADB
    SettingsCard {
        height: adbCol.implicitHeight + Theme.spacingL * 2

        Column {
            id: adbCol
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            Row {
                width: parent.width
                spacing: Theme.spacingS

                StyledText {
                    width: parent.width - adbResetBtn.width - Theme.spacingS
                    text: "Herramientas ADB y Dispositivos Conectados"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }

                ActionChip {
                    id: adbResetBtn
                    iconName: "restart_alt"
                    labelText: "Reiniciar ADB"
                    onClicked: {
                        if (root.daemonInstance)
                            root.daemonInstance.runAdbAction("", "kill-server", "");
                    }
                }
            }

            StyledText {
                visible: root.readyDevices.length === 0
                width: parent.width
                text: "No hay dispositivos ADB activos en este momento. Inicia un emulador o conecta tu teléfono por USB / Wi-Fi."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            Flow {
                visible: root.readyDevices.length > 0
                width: parent.width
                spacing: Theme.spacingS

                Repeater {
                    model: root.readyDevices
                    ActionChip {
                        required property var modelData
                        iconName: modelData.is_emulator ? "smartphone" : "usb"
                        labelText: (modelData.avd_name || modelData.model) + " (" + modelData.serial + ")"
                        activeChip: root.activeAdbDevice && root.activeAdbDevice.serial === modelData.serial
                        onClicked: root.selectedAdbSerial = modelData.serial
                    }
                }
            }

            Flow {
                visible: root.activeAdbDevice !== null
                width: parent.width
                spacing: Theme.spacingS

                Repeater {
                    model: [
                        { "label": "Pantalla (scrcpy)", "icon": "cast",          "act": "scrcpy",        "arg": "" },
                        { "label": "Captura PNG",       "icon": "screenshot",    "act": "screenshot",    "arg": "" },
                        { "label": "ADB Shell",         "icon": "terminal",      "act": "shell",         "arg": "" },
                        { "label": "Logcat",            "icon": "article",       "act": "logcat",        "arg": "" },
                        { "label": "Modo Oscuro",       "icon": "dark_mode",     "act": "toggle-dark",   "arg": "" },
                        { "label": "Layout Bounds",     "icon": "grid_on",       "act": "toggle-bounds", "arg": "" },
                        { "label": "Inicio",            "icon": "home",          "act": "keyevent",      "arg": "HOME" },
                        { "label": "Atrás",             "icon": "arrow_back",    "act": "keyevent",      "arg": "BACK" },
                        { "label": "Recientes",         "icon": "apps",          "act": "keyevent",      "arg": "RECENTS" },
                        { "label": "Reiniciar",         "icon": "refresh",       "act": "reboot",        "arg": "" }
                    ]
                    ActionChip {
                        required property var modelData
                        iconName: modelData.icon
                        labelText: modelData.label
                        onClicked: {
                            if (root.daemonInstance && root.activeAdbDevice) {
                                root.daemonInstance.runAdbAction(root.activeAdbDevice.serial, modelData.act, modelData.arg);
                            }
                        }
                    }
                }
            }

            // Enviar texto rápido
            Row {
                visible: root.activeAdbDevice !== null
                width: parent.width
                spacing: Theme.spacingS

                DankTextField {
                    id: adbTextInput
                    width: parent.width - sendTextBtn.width - Theme.spacingS
                    placeholderText: "Enviar texto al dispositivo activo (adb input text)..."
                    onAccepted: {
                        if (text.trim() !== "" && root.daemonInstance && root.activeAdbDevice) {
                            root.daemonInstance.runAdbAction(root.activeAdbDevice.serial, "input-text", text);
                            text = "";
                        }
                    }
                }

                ActionChip {
                    id: sendTextBtn
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "send"
                    labelText: "Enviar"
                    activeChip: true
                    onClicked: {
                        if (adbTextInput.text.trim() !== "" && root.daemonInstance && root.activeAdbDevice) {
                            root.daemonInstance.runAdbAction(root.activeAdbDevice.serial, "input-text", adbTextInput.text);
                            adbTextInput.text = "";
                        }
                    }
                }
            }

            // Instalar APK por ruta o buscador de archivos
            Row {
                visible: root.activeAdbDevice !== null
                width: parent.width
                spacing: Theme.spacingS

                DankTextField {
                    id: apkPathInput
                    width: parent.width - browseApkBtn.width - installApkBtn.width - Theme.spacingS * 2
                    placeholderText: "Ruta de archivo .apk (o pulsa Buscar / Instalar APK)..."
                    onAccepted: {
                        if (text.trim() !== "" && root.daemonInstance && root.activeAdbDevice) {
                            ToastService.showInfo("Instalando APK...");
                            root.daemonInstance.runAdbAction(root.activeAdbDevice.serial, "install-apk", text.trim());
                        } else if (text.trim() === "") {
                            root.browseForApk(true);
                        }
                    }
                }

                ActionChip {
                    id: browseApkBtn
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "folder_open"
                    labelText: "Buscar"
                    onClicked: root.browseForApk(false)
                }

                ActionChip {
                    id: installApkBtn
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "install_mobile"
                    labelText: "Instalar APK"
                    activeChip: true
                    onClicked: {
                        if (!root.daemonInstance || !root.activeAdbDevice)
                            return;
                        if (apkPathInput.text.trim() !== "") {
                            ToastService.showInfo("Instalando APK...");
                            root.daemonInstance.runAdbAction(root.activeAdbDevice.serial, "install-apk", apkPathInput.text.trim());
                        } else {
                            root.browseForApk(true);
                        }
                    }
                }
            }

            // Conectar ADB Wi-Fi
            Row {
                width: parent.width
                spacing: Theme.spacingS

                DankTextField {
                    id: wifiAddrInput
                    width: parent.width - wifiConnectBtn.width - Theme.spacingS
                    placeholderText: "ADB Wi-Fi: IP:PUERTO (ej. 192.168.1.50:5555)"
                    onAccepted: {
                        if (text.trim() !== "" && root.daemonInstance) {
                            root.daemonInstance.runAdbAction("", "connect", text.trim());
                        }
                    }
                }

                ActionChip {
                    id: wifiConnectBtn
                    anchors.verticalCenter: parent.verticalCenter
                    iconName: "wifi"
                    labelText: "Conectar"
                    onClicked: {
                        if (wifiAddrInput.text.trim() !== "" && root.daemonInstance) {
                            root.daemonInstance.runAdbAction("", "connect", wifiAddrInput.text.trim());
                        }
                    }
                }
            }
        }
    }

    // 4. RUTAS DEL ANDROID SDK Y PREFERENCIAS
    SettingsCard {
        height: sdkCol.implicitHeight + Theme.spacingL * 2

        Column {
            id: sdkCol
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Rutas del Android SDK y Sondeo"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                text: "SDK detectado: " + (root.sdkPaths.sdk_dir || "~/Android/Sdk") +
                      "\nEmulator: " + (root.sdkPaths.emulator_bin || "No encontrado") +
                      "\nADB: " + (root.sdkPaths.adb_bin || "No encontrado") +
                      "\nscrcpy: " + (root.sdkPaths.scrcpy_bin || "No instalado")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            StringSetting {
                settingKey: "customSdkPath"
                label: "Ruta personalizada del Android SDK (opcional)"
                description: "Déjalo vacío para detectar automáticamente ~/Android/Sdk o $ANDROID_HOME"
                placeholder: "~/Android/Sdk"
                defaultValue: ""
            }

            ToggleSetting {
                settingKey: "alwaysShowInBar"
                label: "Mostrar siempre en la barra superior"
                description: "Si está desactivado, el indicador en la barra superior aparece automáticamente solo cuando hay un emulador o dispositivo ADB activo"
                defaultValue: false
            }

            SliderSetting {
                settingKey: "pollIntervalSec"
                label: "Intervalo de actualización de estado"
                description: "Cada cuántos segundos comprobar si hay emuladores o dispositivos ADB activos"
                defaultValue: 4
                minimum: 2
                maximum: 20
                unit: "s"
            }
        }
    }

    // 5. ATAJOS DE TECLADO (WAYLAND)
    SettingsCard {
        height: bindsCol.implicitHeight + Theme.spacingL * 2

        Column {
            id: bindsCol
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Atajos Rápidos por Compositor (Opcional)"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            BindCode {
                titleText: "Niri (~/.config/niri/config.kdl)"
                code: "Mod+Alt+E hotkey-overlay-title=\"Iniciar/Detener Emulador Android\" { spawn \"dms\" \"ipc\" \"call\" \"androidEmulator\" \"toggleDefault\"; }\n" +
                      "Mod+Alt+A hotkey-overlay-title=\"Panel rápido de Emuladores Android\" { spawn \"dms\" \"ipc\" \"call\" \"control-center\" \"openWith\" \"plugin_androidEmulator\"; }\n" +
                      "Mod+Shift+A hotkey-overlay-title=\"Configuración de Emuladores Android & ADB\" { spawn \"dms\" \"ipc\" \"call\" \"androidEmulator\" \"openSettings\"; }"
            }

            BindCode {
                titleText: "Hyprland (~/.config/hypr/hyprland.conf)"
                code: "bind = SUPER ALT, E, exec, dms ipc call androidEmulator toggleDefault\n" +
                      "bind = SUPER SHIFT, E, exec, dms ipc call androidEmulator openSettings"
            }
        }
    }
}
