# youtube-mp3-jn

본인이 소유했거나 다운로드 허가를 받은 YouTube 영상의 오디오를 MP3로 변환하는 개인용 앱입니다. macOS 앱이 실제 변환을 처리하고, iPhone 앱은 같은 Wi-Fi에서 Mac을 자동으로 찾아 변환 요청과 파일 저장을 담당합니다.

> YouTube 이용약관과 저작권자의 권리를 준수하세요. 접근 제한 우회, 로그인 쿠키 사용, 재생목록 일괄 다운로드 기능은 제공하지 않습니다.

## 구성

- Python 로컬 변환 서버
- macOS 네이티브 앱 셸과 Bonjour 서비스
- iPhone SwiftUI 클라이언트
- `yt-dlp`와 FFmpeg 기반 MP3 변환
- 로컬 네트워크 요청용 개인 토큰 인증
- Mac과 iPhone에서 펼쳐보는 최근 저장 파일 5개 목록

## 준비물

- macOS
- Python 3
- FFmpeg
- iPhone 앱 빌드 시 Xcode와 Apple 개발 서명

Homebrew를 사용한다면 FFmpeg는 다음과 같이 설치할 수 있습니다.

```bash
brew install ffmpeg
```

## 웹앱 실행

```bash
git clone https://github.com/jinoisfree/youtube-mp3-jn.git
cd youtube-mp3-jn
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python app.py
```

브라우저에서 <http://127.0.0.1:8000>을 엽니다. 결과 파일은 기본적으로 `downloads` 폴더에 저장됩니다.

## macOS 앱 만들기

Python 환경을 설치한 뒤 실행합니다.

```bash
chmod +x build-macos-app.sh
./build-macos-app.sh
```

완성된 앱은 `dist/My MP3.app`입니다. 처음 빌드할 때 `config/remote-token.txt`가 자동 생성되며, 이 파일은 Git에 포함되지 않습니다. macOS 앱에서 변환한 파일은 `iCloud Drive/My MP3` 폴더에 저장됩니다.

## iPhone 앱 만들기

1. 먼저 `./build-macos-app.sh`를 실행해 개인 연결 토큰을 생성합니다.
2. `ios/MyMP3Mobile.xcodeproj`를 Xcode로 엽니다.
3. `Signing & Capabilities`에서 본인의 Team을 선택합니다.
4. 필요하면 Bundle Identifier를 본인 계정에 맞는 고유 값으로 변경합니다.
5. iPhone을 연결하고 `MyMP3Mobile` 스킴을 실행합니다.
6. iPhone에서 로컬 네트워크 접근을 허용합니다.

사용할 때는 Mac의 `My MP3` 앱을 실행하고 두 기기를 같은 Wi-Fi에 연결해야 합니다. iPhone에서 받은 파일은 `파일 → 나의 iPhone → My MP3`에 저장됩니다.

## 보안 주의사항

- `config/remote-token.txt`를 커밋하거나 공유하지 마세요.
- 이 서버를 인터넷에 직접 공개하지 마세요.
- 로컬 Mac 요청은 허용되며, 다른 기기의 요청은 개인 토큰으로 인증됩니다.
- 변환 권한이 있는 콘텐츠에만 사용하세요.

## 테스트

```bash
python3 -m unittest discover -s tests -v
```

## 현재 제한

- 단일 공개 YouTube 영상만 처리합니다.
- Mac 앱이 실행 중이어야 iPhone 앱을 사용할 수 있습니다.
- 외부 공개 서비스로 운영하려면 별도의 사용자 인증, 작업 큐, 저장 용량 제한, 자동 삭제, 악용 방지와 법률 검토가 필요합니다.
