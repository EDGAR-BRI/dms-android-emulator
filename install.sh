#!/usr/bin/env bash
set -euo pipefail

PLUGIN_ID="androidEmulator"
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DMS_DIR_KEBAB="${HOME}/.config/dms/plugins/android-emulator"

echo "==> Instalando plugin ${PLUGIN_ID} para DMS..."

mkdir -p "${HOME}/.config/dms/plugins"

if [ "${PLUGIN_DIR}" != "$(realpath "${DMS_DIR_KEBAB}" 2>/dev/null || echo "")" ]; then
    ln -sfn "${PLUGIN_DIR}" "${DMS_DIR_KEBAB}"
fi
echo "    Instalado en: ${DMS_DIR_KEBAB}"

chmod +x "${PLUGIN_DIR}/avd_helper.py" "${PLUGIN_DIR}/install.sh" "${PLUGIN_DIR}/update_helper.sh" 2>/dev/null || true

# Verificar herramientas disponibles del SDK
if [ -x "${HOME}/Android/Sdk/emulator/emulator" ]; then
    echo "    ✓ Android Emulator encontrado en ~/Android/Sdk/emulator/emulator"
elif command -v emulator >/dev/null 2>&1; then
    echo "    ✓ Android Emulator encontrado en $(command -v emulator)"
else
    echo "    [Aviso] No se encontró el binario 'emulator'. Configura tu ruta del SDK en los ajustes del plugin."
fi

if [ -x "${HOME}/Android/Sdk/platform-tools/adb" ]; then
    echo "    ✓ ADB encontrado en ~/Android/Sdk/platform-tools/adb"
elif command -v adb >/dev/null 2>&1; then
    echo "    ✓ ADB encontrado en $(command -v adb)"
else
    echo "    [Aviso] No se encontró 'adb'. Instala android-tools o platform-tools."
fi

# Registrar y habilitar en plugin_settings.json y plugins.lock.json
python3 - "${PLUGIN_DIR}" <<'PY' 2>/dev/null || true
import json, os, subprocess, sys

plugin_dir = sys.argv[1]
commit_hash = ""
try:
    commit_hash = subprocess.check_output(
        ["git", "-C", plugin_dir, "rev-parse", "HEAD"],
        stderr=subprocess.DEVNULL,
        text=True,
    ).strip()
except Exception:
    pass

for base in [os.path.expanduser("~/.config/dms"), os.path.expanduser("~/.config/DankMaterialShell")]:
    os.makedirs(base, exist_ok=True)
    p = os.path.join(base, "plugin_settings.json")
    d = {}
    if os.path.exists(p):
        try:
            with open(p, "r", encoding="utf-8") as f:
                d = json.load(f)
        except Exception:
            pass
    if "androidEmulator" not in d:
        d["androidEmulator"] = {}
    d["androidEmulator"].setdefault("enabled", True)
    try:
        with open(p, "w", encoding="utf-8") as f:
            json.dump(d, f, indent=2)
    except Exception:
        pass

    s_path = os.path.join(base, "settings.json")
    if os.path.exists(s_path):
        try:
            with open(s_path, "r", encoding="utf-8") as f:
                s_data = json.load(f)
            changed = False
            for bar in s_data.get("barConfigs", []):
                c_widgets = bar.get("centerWidgets", [])
                has_emu = any(
                    (w == "androidEmulator") or (isinstance(w, dict) and w.get("id") == "androidEmulator")
                    for w in c_widgets
                )
                if not has_emu:
                    if "agentMonitor" in c_widgets:
                        c_widgets.insert(c_widgets.index("agentMonitor") + 1, "androidEmulator")
                    elif "music" in c_widgets:
                        c_widgets.insert(c_widgets.index("music") + 1, "androidEmulator")
                    else:
                        c_widgets.insert(0, "androidEmulator")
                    bar["centerWidgets"] = c_widgets
                    changed = True
            if changed:
                with open(s_path, "w", encoding="utf-8") as f:
                    json.dump(s_data, f, indent=2)
        except Exception:
            pass

lock_path = os.path.expanduser("~/.config/dms/plugins.lock.json")
lock_data = {"lockfileVersion": 1, "plugins": {}}
if os.path.exists(lock_path):
    try:
        with open(lock_path, "r", encoding="utf-8") as f:
            lock_data = json.load(f)
    except Exception:
        pass
lock_data.setdefault("plugins", {})
lock_data["plugins"]["androidEmulator"] = {
    "repo": "git@github.com:EDGAR-BRI/dms-android-emulator.git",
    "commit": commit_hash or "main",
}
try:
    with open(lock_path, "w", encoding="utf-8") as f:
        json.dump(lock_data, f, indent=2)
except Exception:
    pass
PY

if command -v dms >/dev/null 2>&1; then
    echo "==> Escaneando y habilitando el plugin en DMS..."
    dms ipc call plugin-scan scan >/dev/null 2>&1 || true
    dms ipc call plugins enable "${PLUGIN_ID}" >/dev/null 2>&1 || true
    dms ipc call plugins reload "${PLUGIN_ID}" >/dev/null 2>&1 || true
fi

echo ""
echo "✅ Plugin ${PLUGIN_ID} instalado correctamente."
echo "Puedes añadir el widget 'Android Emulator & ADB Manager' en:"
echo "  - Control Center → Editar → + Add widget"
echo "  - Barra superior (DankBar) → Ajustes de barra"
echo ""
echo "Atajos opcionales para ~/.config/niri/config.kdl:"
echo '    Mod+Alt+E hotkey-overlay-title="Iniciar/Detener Emulador Android" { spawn "dms" "ipc" "call" "androidEmulator" "toggleDefault"; }'
