import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
import bridge


class FakeBridge(bridge.Bridge):
    def __init__(self, root=None, online=True, mount_ok=True):
        self.root = root
        self.online = online
        self.mount_ok = mount_ok
        self.calls = []

    def props(self, path, interface):
        if interface == bridge.IFACE:
            return {"isPaired": True, "isReachable": self.online}
        return {"playerList": ["Music"]}

    def call(self, path, interface, method, signature=None, args=(), timeout=3000):
        self.calls.append((method, args))
        return {"mountAndWait": (self.mount_ok,), "getMountError": ("Phone denied access",),
                "getDirectories": ({str(self.root): "Shared files"},),
                "mountPoint": (str(self.root),)}.get(method, ())


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.dependencies = patch("bridge.dependencies", return_value={name: True for name in (
            "kdeconnect", "sshfs", "kio-fuse", "nautilus", "python-gobject", "omarchy-file-select")})
        self.dependencies.start()
        self.addCleanup(self.dependencies.stop)

    def test_missing_sshfs_blocks_mount_before_dbus(self):
        with patch("bridge.dependencies", return_value={"sshfs": False, "kio-fuse": True, "nautilus": True}):
            b = FakeBridge()
            with self.assertRaisesRegex(ValueError, "sshfs"):
                b.mount("phone", "files")
            self.assertEqual(b.calls, [])

    def test_missing_kio_fuse_identified_separately(self):
        with patch("bridge.dependencies", return_value={"sshfs": True, "kio-fuse": False, "nautilus": True}):
            with self.assertRaisesRegex(ValueError, "kio-fuse"):
                FakeBridge().mount("phone", "files")

    def test_device_path_rejects_traversal(self):
        for device in ("../phone", "a/b", "", "$(echo bad)"):
            with self.assertRaises(ValueError): bridge.path_for(device)

    def test_offline_blocks_actions(self):
        b = FakeBridge(online=False)
        with self.assertRaisesRegex(ValueError, "offline"): b.action("ring", "phone")
        self.assertEqual(b.calls, [])

    def test_mount_uses_advertised_share(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(Path, "is_mount", return_value=True):
            (Path(tmp) / "DCIM").mkdir()
            self.assertEqual(FakeBridge(tmp).mount("phone", "photos"), Path(tmp) / "DCIM")

    def test_failed_mount_does_not_open_files(self):
        b = FakeBridge(mount_ok=False)
        with patch("bridge.subprocess.Popen") as launch:
            with self.assertRaisesRegex(ValueError, "denied"): b.action("files", "phone")
            launch.assert_not_called()

    def test_missing_folder_is_actionable(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(Path, "is_mount", return_value=True):
            with self.assertRaisesRegex(ValueError, "Try Browse files"):
                FakeBridge(tmp).mount("phone", "documents")

    def test_symlink_outside_share_rejected(self):
        with tempfile.TemporaryDirectory() as tmp, patch.object(Path, "is_mount", return_value=True):
            (Path(tmp) / "DCIM").symlink_to("/tmp", target_is_directory=True)
            with self.assertRaisesRegex(ValueError, "not shared"):
                FakeBridge(tmp).mount("phone", "photos")

    def test_unmounted_path_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(ValueError, "not mounted"):
                FakeBridge(tmp).mount("phone", "files")

    def test_volume_clamped(self):
        b = FakeBridge()
        b.action("volume", "phone", "200")
        self.assertEqual(b.calls[-1][1][2].unpack(), 100)
        b.action("volume", "phone", "-15")
        self.assertEqual(b.calls[-1][1][2].unpack(), 0)

    def test_player_must_be_available(self):
        b = FakeBridge()
        with self.assertRaisesRegex(ValueError, "no longer available"):
            b.action("player", "phone", "Gone")
        self.assertEqual(b.calls, [])

    def test_invalid_media_action_rejected(self):
        with self.assertRaisesRegex(ValueError, "Unknown media"):
            FakeBridge().action("media", "phone", "Anything")

    def test_playback_action_uses_dbus_argument(self):
        b = FakeBridge()
        b.action("media", "phone", "PlayPause")
        self.assertEqual(b.calls, [("sendAction", ("PlayPause",))])

    def test_cancelled_picker_sends_nothing(self):
        b = FakeBridge()
        with patch("bridge.subprocess.run") as picker:
            picker.return_value.returncode = 1
            self.assertEqual(b.action("share", "phone"), "Nothing sent")
        self.assertEqual(b.calls, [])


class DependencyTests(unittest.TestCase):
    def test_kio_fuse_detected_outside_path(self):
        with patch("bridge.shutil.which", return_value=None), \
             patch("bridge.os.path.isfile", side_effect=lambda p: p == "/usr/lib/kio-fuse"), \
             patch("bridge.os.access", return_value=True):
            result = bridge.dependencies()
            self.assertTrue(result["kio-fuse"])
            self.assertFalse(result["sshfs"])

    def test_non_executable_kio_fuse_not_accepted(self):
        with patch("bridge.shutil.which", return_value=None), \
             patch("bridge.os.path.isfile", return_value=True), \
             patch("bridge.os.access", return_value=False):
            self.assertFalse(bridge.dependencies()["kio-fuse"])


if __name__ == "__main__":
    unittest.main()
