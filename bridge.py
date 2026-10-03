#!/usr/bin/env python3
"""Small, stateless KDE Connect adapter. JSON on stdout; no shell execution."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
try:
    import gi
    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib
except (ImportError, ValueError):
    Gio = GLib = None

BRIDGE_ERRORS = (OSError, ValueError, subprocess.SubprocessError) + ((GLib.Error,) if GLib else ())

BUS = "org.kde.kdeconnect"
ROOT = "/modules/kdeconnect"
IFACE = BUS + ".device"
PROPS = "org.freedesktop.DBus.Properties"
FOLDERS = {"files": "", "photos": "DCIM", "downloads": "Download", "documents": "Documents"}


def dependencies():
    """Check executables, including KIO FUSE's usual non-PATH install location."""
    kio_fuse = bool(shutil.which("kio-fuse")) or any(
        os.path.isfile(path) and os.access(path, os.X_OK)
        for path in ("/usr/lib/kio-fuse", "/usr/libexec/kio-fuse"))
    return {"kdeconnect": bool(shutil.which("kdeconnect-cli")),
            "sshfs": bool(shutil.which("sshfs")), "kio-fuse": kio_fuse,
            "nautilus": bool(shutil.which("nautilus")),
            "python-gobject": Gio is not None,
            "omarchy-file-select": bool(shutil.which("omarchy-file-select"))}


def require_dependencies(*packages):
    installed = dependencies()
    missing = [name for name in packages if not installed.get(name)]
    if missing:
        raise ValueError("Missing runtime dependencies: " + ", ".join(missing)
                         + ". Install them, then refresh the panel.")


def path_for(device):
    if not re.fullmatch(r"[A-Za-z0-9_]+", device):
        raise ValueError("Invalid device identifier")
    return ROOT + "/devices/" + device


class Bridge:
    def __init__(self):
        require_dependencies("python-gobject", "kdeconnect")
        self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)

    def call(self, path, interface, method, signature=None, args=(), timeout=3000):
        value = GLib.Variant(signature, args) if signature else None
        return self.bus.call_sync(BUS, path, interface, method, value, None,
                                 Gio.DBusCallFlags.NONE, timeout, None).unpack()

    def props(self, path, interface):
        return self.call(path, PROPS, "GetAll", "(s)", (interface,))[0]

    def optional_props(self, path, interface):
        try:
            return self.props(path, interface)
        except GLib.Error:
            return {}

    def snapshot(self):
        ids = self.call(ROOT, BUS + ".daemon", "devices", "(bb)", (False, True))[0]
        devices = []
        for device in ids:
            path = path_for(device)
            try:
                p = self.props(path, IFACE)
            except GLib.Error:
                continue
            online = bool(p.get("isReachable") and p.get("isPaired"))
            d = {"id": device, "name": p.get("name", "Phone"), "online": online,
                 "links": p.get("activeProviderNames", []), "battery": -1,
                 "charging": False, "can": [], "media": {}, "notifications": []}
            if online:
                d["can"] = self.call(path, IFACE, "loadedPlugins")[0]
                b = self.optional_props(path + "/battery", IFACE + ".battery")
                if b.get("hasBattery"):
                    d.update(battery=b.get("charge", -1), charging=b.get("isCharging", False))
                d["media"] = self.optional_props(path + "/mprisremote", IFACE + ".mprisremote")
                if "kdeconnect_notifications" in d["can"]:
                    try:
                        notes = self.call(path + "/notifications", IFACE + ".notifications", "activeNotifications")[0]
                        for nid in reversed(notes):
                            if not re.fullmatch(r"[A-Za-z0-9_]+", nid):
                                continue
                            n = self.optional_props(path + "/notifications/" + nid, IFACE + ".notifications.notification")
                            if n:
                                d["notifications"].append({"id": nid, "app": n.get("appName", "Phone"),
                                    "title": n.get("title", ""), "body": n.get("text", ""),
                                    "dismissable": bool(n.get("dismissable", False))})
                    except GLib.Error:
                        pass
            devices.append(d)
        devices.sort(key=lambda d: (not d["online"], d["name"].casefold()))
        return {"ok": True, "devices": devices}

    def require_online(self, device):
        path = path_for(device)
        p = self.props(path, IFACE)
        if not p.get("isPaired") or not p.get("isReachable"):
            raise ValueError("Phone is offline. Open KDE Connect on your phone and check its connection.")
        return path

    def mount(self, device, folder):
        # Both are required by this plugin's supported Omarchy/Nautilus setup.
        # SSHFS performs this mount; KIO FUSE supports KDE's separate URL handoff.
        require_dependencies("sshfs", "kio-fuse", "nautilus")
        path = self.require_online(device) + "/sftp"
        if folder not in FOLDERS:
            raise ValueError("Unknown folder")
        if not self.call(path, IFACE + ".sftp", "mountAndWait", timeout=25000)[0]:
            error = self.call(path, IFACE + ".sftp", "getMountError")[0]
            raise ValueError(error or "Could not mount phone storage")
        # Use the advertised share, never a hardcoded Android storage path or KIO URL.
        shares = self.call(path, IFACE + ".sftp", "getDirectories")[0]
        if not shares:
            raise ValueError("No folders shared. Enable Filesystem expose in the phone's KDE Connect settings.")
        mount = Path(self.call(path, IFACE + ".sftp", "mountPoint")[0]).resolve()
        roots = sorted(Path(s).resolve() for s in shares)
        root = next((s for s in roots if str(s).endswith("/storage/emulated/0")), roots[0])
        if not root.is_relative_to(mount) or not mount.is_mount():
            raise ValueError("Phone storage is not mounted")
        target = (root / FOLDERS[folder]).resolve()
        if not target.is_relative_to(root) or not target.is_dir():
            raise ValueError("This folder is not shared by your phone. Try Browse files.")
        return target

    def action(self, verb, device, value=""):
        path = self.require_online(device)
        if verb in FOLDERS:
            target = self.mount(device, verb)
            subprocess.Popen(["nautilus", "--new-window", str(target)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
            return "Opened phone " + ("storage" if verb == "files" else verb)
        if verb == "ring":
            self.call(path + "/findmyphone", IFACE + ".findmyphone", "ring")
            return "Ring request sent"
        if verb == "clipboard":
            self.call(path + "/clipboard", IFACE + ".clipboard", "sendClipboard")
            return "Clipboard sent to phone"
        if verb == "share":
            require_dependencies("omarchy-file-select")
            picker = subprocess.run(["omarchy-file-select", "--title", "Send a file to your phone"], capture_output=True, text=True, timeout=600)
            if picker.returncode == 1:
                return "Nothing sent"
            if picker.returncode:
                raise ValueError("Could not open the file chooser")
            filename = picker.stdout.rstrip("\n")
            if not filename:
                return "Nothing sent"
            if not Path(filename).is_file():
                raise ValueError("Select a regular file")
            self.require_online(device)
            uri = Gio.File.new_for_path(filename).get_uri()
            self.call(path + "/share", IFACE + ".share", "shareUrl", "(s)", (uri,))
            return "File handed to KDE Connect for transfer"
        if verb == "dismiss":
            if not re.fullmatch(r"[A-Za-z0-9_]+", value):
                raise ValueError("Invalid notification")
            self.call(path + "/notifications/" + value, IFACE + ".notifications.notification", "dismiss")
            return "Notification dismissed"
        media_path, media_iface = path + "/mprisremote", IFACE + ".mprisremote"
        if verb == "player":
            players = self.props(media_path, media_iface).get("playerList", [])
            if value not in players:
                raise ValueError("Player is no longer available")
            self.call(media_path, PROPS, "Set", "(ssv)", (media_iface, "player", GLib.Variant("s", value)))
            return "Player selected"
        if verb == "media":
            if value not in ("PlayPause", "Next", "Previous"):
                raise ValueError("Unknown media action")
            self.call(media_path, media_iface, "sendAction", "(s)", (value,))
            return "Playback request sent"
        if verb == "volume":
            volume = max(0, min(100, int(value)))
            self.call(media_path, PROPS, "Set", "(ssv)", (media_iface, "volume", GLib.Variant("i", volume)))
            return "Phone volume updated"
        raise ValueError("Unknown action")


def main():
    installed = dependencies()
    try:
        if len(sys.argv) > 1 and sys.argv[1] == "check-dependencies":
            result = {"ok": all(installed.values())}
        else:
            bridge = Bridge()
            if len(sys.argv) == 1 or sys.argv[1] == "snapshot":
                result = bridge.snapshot()
            elif sys.argv[1] == "check-mount" and len(sys.argv) == 3:
                result = {"ok": True, "path": str(bridge.mount(sys.argv[2], "files"))}
            elif len(sys.argv) in (3, 4):
                result = {"ok": True, "message": bridge.action(*sys.argv[1:])}
            else:
                raise ValueError("Usage: bridge.py [snapshot|check-dependencies|check-mount DEVICE|ACTION DEVICE [VALUE]]")
    except BRIDGE_ERRORS as error:
        result = {"ok": False, "error": str(error), "devices": []}
    result["dependencies"] = installed
    print(json.dumps(result), flush=True)
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
