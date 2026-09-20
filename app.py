#!/usr/bin/env python3
"""로컬 전용 YouTube 오디오 변환 웹앱."""

from __future__ import annotations

import json
import hmac
import ipaddress
import mimetypes
import os
import shutil
import subprocess
import sys
import threading
import urllib.parse
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional


ROOT = Path(__file__).resolve().parent
STATIC_DIR = ROOT / "static"
DOWNLOAD_DIR = Path(os.environ.get("MY_MP3_DOWNLOAD_DIR", str(ROOT / "downloads"))).expanduser().resolve()
MAX_BODY_BYTES = 16_384
DOWNLOAD_TIMEOUT_SECONDS = 15 * 60
YOUTUBE_HOSTS = {
    "youtube.com",
    "www.youtube.com",
    "m.youtube.com",
    "music.youtube.com",
    "youtu.be",
}
download_lock = threading.Lock()


def remote_request_is_authorized(client_host: str, provided_token: Optional[str]) -> bool:
    try:
        if ipaddress.ip_address(client_host).is_loopback:
            return True
    except ValueError:
        pass
    configured_token = os.environ.get("MY_MP3_REMOTE_TOKEN", "")
    return bool(configured_token and provided_token and hmac.compare_digest(configured_token, provided_token))


def validate_youtube_url(value: object) -> Optional[str]:
    if not isinstance(value, str):
        return None
    candidate = value.strip()
    try:
        parsed = urllib.parse.urlparse(candidate)
    except ValueError:
        return None
    host = (parsed.hostname or "").lower().rstrip(".")
    if parsed.scheme not in {"http", "https"} or host not in YOUTUBE_HOSTS:
        return None
    if parsed.username or parsed.password:
        return None
    return candidate


def find_yt_dlp() -> Optional[str]:
    bundled_binary = ROOT / "yt-dlp_macos"
    if bundled_binary.is_file() and os.access(str(bundled_binary), os.X_OK):
        return str(bundled_binary)
    local_binary = ROOT / ".venv" / "bin" / "yt-dlp"
    if local_binary.is_file() and os.access(str(local_binary), os.X_OK):
        return str(local_binary)
    return shutil.which("yt-dlp")


def yt_dlp_command() -> Optional[list[str]]:
    binary = find_yt_dlp()
    if binary:
        return [binary]
    if (ROOT / "yt_dlp" / "__main__.py").is_file():
        return [sys.executable, "-m", "yt_dlp"]
    return None


def recent_downloads(limit: int = 5) -> list[Path]:
    if not DOWNLOAD_DIR.is_dir():
        return []
    candidates: list[tuple[float, Path]] = []
    for path in DOWNLOAD_DIR.iterdir():
        if not path.is_file() or path.suffix.lower() != ".mp3":
            continue
        try:
            candidates.append((path.stat().st_mtime, path))
        except OSError:
            continue
    candidates.sort(key=lambda item: item[0], reverse=True)
    return [path for _, path in candidates[:limit]]


def convert_to_mp3(url: str) -> Path:
    command = yt_dlp_command()
    if not command:
        raise RuntimeError("yt-dlp가 설치되지 않았습니다. README의 설치 명령을 실행해 주세요.")

    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
    output_template = str(DOWNLOAD_DIR / "%(title).100s.%(ext)s")
    command.extend([
        "--no-playlist",
        "--no-progress",
        "--extract-audio",
        "--audio-format",
        "mp3",
        "--audio-quality",
        "0",
        "--print",
        "after_move:filepath",
        "--output",
        output_template,
        url,
    ])
    ffmpeg_location = os.environ.get("MY_MP3_FFMPEG")
    if ffmpeg_location:
        command.extend(["--ffmpeg-location", ffmpeg_location])

    try:
        completed = subprocess.run(
            command,
            cwd=str(ROOT),
            capture_output=True,
            text=True,
            timeout=DOWNLOAD_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError("변환 시간이 15분을 초과했습니다.") from exc

    if completed.returncode != 0:
        detail = completed.stderr.strip().splitlines()
        message = detail[-1] if detail else "알 수 없는 yt-dlp 오류"
        raise RuntimeError(f"변환에 실패했습니다: {message[:300]}")

    for line in reversed(completed.stdout.splitlines()):
        candidate = Path(line.strip()).resolve()
        try:
            candidate.relative_to(DOWNLOAD_DIR.resolve())
        except ValueError:
            continue
        if candidate.is_file() and candidate.suffix.lower() == ".mp3":
            return candidate
    raise RuntimeError("변환은 끝났지만 MP3 결과 파일을 찾지 못했습니다.")


class AppHandler(SimpleHTTPRequestHandler):
    server_version = "MyMP3/1.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(STATIC_DIR), **kwargs)

    def send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self) -> None:
        if self.path != "/api/convert":
            self.send_json(HTTPStatus.NOT_FOUND, {"error": "요청 경로를 찾을 수 없습니다."})
            return
        if not remote_request_is_authorized(self.client_address[0], self.headers.get("X-MyMP3-Token")):
            self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "인증되지 않은 기기입니다."})
            return

        try:
            content_length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            content_length = 0
        if content_length <= 0 or content_length > MAX_BODY_BYTES:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "요청 크기가 올바르지 않습니다."})
            return

        try:
            data = json.loads(self.rfile.read(content_length))
        except (json.JSONDecodeError, UnicodeDecodeError):
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "JSON 요청이 올바르지 않습니다."})
            return

        url = validate_youtube_url(data.get("url"))
        if not url:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "올바른 YouTube URL을 입력해 주세요."})
            return
        if data.get("rightsConfirmed") is not True:
            self.send_json(HTTPStatus.BAD_REQUEST, {"error": "다운로드 권한 확인이 필요합니다."})
            return

        if not download_lock.acquire(blocking=False):
            self.send_json(HTTPStatus.CONFLICT, {"error": "다른 변환이 진행 중입니다. 잠시 후 다시 시도해 주세요."})
            return
        try:
            result = convert_to_mp3(url)
        except RuntimeError as exc:
            self.send_json(HTTPStatus.BAD_GATEWAY, {"error": str(exc)})
            return
        finally:
            download_lock.release()

        quoted_name = urllib.parse.quote(result.name)
        self.send_json(
            HTTPStatus.OK,
            {"filename": result.name, "downloadUrl": f"/downloads/{quoted_name}"},
        )

    def do_GET(self) -> None:
        if self.path.startswith("/downloads/"):
            self.serve_download()
            return
        if self.path == "/api/history":
            if not remote_request_is_authorized(self.client_address[0], self.headers.get("X-MyMP3-Token")):
                self.send_json(HTTPStatus.UNAUTHORIZED, {"error": "인증되지 않은 기기입니다."})
                return
            items = [
                {
                    "filename": path.name,
                    "downloadUrl": f"/downloads/{urllib.parse.quote(path.name)}",
                }
                for path in recent_downloads()
            ]
            self.send_json(HTTPStatus.OK, {"items": items})
            return
        if self.path == "/health":
            self.send_json(HTTPStatus.OK, {"status": "ok", "ytDlp": bool(yt_dlp_command())})
            return
        super().do_GET()

    def serve_download(self) -> None:
        if not remote_request_is_authorized(self.client_address[0], self.headers.get("X-MyMP3-Token")):
            self.send_error(HTTPStatus.UNAUTHORIZED)
            return
        raw_name = urllib.parse.unquote(self.path.removeprefix("/downloads/"))
        if not raw_name or Path(raw_name).name != raw_name:
            self.send_error(HTTPStatus.BAD_REQUEST)
            return
        file_path = DOWNLOAD_DIR / raw_name
        if not file_path.is_file() or file_path.suffix.lower() != ".mp3":
            self.send_error(HTTPStatus.NOT_FOUND)
            return

        content_type = mimetypes.guess_type(file_path.name)[0] or "audio/mpeg"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(file_path.stat().st_size))
        self.send_header("Content-Disposition", f"attachment; filename*=UTF-8''{urllib.parse.quote(file_path.name)}")
        self.end_headers()
        with file_path.open("rb") as source:
            shutil.copyfileobj(source, self.wfile)

    def log_message(self, message: str, *args) -> None:
        print(f"[{self.log_date_time_string()}] {message % args}")


def main() -> None:
    host = os.environ.get("APP_HOST", "127.0.0.1")
    port = int(os.environ.get("APP_PORT", "8000"))
    server = ThreadingHTTPServer((host, port), AppHandler)
    print(f"My MP3 앱 실행 중: http://{host}:{port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n서버를 종료합니다.")
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
