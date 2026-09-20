import json
import os
import stat
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import app


class UrlValidationTests(unittest.TestCase):
    def test_accepts_supported_youtube_urls(self):
        self.assertEqual(
            app.validate_youtube_url("https://youtu.be/abc123"),
            "https://youtu.be/abc123",
        )
        self.assertIsNotNone(app.validate_youtube_url("https://www.youtube.com/watch?v=abc123"))

    def test_rejects_other_hosts_and_credentials(self):
        self.assertIsNone(app.validate_youtube_url("https://example.com/watch?v=abc"))
        self.assertIsNone(app.validate_youtube_url("https://youtube.com@example.com/video"))
        self.assertIsNone(app.validate_youtube_url("javascript:alert(1)"))


class RemoteAuthorizationTests(unittest.TestCase):
    def test_loopback_never_requires_token(self):
        self.assertTrue(app.remote_request_is_authorized("127.0.0.1", None))
        self.assertTrue(app.remote_request_is_authorized("::1", None))

    def test_remote_client_requires_matching_token(self):
        with mock.patch.dict(os.environ, {"MY_MP3_REMOTE_TOKEN": "personal-token"}):
            self.assertTrue(app.remote_request_is_authorized("192.168.0.10", "personal-token"))
            self.assertFalse(app.remote_request_is_authorized("192.168.0.10", "wrong-token"))
            self.assertFalse(app.remote_request_is_authorized("192.168.0.10", None))


class ConversionTests(unittest.TestCase):
    def test_recent_downloads_returns_latest_five_mp3_files(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            for index in range(7):
                path = temp_root / f"track-{index}.mp3"
                path.write_bytes(b"ID3")
                os.utime(path, (index, index))
            (temp_root / "ignore.txt").write_text("ignore", encoding="utf-8")

            with mock.patch.object(app, "DOWNLOAD_DIR", temp_root):
                results = app.recent_downloads()

            self.assertEqual(
                [path.name for path in results],
                ["track-6.mp3", "track-5.mp3", "track-4.mp3", "track-3.mp3", "track-2.mp3"],
            )

    def test_bundled_macos_binary_has_priority(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            bundled_binary = temp_root / "yt-dlp_macos"
            bundled_binary.write_text("#!/bin/sh\n", encoding="utf-8")
            bundled_binary.chmod(bundled_binary.stat().st_mode | stat.S_IXUSR)
            with mock.patch.object(app, "ROOT", temp_root), \
                 mock.patch("app.shutil.which", return_value="/usr/local/bin/yt-dlp"):
                self.assertEqual(app.find_yt_dlp(), str(bundled_binary))

    def test_conversion_uses_argument_list_and_returns_mp3(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            fake_binary = temp_root / "yt-dlp"
            fake_binary.write_text("#!/bin/sh\n", encoding="utf-8")
            fake_binary.chmod(fake_binary.stat().st_mode | stat.S_IXUSR)
            output = temp_root / "result.mp3"
            output.write_bytes(b"ID3")
            completed = mock.Mock(returncode=0, stdout=f"{output}\n", stderr="")

            with mock.patch.object(app, "DOWNLOAD_DIR", temp_root), \
                 mock.patch.object(app, "find_yt_dlp", return_value=str(fake_binary)), \
                 mock.patch("app.subprocess.run", return_value=completed) as run:
                result = app.convert_to_mp3("https://youtu.be/abc123")

            self.assertEqual(result.resolve(), output.resolve())
            command = run.call_args.args[0]
            self.assertIsInstance(command, list)
            self.assertIn("--no-playlist", command)
            self.assertNotIn("--restrict-filenames", command)
            self.assertNotIn("--cookies-from-browser", command)
            output_template = command[command.index("--output") + 1]
            self.assertIn("%(title).100s.%(ext)s", output_template)
            self.assertNotIn("%(id)s", output_template)

    def test_ffmpeg_option_follows_embedded_module_invocation(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            output = temp_root / "result.mp3"
            output.write_bytes(b"ID3")
            completed = mock.Mock(returncode=0, stdout=f"{output}\n", stderr="")

            with mock.patch.object(app, "DOWNLOAD_DIR", temp_root), \
                 mock.patch.object(app, "yt_dlp_command", return_value=["python3", "-m", "yt_dlp"]), \
                 mock.patch.dict(os.environ, {"MY_MP3_FFMPEG": "/opt/homebrew/bin/ffmpeg"}), \
                 mock.patch("app.subprocess.run", return_value=completed) as run:
                app.convert_to_mp3("https://youtu.be/abc123")

            command = run.call_args.args[0]
            self.assertEqual(command[:3], ["python3", "-m", "yt_dlp"])
            self.assertGreater(command.index("--ffmpeg-location"), command.index("yt_dlp"))

    def test_embedded_yt_dlp_module_is_supported(self):
        with tempfile.TemporaryDirectory() as temp_dir:
            temp_root = Path(temp_dir)
            module_main = temp_root / "yt_dlp" / "__main__.py"
            module_main.parent.mkdir()
            module_main.write_text("", encoding="utf-8")
            with mock.patch.object(app, "ROOT", temp_root), \
                 mock.patch.object(app, "find_yt_dlp", return_value=None):
                command = app.yt_dlp_command()
            self.assertEqual(command, [app.sys.executable, "-m", "yt_dlp"])


if __name__ == "__main__":
    unittest.main()
