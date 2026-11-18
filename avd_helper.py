#!/usr/bin/env python3
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path


def resolve_sdk_paths(custom_sdk: str = "") -> dict:
    home = Path.home()
    candidates = []
    if custom_sdk:
        candidates.append(Path(os.path.expanduser(custom_sdk)))
    # Prefer Android Studio's default ~/Android/Sdk when present
    candidates.append(home / "Android" / "Sdk")
    for env_var in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        val = os.environ.get(env_var, "").strip()
        if val:
            candidates.append(Path(os.path.expanduser(val)))
    candidates.extend([
        Path("/opt/android-sdk"),
        home / ".local" / "share" / "android-sdk",
    ])

    sdk_dir = None
    for cand in candidates:
        if (cand / "emulator" / "emulator").is_file():
            sdk_dir = cand
            break
    if not sdk_dir:
        for cand in candidates:
            if (cand / "platform-tools" / "adb").is_file():
                sdk_dir = cand
                break

    emulator_bin = ""
    if sdk_dir and (sdk_dir / "emulator" / "emulator").is_file():
        emulator_bin = str(sdk_dir / "emulator" / "emulator")
    else:
        emulator_bin = shutil.which("emulator") or ""

    adb_bin = ""
    if sdk_dir and (sdk_dir / "platform-tools" / "adb").is_file():
        adb_bin = str(sdk_dir / "platform-tools" / "adb")
    else:
        adb_bin = shutil.which("adb") or ""

    scrcpy_bin = shutil.which("scrcpy") or ""

    return {
        "sdk_dir": str(sdk_dir) if sdk_dir else str(home / "Android" / "Sdk"),
        "emulator_bin": emulator_bin,
        "adb_bin": adb_bin,
        "scrcpy_bin": scrcpy_bin,
    }


def avd_home_dir() -> Path:
    env_home = os.environ.get("ANDROID_AVD_HOME", "").strip()
    if env_home:
        return Path(os.path.expanduser(env_home))
    return Path.home() / ".android" / "avd"


def parse_ini_file(path: Path) -> dict:
    data = {}
    if not path.is_file():
        return data
    try:
        with path.open("r", encoding="utf-8", errors="replace") as f:
            for line in f:
                stripped = line.strip()
                if not stripped or stripped.startswith("#") or "=" not in stripped:
                    continue
                k, v = stripped.split("=", 1)
                data[k.strip()] = v.strip()
    except Exception:
        pass
    return data


def update_ini_file(path: Path, updates: dict) -> bool:
    if not path.is_file():
        return False
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines(keepends=True)
    except Exception:
        return False

    remaining = {str(k): str(v) for k, v in updates.items()}
    out_lines = []
    for line in lines:
        stripped = line.strip()
        if stripped and not stripped.startswith("#") and "=" in stripped:
            key = stripped.split("=", 1)[0].strip()
            if key in remaining:
                ending = "\n" if line.endswith("\n") else ""
                out_lines.append(f"{key}={remaining.pop(key)}{ending}")
                continue
        out_lines.append(line)

    for k, v in remaining.items():
        if out_lines and not out_lines[-1].endswith("\n"):
            out_lines[-1] += "\n"
        out_lines.append(f"{k}={v}\n")

    path.write_text("".join(out_lines), encoding="utf-8")
    return True


def run_cmd(cmd: list, timeout: float = 4.0, env: dict = None) -> tuple:
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
        )
        return proc.returncode, proc.stdout or "", proc.stderr or ""
    except subprocess.TimeoutExpired:
        return 124, "", "timeout"
    except Exception as exc:
        return 1, "", str(exc)


def sdk_env(paths: dict) -> dict:
    env = os.environ.copy()
    sdk_dir = paths.get("sdk_dir", "")
    if sdk_dir:
        env["ANDROID_HOME"] = sdk_dir
        env["ANDROID_SDK_ROOT"] = sdk_dir
        pt_dir = str(Path(sdk_dir) / "platform-tools")
        emu_dir = str(Path(sdk_dir) / "emulator")
        old_path = env.get("PATH", "")
        clean_parts = [
            p for p in old_path.split(os.pathsep)
            if p and not (p.startswith("/opt/android-sdk") and sdk_dir != "/opt/android-sdk")
        ]
        env["PATH"] = os.pathsep.join([pt_dir, emu_dir] + clean_parts)
    return env


def ensure_emulator_conf(paths: dict) -> None:
    """Ensure Qt Emulator.conf enables clipboardSharing and points adbPath to the real adb binary."""
    conf_dir = Path.home() / ".config" / "Android Open Source Project"
    conf_file = conf_dir / "Emulator.conf"
    adb_bin = paths.get("adb_bin", "")
    try:
        conf_dir.mkdir(parents=True, exist_ok=True)
        lines = []
        if conf_file.is_file():
            lines = conf_file.read_text(encoding="utf-8", errors="replace").splitlines()

        has_set_section = False
        in_set_section = False
        updated_keys = set()
        desired = {
            "clipboardSharing": "true",
        }
        if adb_bin:
            desired["autoFindAdb"] = "false"
            desired["adbPath"] = adb_bin

        out_lines = []
        for line in lines:
            stripped = line.strip()
            if stripped.startswith("[") and stripped.endswith("]"):
                if in_set_section:
                    for k, v in desired.items():
                        if k not in updated_keys:
                            out_lines.append(f"{k}={v}")
                            updated_keys.add(k)
                in_set_section = (stripped == "[set]")
                if in_set_section:
                    has_set_section = True
                out_lines.append(line)
                continue

            if in_set_section and "=" in stripped and not stripped.startswith("#"):
                k = stripped.split("=", 1)[0].strip()
                if k in desired:
                    out_lines.append(f"{k}={desired[k]}")
                    updated_keys.add(k)
                    continue
            out_lines.append(line)

        if not has_set_section:
            if out_lines and out_lines[-1].strip() != "":
                out_lines.append("")
            out_lines.append("[set]")
            for k, v in desired.items():
                out_lines.append(f"{k}={v}")
        elif in_set_section:
            for k, v in desired.items():
                if k not in updated_keys:
                    out_lines.append(f"{k}={v}")

        conf_file.write_text("\n".join(out_lines) + "\n", encoding="utf-8")
    except Exception:
        pass


def get_running_emulator_procs() -> dict:
    """Map AVD name -> process info from ps."""
    procs = {}
    rc, out, _ = run_cmd(["ps", "-eo", "pid=,args="], timeout=2.0)
    if rc != 0:
        return procs

    for line in out.splitlines():
        line = line.strip()
        if not line:
            continue
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        args = parts[1]
        if "qemu-system" not in args and "/emulator/emulator" not in args and " -avd " not in args:
            continue

        avd_name = ""
        m = re.search(r"(?:^|\s)-avd\s+(\S+)", args)
        if m:
            avd_name = m.group(1).strip("'\"")
        else:
            m2 = re.search(r"(?:^|\s)@(\S+)", args)
            if m2:
                avd_name = m2.group(1).strip("'\"")

        if not avd_name:
            continue

        hidden = ("-qt-hide-window" in args) or ("-no-window" in args)
        # Prefer qemu-system PID if both wrapper and qemu exist
        existing = procs.get(avd_name)
        is_qemu = "qemu-system" in args
        if not existing or is_qemu:
            procs[avd_name] = {
                "pid": pid,
                "hidden_window": hidden,
                "is_qemu": is_qemu,
                "args": args,
            }
    return procs


def get_adb_devices(adb_bin: str) -> list:
    devices = []
    if not adb_bin:
        return devices

    rc, out, _ = run_cmd([adb_bin, "devices", "-l"], timeout=3.0)
    if rc != 0:
        return devices

    for line in out.splitlines()[1:]:
        line = line.strip()
        if not line:
            continue
        parts = line.split()
        if len(parts) < 2:
            continue
        serial = parts[0]
        state = parts[1]
        meta = {}
        for token in parts[2:]:
            if ":" in token:
                k, v = token.split(":", 1)
                meta[k] = v

        is_emulator = serial.startswith("emulator-")
        avd_name = ""
        boot_completed = False
        ui_night = ""
        layout_bounds = False
        android_version = ""

        if state == "device":
            probe_cmd = (
                "getprop ro.boot.qemu.avd_name; echo '___SEP___'; "
                "getprop sys.boot_completed; echo '___SEP___'; "
                "getprop ro.build.version.release; echo '___SEP___'; "
                "getprop debug.layout; echo '___SEP___'; "
                "cmd uimode night 2>/dev/null || true"
            )
            _, probe_out, _ = run_cmd([adb_bin, "-s", serial, "shell", probe_cmd], timeout=2.0)
            segs = [s.strip() for s in probe_out.split("___SEP___")]
            if len(segs) >= 1:
                avd_name = segs[0]
            if is_emulator and not avd_name:
                _, emu_out, _ = run_cmd([adb_bin, "-s", serial, "emu", "avd", "name"], timeout=1.5)
                first_line = (emu_out.splitlines() or [""])[0].strip()
                if first_line and first_line != "OK" and "error" not in first_line.lower():
                    avd_name = first_line
            if len(segs) >= 2:
                boot_completed = segs[1] == "1"
            if len(segs) >= 3:
                android_version = segs[2]
            if len(segs) >= 4:
                layout_bounds = segs[3].lower() == "true"
            if len(segs) >= 5:
                night_out = segs[4].lower()
                if "yes" in night_out:
                    ui_night = "dark"
                elif "no" in night_out:
                    ui_night = "light"

        devices.append({
            "serial": serial,
            "state": state,
            "is_emulator": is_emulator,
            "avd_name": avd_name,
            "model": meta.get("model", serial).replace("_", " "),
            "product": meta.get("product", ""),
            "boot_completed": boot_completed,
            "android_version": android_version,
            "ui_mode": ui_night,
            "layout_bounds": layout_bounds,
        })
    return devices


def format_target_label(target: str) -> str:
    if not target:
        return "Android"
    m = re.match(r"android-(\d+(?:\.\d+)?)", target)
    if m:
        return f"API {m.group(1)}"
    return target


def list_avds(paths: dict, running_procs: dict, adb_devices: list) -> list:
    avd_dir = avd_home_dir()
    avd_map = {}

    if avd_dir.is_dir():
        for ini_path in sorted(avd_dir.glob("*.ini")):
            avd_id = ini_path.stem
            root_ini = parse_ini_file(ini_path)
            rel_or_abs = root_ini.get("path", "")
            avd_folder = Path(rel_or_abs) if rel_or_abs else (avd_dir / f"{avd_id}.avd")
            if not avd_folder.is_absolute():
                avd_folder = avd_dir / avd_folder
            avd_map[avd_id] = {
                "avd_id": avd_id,
                "root_ini": root_ini,
                "avd_folder": avd_folder,
            }

    # Also consult emulator -list-avds to make sure nothing is missed
    if paths.get("emulator_bin"):
        rc, out, _ = run_cmd([paths["emulator_bin"], "-list-avds"], timeout=3.0, env=sdk_env(paths))
        if rc == 0:
            for line in out.splitlines():
                name = line.strip()
                if name and name not in avd_map:
                    avd_map[name] = {
                        "avd_id": name,
                        "root_ini": {},
                        "avd_folder": avd_dir / f"{name}.avd",
                    }

    adb_by_avd = {d["avd_name"]: d for d in adb_devices if d.get("avd_name")}
    result = []

    for avd_id in sorted(avd_map.keys()):
        entry = avd_map[avd_id]
        folder = entry["avd_folder"]
        cfg = parse_ini_file(folder / "config.ini")
        root_ini = entry["root_ini"]

        proc_info = running_procs.get(avd_id)
        adb_info = adb_by_avd.get(avd_id)
        running = proc_info is not None or adb_info is not None

        locks = []
        if folder.is_dir():
            for lock_name in ("hardware-qemu.ini.lock", "multiinstance.lock", "userdata-qemu.img.lock"):
                if (folder / lock_name).exists():
                    locks.append(lock_name)

        ram_mb = int(cfg.get("hw.ramSize", "2048") or 2048) if str(cfg.get("hw.ramSize", "2048")).isdigit() else 2048
        cores = int(cfg.get("hw.cpu.ncore", "2") or 2) if str(cfg.get("hw.cpu.ncore", "2")).isdigit() else 2
        width = int(cfg.get("hw.lcd.width", "1080") or 1080) if str(cfg.get("hw.lcd.width", "1080")).isdigit() else 1080
        height = int(cfg.get("hw.lcd.height", "2400") or 2400) if str(cfg.get("hw.lcd.height", "2400")).isdigit() else 2400
        density = int(cfg.get("hw.lcd.density", "420") or 420) if str(cfg.get("hw.lcd.density", "420")).isdigit() else 420

        target = cfg.get("target") or root_ini.get("target", "")
        display_name = cfg.get("avd.ini.displayname") or avd_id.replace("_", " ")

        result.append({
            "id": avd_id,
            "display_name": display_name,
            "target": target,
            "target_label": format_target_label(target),
            "abi": cfg.get("abi.type", cfg.get("hw.cpu.arch", "x86_64")),
            "play_store": cfg.get("PlayStore.enabled", "false").lower() == "true",
            "ram_mb": ram_mb,
            "cpu_cores": cores,
            "gpu_mode": cfg.get("hw.gpu.mode", "auto"),
            "gpu_enabled": cfg.get("hw.gpu.enabled", "yes").lower() == "yes",
            "width": width,
            "height": height,
            "density": density,
            "disk_size": cfg.get("disk.dataPartition.size", "10G"),
            "heap_size": cfg.get("vm.heapSize", "228"),
            "device_frame": cfg.get("showDeviceFrame", "yes").lower() == "yes",
            "keyboard": cfg.get("hw.keyboard", "yes").lower() == "yes",
            "cold_boot": cfg.get("fastboot.forceColdBoot", "no").lower() == "yes",
            "fast_boot": cfg.get("fastboot.forceFastBoot", "yes").lower() == "yes",
            "running": running,
            "pid": proc_info["pid"] if proc_info else 0,
            "hidden_window": proc_info["hidden_window"] if proc_info else False,
            "serial": adb_info["serial"] if adb_info else "",
            "adb_state": adb_info["state"] if adb_info else "",
            "boot_completed": adb_info["boot_completed"] if adb_info else False,
            "android_version": adb_info["android_version"] if adb_info else "",
            "ui_mode": adb_info["ui_mode"] if adb_info else "",
            "layout_bounds": adb_info["layout_bounds"] if adb_info else False,
            "stale_locks": (not running) and len(locks) > 0,
            "config_path": str(folder / "config.ini"),
        })

    return result


def cmd_status(custom_sdk: str = "") -> dict:
    paths = resolve_sdk_paths(custom_sdk)
    running_procs = get_running_emulator_procs()
    adb_devices = get_adb_devices(paths["adb_bin"])
    avds = list_avds(paths, running_procs, adb_devices)
    return {
        "ok": True,
        "paths": paths,
        "avds": avds,
        "adb_devices": adb_devices,
        "running_count": sum(1 for a in avds if a["running"]),
        "device_count": len([d for d in adb_devices if d["state"] == "device"]),
    }


def clean_avd_locks(avd_id: str) -> list:
    avd_folder = avd_home_dir() / f"{avd_id}.avd"
    removed = []
    if not avd_folder.is_dir():
        return removed
    for lock_file in avd_folder.glob("*.lock"):
        try:
            if lock_file.is_dir():
                shutil.rmtree(lock_file, ignore_errors=True)
            else:
                lock_file.unlink()
            removed.append(lock_file.name)
        except Exception:
            pass
    return removed


def cmd_launch(avd_id: str, mode: str = "normal", custom_sdk: str = "") -> dict:
    paths = resolve_sdk_paths(custom_sdk)
    emu_bin = paths.get("emulator_bin", "")
    if not emu_bin:
        return {"ok": False, "error": "No se encontró el binario 'emulator' en el Android SDK"}

    running_procs = get_running_emulator_procs()
    if avd_id in running_procs:
        return {"ok": False, "error": f"El emulador {avd_id} ya está en ejecución (PID {running_procs[avd_id]['pid']})"}

    clean_avd_locks(avd_id)
    ensure_emulator_conf(paths)

    cmd = [emu_bin, "-avd", avd_id, "-feature", "ClipboardSharing"]
    if mode == "cold":
        cmd.append("-no-snapshot-load")
    elif mode == "wipe":
        cmd.extend(["-wipe-data", "-no-snapshot-load"])
    elif mode == "no-window":
        cmd.append("-no-window")

    log_dir = Path("/tmp") / f"dms-android-emulator-{os.getuid()}"
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / f"{avd_id}.log"

    env = sdk_env(paths)
    with log_file.open("ab") as lf:
        lf.write(f"\n--- Launch {avd_id} ({mode}) at {datetime.now().isoformat()} ---\n".encode())
        proc = subprocess.Popen(
            cmd,
            stdout=lf,
            stderr=lf,
            stdin=subprocess.DEVNULL,
            env=env,
            start_new_session=True,
        )

    return {
        "ok": True,
        "avd_id": avd_id,
        "mode": mode,
        "pid": proc.pid,
        "log_file": str(log_file),
    }


def cmd_stop(target: str, custom_sdk: str = "") -> dict:
    paths = resolve_sdk_paths(custom_sdk)
    adb_bin = paths.get("adb_bin", "")
    running_procs = get_running_emulator_procs()
    adb_devices = get_adb_devices(adb_bin)

    serial = ""
    avd_id = target

    if target.startswith("emulator-"):
        serial = target
        for d in adb_devices:
            if d["serial"] == serial and d.get("avd_name"):
                avd_id = d["avd_name"]
                break
    else:
        for d in adb_devices:
            if d.get("avd_name") == target:
                serial = d["serial"]
                break

    killed_via = []
    if serial and adb_bin:
        rc, _, _ = run_cmd([adb_bin, "-s", serial, "emu", "kill"], timeout=3.0)
        if rc == 0:
            killed_via.append("adb-emu-kill")

    proc_info = running_procs.get(avd_id)
    if proc_info and proc_info.get("pid"):
        pid = proc_info["pid"]
        # Give adb emu kill a brief moment if used, otherwise SIGTERM
        if killed_via:
            time.sleep(0.5)
        try:
            os.kill(pid, 0)
            os.kill(pid, signal.SIGTERM)
            killed_via.append(f"sigterm:{pid}")
        except ProcessLookupError:
            pass
        except Exception:
            pass

    if not killed_via:
        return {"ok": False, "error": f"No se encontró instancia activa para {target}"}

    return {"ok": True, "target": target, "avd_id": avd_id, "serial": serial, "method": killed_via}


def cmd_update_config(avd_id: str, json_payload: str) -> dict:
    try:
        patch = json.loads(json_payload)
    except Exception as exc:
        return {"ok": False, "error": f"JSON inválido: {exc}"}

    cfg_path = avd_home_dir() / f"{avd_id}.avd" / "config.ini"
    if not cfg_path.is_file():
        return {"ok": False, "error": f"No existe config.ini para {avd_id}"}

    updates = {}
    if "ram_mb" in patch:
        ram = max(512, min(32768, int(patch["ram_mb"])))
        updates["hw.ramSize"] = str(ram)
    if "cpu_cores" in patch:
        cores = max(1, min(16, int(patch["cpu_cores"])))
        updates["hw.cpu.ncore"] = str(cores)
    if "gpu_mode" in patch:
        mode = str(patch["gpu_mode"])
        if mode in ("auto", "host", "swiftshader_indirect", "angle_indirect", "off"):
            updates["hw.gpu.mode"] = mode
            updates["hw.gpu.enabled"] = "no" if mode == "off" else "yes"
    if "device_frame" in patch:
        updates["showDeviceFrame"] = "yes" if patch["device_frame"] else "no"
    if "keyboard" in patch:
        updates["hw.keyboard"] = "yes" if patch["keyboard"] else "no"
    if "cold_boot" in patch:
        is_cold = bool(patch["cold_boot"])
        updates["fastboot.forceColdBoot"] = "yes" if is_cold else "no"
        updates["fastboot.forceFastBoot"] = "no" if is_cold else "yes"
    if "display_name" in patch and str(patch["display_name"]).strip():
        updates["avd.ini.displayname"] = str(patch["display_name"]).strip()

    if not updates:
        return {"ok": False, "error": "No hay cambios válidos para guardar"}

    ok = update_ini_file(cfg_path, updates)
    return {"ok": ok, "avd_id": avd_id, "updated": updates}


def find_terminal_command(shell_cmd: str) -> list:
    for term in ("kitty", "alacritty", "foot", "wezterm", "ghostty", "konsole", "gnome-terminal"):
        path = shutil.which(term)
        if not path:
            continue
        if term == "wezterm":
            return [path, "start", "--", "sh", "-c", shell_cmd]
        if term == "gnome-terminal":
            return [path, "--", "sh", "-c", shell_cmd]
        return [path, "-e", "sh", "-c", shell_cmd]
    xdg_term = shutil.which("xdg-terminal-exec")
    if xdg_term:
        return [xdg_term, "sh", "-c", shell_cmd]
    return []


def pick_apk_file() -> str:
    home = Path.home()
    start_dir = home / "Descargas"
    if not start_dir.is_dir():
        start_dir = home / "Downloads" if (home / "Downloads").is_dir() else home

    if shutil.which("zenity"):
        proc = subprocess.run(
            [
                "zenity",
                "--file-selection",
                "--title=Seleccionar archivo APK",
                f"--filename={start_dir}/",
                "--file-filter=Paquetes Android (*.apk) | *.apk *.APK",
                "--file-filter=Todos los archivos | *",
            ],
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()
        return ""

    if shutil.which("kdialog"):
        proc = subprocess.run(
            [
                "kdialog",
                "--getopenfilename",
                str(start_dir),
                "*.apk *.APK|Paquetes Android (*.apk)",
            ],
            capture_output=True,
            text=True,
        )
        if proc.returncode == 0 and proc.stdout.strip():
            return proc.stdout.strip()
        return ""

    try:
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk

        dialog = Gtk.FileChooserDialog(
            title="Seleccionar archivo APK",
            parent=None,
            action=Gtk.FileChooserAction.OPEN,
        )
        dialog.add_buttons(
            Gtk.STOCK_CANCEL, Gtk.ResponseType.CANCEL,
            "Seleccionar", Gtk.ResponseType.OK,
        )
        dialog.set_current_folder(str(start_dir))
        flt = Gtk.FileFilter()
        flt.set_name("Paquetes Android (*.apk)")
        flt.add_pattern("*.apk")
        flt.add_pattern("*.APK")
        dialog.add_filter(flt)
        chosen = ""
        if dialog.run() == Gtk.ResponseType.OK:
            chosen = dialog.get_filename() or ""
        dialog.destroy()
        while Gtk.events_pending():
            Gtk.main_iteration()
        return chosen
    except Exception:
        return ""


def cmd_adb_action(serial: str, action: str, arg: str = "", custom_sdk: str = "") -> dict:
    paths = resolve_sdk_paths(custom_sdk)
    adb_bin = paths.get("adb_bin", "")
    scrcpy_bin = paths.get("scrcpy_bin", "")
    if not adb_bin:
        return {"ok": False, "error": "No se encontró 'adb'"}

    if action == "kill-server":
        run_cmd([adb_bin, "kill-server"], timeout=3.0)
        rc, out, err = run_cmd([adb_bin, "start-server"], timeout=5.0)
        return {"ok": rc == 0, "message": "Servidor ADB reiniciado", "output": (out + err).strip()}

    if action == "connect":
        if not arg:
            return {"ok": False, "error": "Indica una dirección IP:PUERTO"}
        rc, out, err = run_cmd([adb_bin, "connect", arg], timeout=5.0)
        msg = (out + err).strip()
        return {"ok": rc == 0 and "connected" in msg.lower(), "message": msg}

    if action == "disconnect":
        cmd = [adb_bin, "disconnect", arg] if arg else [adb_bin, "disconnect"]
        rc, out, err = run_cmd(cmd, timeout=4.0)
        return {"ok": rc == 0, "message": (out + err).strip() or "Desconectado"}

    if not serial:
        return {"ok": False, "error": "No hay dispositivo seleccionado"}

    if action == "scrcpy":
        if not scrcpy_bin:
            return {"ok": False, "error": "scrcpy no está instalado en el sistema"}
        subprocess.Popen(
            [scrcpy_bin, "-s", serial, "--window-title", f"Android ({serial})"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
        return {"ok": True, "message": f"Abriendo scrcpy para {serial}"}

    if action == "screenshot":
        pic_dir = Path.home() / "Imágenes" / "Screenshots"
        if not (Path.home() / "Imágenes").exists():
            pic_dir = Path.home() / "Pictures" / "Screenshots"
        pic_dir.mkdir(parents=True, exist_ok=True)
        fname = f"android_{serial}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.png"
        out_path = pic_dir / fname
        try:
            proc = subprocess.run([adb_bin, "-s", serial, "exec-out", "screencap", "-p"], capture_output=True, timeout=6.0)
            if proc.returncode != 0 or not proc.stdout:
                return {"ok": False, "error": "Error al capturar pantalla del dispositivo"}
            out_path.write_bytes(proc.stdout)
            if shutil.which("wl-copy"):
                subprocess.run(["wl-copy", "--type", "image/png"], input=proc.stdout, timeout=2.0)
            return {"ok": True, "path": str(out_path), "message": f"Captura guardada en {out_path.name}"}
        except Exception as exc:
            return {"ok": False, "error": str(exc)}

    if action == "keyevent":
        key_map = {
            "HOME": "3",
            "BACK": "4",
            "CALL": "5",
            "ENDCALL": "6",
            "DPAD_UP": "19",
            "DPAD_DOWN": "20",
            "VOL_UP": "24",
            "VOL_DOWN": "25",
            "POWER": "26",
            "CAMERA": "27",
            "MENU": "82",
            "RECENTS": "187",
            "ROTATE": "28",
        }
        code = key_map.get(arg.upper(), arg)
        rc, _, err = run_cmd([adb_bin, "-s", serial, "shell", "input", "keyevent", str(code)], timeout=3.0)
        return {"ok": rc == 0, "message": f"Tecla {arg} enviada" if rc == 0 else err}

    if action == "input-text":
        if not arg:
            return {"ok": False, "error": "Texto vacío"}
        # Escape spaces for adb shell input text
        escaped = arg.replace("\\", "\\\\").replace(" ", "%s").replace("'", "\\'")
        rc, _, err = run_cmd([adb_bin, "-s", serial, "shell", "input", "text", escaped], timeout=3.0)
        return {"ok": rc == 0, "message": "Texto enviado al dispositivo" if rc == 0 else err}

    if action == "paste-clipboard":
        clip_text = ""
        if shutil.which("wl-paste"):
            _, out, _ = run_cmd(["wl-paste", "--no-newline"], timeout=2.0)
            clip_text = out
        if not clip_text and shutil.which("xclip"):
            _, out, _ = run_cmd(["xclip", "-selection", "clipboard", "-o"], timeout=2.0)
            clip_text = out
        if not clip_text:
            return {"ok": False, "error": "El portapapeles está vacío"}
        first_line = clip_text.splitlines()[0].strip()
        if not first_line:
            return {"ok": False, "error": "El portapapeles no contiene texto"}
        escaped = first_line.replace("\\", "\\\\").replace(" ", "%s").replace("'", "\\'")
        rc, _, err = run_cmd([adb_bin, "-s", serial, "shell", "input", "text", escaped], timeout=4.0)
        return {"ok": rc == 0, "message": "Portapapeles pegado en el emulador" if rc == 0 else err}

    if action == "toggle-dark":
        _, night_out, _ = run_cmd([adb_bin, "-s", serial, "shell", "cmd", "uimode", "night"], timeout=2.0)
        next_val = "no" if "yes" in night_out.lower() else "yes"
        rc, _, err = run_cmd([adb_bin, "-s", serial, "shell", "cmd", "uimode", "night", next_val], timeout=3.0)
        label = "Modo Oscuro activado" if next_val == "yes" else "Modo Claro activado"
        return {"ok": rc == 0, "message": label if rc == 0 else err}

    if action == "toggle-bounds":
        _, cur_out, _ = run_cmd([adb_bin, "-s", serial, "shell", "getprop", "debug.layout"], timeout=2.0)
        next_val = "false" if cur_out.strip().lower() == "true" else "true"
        run_cmd([adb_bin, "-s", serial, "shell", "setprop", "debug.layout", next_val], timeout=2.0)
        run_cmd([adb_bin, "-s", serial, "shell", "service", "call", "activity", "1599295570"], timeout=2.0)
        label = "Layout Bounds activado" if next_val == "true" else "Layout Bounds desactivado"
        return {"ok": True, "message": label}

    if action == "shell":
        cmd_str = f"{shlex.quote(adb_bin)} -s {shlex.quote(serial)} shell"
        term_cmd = find_terminal_command(cmd_str)
        if not term_cmd:
            return {"ok": False, "error": "No se encontró terminal compatible para abrir adb shell"}
        subprocess.Popen(term_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return {"ok": True, "message": f"Terminal adb shell abierta para {serial}"}

    if action == "logcat":
        cmd_str = f"{shlex.quote(adb_bin)} -s {shlex.quote(serial)} logcat -v color"
        term_cmd = find_terminal_command(cmd_str)
        if not term_cmd:
            return {"ok": False, "error": "No se encontró terminal compatible para abrir logcat"}
        subprocess.Popen(term_cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
        return {"ok": True, "message": f"Logcat abierto para {serial}"}

    if action == "install-apk":
        raw_arg = arg.strip()
        if not raw_arg:
            picked = pick_apk_file()
            if not picked:
                return {"ok": False, "cancelled": True, "message": ""}
            apk_path = os.path.expanduser(picked)
        else:
            apk_path = os.path.expanduser(raw_arg)
        if not apk_path or not os.path.isfile(apk_path):
            return {"ok": False, "error": f"No existe el archivo APK: {apk_path}"}
        rc, out, err = run_cmd([adb_bin, "-s", serial, "install", "-r", apk_path], timeout=90.0)
        return {
            "ok": rc == 0,
            "path": apk_path,
            "message": f"APK instalado: {Path(apk_path).name}" if rc == 0 else ((out + err).strip() or "Error al instalar APK"),
        }

    if action == "reboot":
        rc, out, err = run_cmd([adb_bin, "-s", serial, "reboot"], timeout=4.0)
        return {"ok": rc == 0, "message": f"Reiniciando {serial}" if rc == 0 else err}

    return {"ok": False, "error": f"Acción desconocida: {action}"}


def main():
    args = sys.argv[1:]
    custom_sdk = ""
    if len(args) >= 2 and args[0] == "--sdk":
        custom_sdk = args[1]
        args = args[2:]

    if not args or args[0] == "status":
        res = cmd_status(custom_sdk)
    elif args[0] == "launch" and len(args) >= 2:
        mode = args[2] if len(args) >= 3 else "normal"
        res = cmd_launch(args[1], mode, custom_sdk)
    elif args[0] == "stop" and len(args) >= 2:
        res = cmd_stop(args[1], custom_sdk)
    elif args[0] == "clean-locks" and len(args) >= 2:
        removed = clean_avd_locks(args[1])
        res = {"ok": True, "avd_id": args[1], "removed": removed}
    elif args[0] == "update-config" and len(args) >= 3:
        res = cmd_update_config(args[1], args[2])
    elif args[0] == "pick-apk":
        picked = pick_apk_file()
        res = {"ok": bool(picked), "cancelled": not bool(picked), "path": picked}
    elif args[0] == "adb-action" and len(args) >= 3:
        extra = args[3] if len(args) >= 4 else ""
        res = cmd_adb_action(args[1], args[2], extra, custom_sdk)
    else:
        res = {"ok": False, "error": "Uso: avd_helper.py [--sdk RUTA] [status|launch|stop|clean-locks|update-config|adb-action] ..."}

    print(json.dumps(res, ensure_ascii=False))


if __name__ == "__main__":
    main()
