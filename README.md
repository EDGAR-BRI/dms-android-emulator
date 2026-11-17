# DMS Android Emulator & ADB Manager (`androidEmulator`)

Plugin nativo para **Dux Modular Shell (DMS / DankMaterialShell)** en Wayland (**Niri**, **Hyprland**, **Sway**, **MangoWM**) que permite **listar, iniciar, detener, configurar emuladores de Android Studio (AVDs) y controlar dispositivos por ADB** sin necesidad de abrir Android Studio.

---

## Funcionalidades

- **Widget nativo para el Control Center y la Barra Superior (DankBar)**:
  - **Click rápido en el tile**: Inicia o detiene tu emulador favorito con un solo click.
  - **Panel desplegable en vivo**: Lista todos tus AVDs (`~/.android/avd`), mostrando su estado (`En ejecución`, `Ventana oculta`, `Detenido`), serial ADB (`emulator-5554`, etc.), API, RAM y núcleos de CPU.
  - **Acceso directo a configuración (`⚙`)**: Abre al instante la pantalla de ajustes del plugin para modificar hardware o ejecutar herramientas ADB.
- **Gestión completa de Emuladores (`~/Android/Sdk/emulator/emulator`)**:
  - Iniciar en modo normal (Fast Boot), **Cold Boot** (`-no-snapshot-load`), **Headless** (`-no-window`) o **Wipe Data**.
  - Detener limpiamente mediante `adb emu kill` y limpieza automática de archivos `.lock` huérfanos.
  - **Detección de ventana oculta (`-qt-hide-window`)**: Si Android Studio dejó un emulador corriendo oculto en segundo plano, te lo indica y permite abrir su pantalla interactiva al instante con `scrcpy`.
- **Editor Gráfico de `config.ini` (Sin abrir Android Studio)**:
  - Cambia memoria RAM (`hw.ramSize`), núcleos de CPU (`hw.cpu.ncore`), aceleración GPU (`auto`, `host`, `swiftshader_indirect`, `angle_indirect`), marco del teléfono (`showDeviceFrame`), teclado físico (`hw.keyboard`) y modo Cold Boot por defecto.
- **Centro de Herramientas ADB**:
  - Espejo de pantalla con `scrcpy`, captura de pantalla PNG (guardada y copiada al portapapeles), `adb shell`, `adb logcat`, botones rápidos (`Home`, `Atrás`, `Recientes`), cambio rápido de **Modo Oscuro**, **Layout Bounds**, envío de texto (`adb input text`), instalación de APKs y conexión **ADB Wi-Fi (`IP:PUERTO`)**.
- **Actualización con 1 click desde GitHub**:
  - Comprueba y descarga mejoras directamente desde **Ajustes de DMS → Plugins → Android Emulator & ADB Manager**.

---

## Instalación rápida (PC o Laptop)

```bash
git clone git@github.com:EDGAR-BRI/dms-android-emulator.git ~/.config/dms/plugins/android-emulator
cd ~/.config/dms/plugins/android-emulator
chmod +x install.sh
./install.sh
```

Luego agrega el widget **Android Emulator & ADB Manager** en tu **Control Center** (`Editar → + Add widget`) o en tu barra superior.

---

## Comandos IPC y Atajos Recomendados

```bash
dms ipc call androidEmulator toggleDefault   # Iniciar/detener emulador favorito
dms ipc call androidEmulator launch Medium_Phone
dms ipc call androidEmulator stopAll
dms ipc call androidEmulator openSettings    # Abrir editor y herramientas ADB
```

### Niri (`~/.config/niri/config.kdl`)
```kdl
    Mod+Alt+E hotkey-overlay-title="Iniciar/Detener Emulador Android" { spawn "dms" "ipc" "call" "androidEmulator" "toggleDefault"; }
    Mod+Shift+E hotkey-overlay-title="Configuración Emulador Android" { spawn "dms" "ipc" "call" "androidEmulator" "openSettings"; }
```

### Hyprland (`~/.config/hypr/hyprland.conf`)
```ini
bind = SUPER ALT, E, exec, dms ipc call androidEmulator toggleDefault
bind = SUPER SHIFT, E, exec, dms ipc call androidEmulator openSettings
```
