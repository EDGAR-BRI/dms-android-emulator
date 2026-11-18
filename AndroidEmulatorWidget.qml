import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.DCommon.Widgets
import qs.Widgets
import qs.Modules.ControlCenter
import qs.Modules.ControlCenter.Widgets
import qs.Modules.Plugins

PluginComponent {
    id: root

    layerNamespacePlugin: "android-emulator"

    readonly property var daemonInstance: pluginService && pluginService.pluginDaemonInstances ? pluginService.pluginDaemonInstances[pluginId] : null
    readonly property var avds: daemonInstance ? daemonInstance.avds : []
    readonly property var adbDevices: daemonInstance ? daemonInstance.adbDevices : []
    readonly property int runningCount: daemonInstance ? daemonInstance.runningCount : 0
    readonly property int deviceCount: daemonInstance ? daemonInstance.deviceCount : 0
    readonly property string defaultAvd: daemonInstance ? daemonInstance.defaultAvd : ""
    readonly property var runningAvds: daemonInstance ? daemonInstance.runningAvds : []
    readonly property var activeDevice: daemonInstance ? daemonInstance.activeDevice : null
    readonly property bool isBusy: daemonInstance ? daemonInstance.isBusy : false

    // Show automatically in the top bar whenever an emulator or ADB device is active (or always if configured)
    readonly property bool alwaysShowInBar: Boolean(pluginData.alwaysShowInBar)
    readonly property bool showInBar: alwaysShowInBar || runningCount > 0 || deviceCount > 0
    _visibilityOverride: true
    _visibilityOverrideValue: showInBar

    ccWidgetIcon: "smartphone"
    ccWidgetPrimaryText: "Android AVD"
    ccWidgetSecondaryText: {
        if (runningCount > 0) {
            if (runningCount === 1 && runningAvds.length > 0)
                return "Activo • " + runningAvds[0].display_name;
            return runningCount + " emuladores activos";
        }
        if (deviceCount > 0)
            return deviceCount + " dispositivo ADB";
        if (avds.length > 0) {
            const def = avds.find(a => a.id === defaultAvd) || avds[0];
            return avds.length + " AVDs • " + def.display_name;
        }
        return "Sin emuladores";
    }
    ccWidgetIsActive: runningCount > 0
    ccWidgetIsToggle: true
    ccDetailHeight: 360

    onCcWidgetToggled: {
        if (daemonInstance) {
            daemonInstance.toggleDefaultAvd();
        }
    }

    onCcWidgetExpanded: {
        if (daemonInstance) {
            daemonInstance.refreshStatus();
        }
    }

    pillRightClickAction: () => {
        if (root.daemonInstance) {
            root.daemonInstance.toggleDefaultAvd();
        }
    }

    component EmulatorManagerBody: Column {
        id: mgrBody
        width: parent.width
        spacing: CcMetrics.detailContentGap

        property string selectedSerial: ""
        readonly property var readyDevices: root.adbDevices.filter(d => d.state === "device")
        readonly property var currentDevice: {
            if (readyDevices.length === 0)
                return null;
            const found = readyDevices.find(d => d.serial === selectedSerial);
            return found || readyDevices[0];
        }

        CcEmptyState {
            visible: root.avds.length === 0
            iconName: "smartphone"
            title: "No se encontraron emuladores AVD en ~/.android/avd"
        }

        CcGroup {
            visible: root.avds.length > 0

            Repeater {
                model: root.avds

                CcListRow {
                    id: avdRow
                    required property var modelData

                    readonly property bool isDefault: modelData.id === root.defaultAvd
                    readonly property bool isRunning: Boolean(modelData.running)
                    readonly property bool isHidden: Boolean(modelData.hidden_window)

                    active: isRunning
                    title: modelData.display_name + (isDefault ? " ★" : "")
                    subtitle: {
                        const parts = [];
                        if (isRunning) {
                            parts.push(modelData.serial ? modelData.serial : "Iniciando...");
                            if (isHidden)
                                parts.push("Ventana oculta");
                        } else {
                            parts.push("Detenido");
                        }
                        if (modelData.target_label)
                            parts.push(modelData.target_label);
                        parts.push(Math.round(modelData.ram_mb / 1024 * 10) / 10 + " GB RAM");
                        parts.push(modelData.cpu_cores + " CPU");
                        return parts.join(" • ");
                    }
                    clickable: true
                    onClicked: {
                        if (!root.daemonInstance)
                            return;
                        if (avdRow.isRunning) {
                            if (avdRow.modelData.serial) {
                                root.daemonInstance.runAdbAction(avdRow.modelData.serial, "scrcpy", "");
                            } else {
                                root.daemonInstance.stopAvd(avdRow.modelData.id);
                            }
                        } else {
                            root.daemonInstance.launchAvd(avdRow.modelData.id, "normal");
                        }
                    }

                    leading: CcStatusDot {
                        color: avdRow.isRunning ? (avdRow.modelData.boot_completed ? Theme.success : Theme.warning) : Theme.surfaceVariantText
                    }

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Theme.spacingXXS

                        DActionButton {
                            visible: avdRow.isRunning && avdRow.modelData.serial !== ""
                            buttonSize: Theme.buttonHeightXS
                            iconSize: Theme.iconSizeSmall
                            iconName: "cast"
                            iconColor: Theme.primary
                            Accessible.name: "Mostrar pantalla con scrcpy"
                            onClicked: {
                                if (root.daemonInstance)
                                    root.daemonInstance.runAdbAction(avdRow.modelData.serial, "scrcpy", "");
                            }
                        }

                        DActionButton {
                            visible: !avdRow.isRunning
                            buttonSize: Theme.buttonHeightXS
                            iconSize: Theme.iconSizeSmall
                            iconName: "ac_unit"
                            iconColor: Theme.surfaceVariantText
                            Accessible.name: "Cold Boot"
                            onClicked: {
                                if (root.daemonInstance)
                                    root.daemonInstance.launchAvd(avdRow.modelData.id, "cold");
                            }
                        }

                        DActionButton {
                            buttonSize: Theme.buttonHeightXS
                            iconSize: Theme.iconSizeSmall
                            iconName: avdRow.isRunning ? "stop" : "play_arrow"
                            iconColor: avdRow.isRunning ? Theme.error : Theme.primary
                            Accessible.name: avdRow.isRunning ? "Detener emulador" : "Iniciar emulador"
                            onClicked: {
                                if (root.daemonInstance)
                                    root.daemonInstance.toggleAvd(avdRow.modelData.id, "normal");
                            }
                        }

                        DActionButton {
                            buttonSize: Theme.buttonHeightXS
                            iconSize: Theme.iconSizeSmall
                            iconName: "tune"
                            iconColor: Theme.surfaceText
                            Accessible.name: "Configurar emulador"
                            onClicked: {
                                if (root.daemonInstance)
                                    root.daemonInstance.openPluginSettings();
                            }
                        }
                    }
                }
            }
        }

        // Quick ADB controls when at least one device/emulator is online
        CcGroup {
            visible: mgrBody.currentDevice !== null

            CcListRow {
                iconName: "adb"
                title: "ADB: " + (mgrBody.currentDevice ? (mgrBody.currentDevice.avd_name || mgrBody.currentDevice.model) : "")
                subtitle: mgrBody.currentDevice ? (mgrBody.currentDevice.serial + (mgrBody.currentDevice.android_version ? " • Android " + mgrBody.currentDevice.android_version : "")) : ""
                active: true

                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Theme.spacingXXS

                    DActionButton {
                        visible: mgrBody.readyDevices.length > 1
                        buttonSize: Theme.buttonHeightXS
                        iconSize: Theme.iconSizeSmall
                        iconName: "swap_horiz"
                        iconColor: Theme.surfaceText
                        Accessible.name: "Cambiar dispositivo ADB"
                        onClicked: {
                            const list = mgrBody.readyDevices;
                            const idx = list.findIndex(d => d.serial === mgrBody.currentDevice.serial);
                            const next = list[(idx + 1) % list.length];
                            mgrBody.selectedSerial = next.serial;
                        }
                    }

                    DActionButton {
                        buttonSize: Theme.buttonHeightXS
                        iconSize: Theme.iconSizeSmall
                        iconName: "terminal"
                        iconColor: Theme.surfaceText
                        Accessible.name: "Abrir ADB Shell"
                        onClicked: {
                            if (root.daemonInstance && mgrBody.currentDevice)
                                root.daemonInstance.runAdbAction(mgrBody.currentDevice.serial, "shell", "");
                        }
                    }

                    DActionButton {
                        buttonSize: Theme.buttonHeightXS
                        iconSize: Theme.iconSizeSmall
                        iconName: "screenshot"
                        iconColor: Theme.surfaceText
                        Accessible.name: "Captura de pantalla"
                        onClicked: {
                            if (root.daemonInstance && mgrBody.currentDevice)
                                root.daemonInstance.runAdbAction(mgrBody.currentDevice.serial, "screenshot", "");
                        }
                    }
                }
            }

            Item {
                width: parent.width
                height: adbActionsFlow.implicitHeight + Theme.spacingS * 2

                Flow {
                    id: adbActionsFlow
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: CcMetrics.rowPaddingH
                    anchors.rightMargin: CcMetrics.rowPaddingH
                    spacing: Theme.spacingXS

                    Repeater {
                        model: [
                            { "label": "Atrás",    "icon": "arrow_back",     "act": "keyevent",        "arg": "BACK" },
                            { "label": "Inicio",   "icon": "home",           "act": "keyevent",        "arg": "HOME" },
                            { "label": "Recientes","icon": "apps",           "act": "keyevent",        "arg": "RECENTS" },
                            { "label": "Pegar",    "icon": "content_paste",  "act": "paste-clipboard", "arg": "" },
                            { "label": "Oscuro",   "icon": "dark_mode",      "act": "toggle-dark",     "arg": "" },
                            { "label": "Bounds",   "icon": "grid_on",        "act": "toggle-bounds",   "arg": "" },
                            { "label": "Logcat",   "icon": "article",        "act": "logcat",          "arg": "" },
                            { "label": "Pantalla", "icon": "cast",           "act": "scrcpy",          "arg": "" },
                            { "label": "APK",      "icon": "install_mobile", "act": "install-apk",     "arg": "" }
                        ]

                        delegate: StyledRect {
                            required property var modelData
                            height: 28
                            width: chipRow.implicitWidth + 16
                            radius: 14
                            color: chipMa.pressed ? Theme.primaryPressed : (chipMa.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh)
                            border.width: 1
                            border.color: Theme.withAlpha(Theme.outline, 0.3)

                            Row {
                                id: chipRow
                                anchors.centerIn: parent
                                spacing: 4
                                DIcon {
                                    name: modelData.icon
                                    size: 14
                                    color: Theme.primary
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                                StyledText {
                                    text: modelData.label
                                    font.pixelSize: Theme.fontSizeSmall - 1
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            MouseArea {
                                id: chipMa
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    if (root.daemonInstance && mgrBody.currentDevice) {
                                        root.daemonInstance.runAdbAction(mgrBody.currentDevice.serial, modelData.act, modelData.arg);
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        CcGroup {
            CcListRow {
                iconName: "settings"
                title: "Configurar Emuladores y Herramientas ADB"
                subtitle: "Editar RAM, CPU, GPU, arranque, ADB Wi-Fi y rutas"
                clickable: true
                onClicked: {
                    if (root.daemonInstance)
                        root.daemonInstance.openPluginSettings();
                }

                DIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "chevron_right"
                    size: Theme.iconSize
                    color: Theme.surfaceVariantText
                }
            }
        }
    }

    ccDetailContent: Component {
        Item {
            id: detailRoot

            readonly property string title: "Emuladores Android & ADB"
            readonly property Item headerActions: Row {
                spacing: Theme.spacingXXS

                DActionButton {
                    buttonSize: CcMetrics.headerActionSize
                    iconSize: CcMetrics.headerActionIconSize
                    iconName: "sync"
                    iconColor: Theme.surfaceText
                    Accessible.name: "Actualizar lista"
                    onClicked: {
                        if (root.daemonInstance)
                            root.daemonInstance.refreshStatus();
                    }
                }

                DActionButton {
                    buttonSize: CcMetrics.headerActionSize
                    iconSize: CcMetrics.headerActionIconSize
                    iconName: "settings"
                    iconColor: Theme.surfaceText
                    Accessible.name: "Configuración del plugin"
                    onClicked: {
                        if (root.daemonInstance)
                            root.daemonInstance.openPluginSettings();
                    }
                }
            }

            DFlickable {
                anchors.fill: parent
                contentHeight: detailCol.implicitHeight
                clip: true

                EmulatorManagerBody {
                    id: detailCol
                    width: parent.width
                }
            }
        }
    }

    ccExpandedContent: Component {
        CcTileActions {
            actions: root.avds.map(avd => ({
                text: (avd.running ? "Detener " : "Iniciar ") + avd.display_name,
                icon: avd.running ? "stop_circle" : "play_circle",
                active: avd.running,
                toggle: true,
                trigger: () => {
                    if (root.daemonInstance)
                        root.daemonInstance.toggleAvd(avd.id, "normal");
                }
            }))
        }
    }

    horizontalBarPill: Component {
        Row {
            visible: root.showInBar
            spacing: Theme.spacingXS

            DIcon {
                name: "smartphone"
                size: root.iconSize
                color: root.runningCount > 0
                    ? (root.runningAvds.some(a => !a.boot_completed) ? Theme.warning : Theme.primary)
                    : (root.deviceCount > 0 ? Theme.success : Theme.surfaceVariantText)
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                visible: root.runningCount > 0 || root.deviceCount > 0
                text: {
                    if (root.runningCount === 1 && root.runningAvds.length > 0) {
                        const avd = root.runningAvds[0];
                        return avd.display_name + (!avd.boot_completed ? " (Iniciando...)" : "");
                    }
                    if (root.runningCount > 1)
                        return root.runningCount + " AVDs";
                    if (root.deviceCount > 0 && root.activeDevice)
                        return root.activeDevice.model || "ADB (" + root.deviceCount + ")";
                    return "";
                }
                font.pixelSize: root.textSize
                font.weight: Font.Bold
                color: root.runningCount > 0
                    ? (root.runningAvds.some(a => !a.boot_completed) ? Theme.warning : Theme.primary)
                    : Theme.surfaceText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    verticalBarPill: Component {
        Column {
            visible: root.showInBar
            spacing: Theme.spacingXXS

            DIcon {
                name: "smartphone"
                size: root.iconSize
                color: root.runningCount > 0 ? Theme.primary : Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                visible: root.runningCount > 0 || root.deviceCount > 0
                text: String(root.runningCount > 0 ? root.runningCount : root.deviceCount)
                font.pixelSize: root.textSize
                font.weight: Font.Bold
                color: Theme.primary
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutWidth: 430
    popoutHeight: 460

    popoutContent: Component {
        Column {
            id: popRootCol
            width: parent ? parent.width : 400
            spacing: Theme.spacingM

            Row {
                width: parent.width
                spacing: Theme.spacingS

                DIcon {
                    name: "smartphone"
                    size: Theme.iconSize
                    color: root.runningCount > 0 ? Theme.primary : Theme.surfaceText
                    anchors.verticalCenter: parent.verticalCenter
                }

                Column {
                    width: parent.width - popHeaderBtns.width - Theme.iconSize - Theme.spacingS * 2
                    anchors.verticalCenter: parent.verticalCenter

                    StyledText {
                        width: parent.width
                        text: "Emuladores Android & ADB"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }

                    StyledText {
                        width: parent.width
                        text: root.runningCount > 0
                            ? (root.runningCount + " emulador(es) en ejecución • " + root.deviceCount + " ADB")
                            : (root.avds.length + " AVDs disponibles")
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: root.runningCount > 0 ? Theme.primary : Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }

                Row {
                    id: popHeaderBtns
                    spacing: Theme.spacingXXS
                    anchors.verticalCenter: parent.verticalCenter

                    DActionButton {
                        visible: root.runningCount > 0
                        buttonSize: Theme.buttonHeightXS
                        iconSize: Theme.iconSizeSmall
                        iconName: "stop_circle"
                        iconColor: Theme.error
                        Accessible.name: "Detener todos los emuladores"
                        onClicked: {
                            if (root.daemonInstance)
                                root.daemonInstance.stopAll();
                        }
                    }

                    DActionButton {
                        buttonSize: Theme.buttonHeightXS
                        iconSize: Theme.iconSizeSmall
                        iconName: "sync"
                        iconColor: Theme.surfaceText
                        Accessible.name: "Actualizar"
                        onClicked: {
                            if (root.daemonInstance)
                                root.daemonInstance.refreshStatus();
                        }
                    }

                    DActionButton {
                        buttonSize: Theme.buttonHeightXS
                        iconSize: Theme.iconSizeSmall
                        iconName: "settings"
                        iconColor: Theme.surfaceText
                        Accessible.name: "Abrir configuración"
                        onClicked: {
                            root.closePopout();
                            if (root.daemonInstance)
                                root.daemonInstance.openPluginSettings();
                        }
                    }
                }
            }

            DFlickable {
                width: parent.width
                height: Math.min(390, Math.max(200, popBody.implicitHeight))
                implicitHeight: height
                contentHeight: popBody.implicitHeight
                clip: true

                EmulatorManagerBody {
                    id: popBody
                    width: parent.width
                }
            }
        }
    }
}
