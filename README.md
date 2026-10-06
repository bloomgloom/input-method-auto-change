<p align="center">
  <img src="Resources/AppIcon.iconset/icon_128x128@2x.png" width="128" alt="Input Method Auto Change 아이콘">
</p>

# Input Method Auto Change

macOS에서 한/영 전환을 깜빡하고 입력한 단어를 자동으로 고쳐 주는 메뉴 막대 앱입니다.

예를 들어 영문 상태에서 `dkssudgktpdy`를 입력하면 `안녕하세요`로, 한글 상태에서 `ㅗ디ㅣㅐ`를 입력하면 `hello`로 교정하고 입력 소스도 함께 전환합니다.

## 주요 기능

- 공백, Return, `.`, `,`, `?`, `!` 입력 시 단어 자동 교정
- macOS 시스템 사전을 이용한 로컬 판별
- 직전 자동 교정을 `⌘Z`로 되돌리기
- 앱별 교정 제외 목록과 사용자 사전
- 로그인 시 자동 실행 및 메뉴 막대 아이콘 설정
- macOS 26 이상에서 Apple 온디바이스 Foundation Model을 이용한 선택적 판별
- 별도 서버나 네트워크 통신 없이 기기 안에서 처리

## 요구 사항

- Apple Silicon Mac
- macOS 14 Sonoma 이상
- `ABC` 또는 `U.S.` 영문 입력 소스
- `두벌식` 한국어 입력 소스
- 소스에서 빌드할 경우 Swift 6 도구 모음(Xcode 16 이상 또는 Command Line Tools)

## 설치

1. [Releases](https://github.com/bloomgloom/input-method-auto-change/releases)에서 최신 `InputMethodAutoChange.app.zip`을 다운로드합니다.
2. 압축을 풀고 `InputMethodAutoChange.app`을 `/Applications` 폴더로 옮깁니다.
3. 앱을 실행합니다.

현재 배포 앱은 Apple Developer 인증서로 서명하거나 공증하지 않은 ad-hoc 서명 앱입니다. macOS가 실행을 차단하면 **시스템 설정 → 개인정보 보호 및 보안**에서 **확인 없이 열기**를 선택합니다.

### 소스에서 빌드

```bash
git clone https://github.com/bloomgloom/input-method-auto-change.git
cd input-method-auto-change
./Scripts/build_app.sh release
open .build/InputMethodAutoChange.app
```

## 처음 실행할 때

1. 앱이 요청하는 **손쉬운 사용** 권한을 허용합니다.
2. 권한 상태가 갱신되면 설정 창을 닫습니다.
3. 메뉴 막대의 키보드 아이콘에서 설정을 다시 열 수 있습니다.

권한이 인식되지 않으면 **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용**에서 `Input Method Auto Change`를 껐다가 다시 켜 주세요. 임시 서명으로 앱을 다시 빌드하면 macOS가 새 앱으로 인식해 권한을 다시 요구할 수 있습니다.

## 교정 방식

앱은 현재 입력 소스로 작성된 단어를 먼저 확인합니다. 현재 단어가 정상이라면 그대로 두고, 반대 입력 소스로 해석한 결과만 사전에 있는 단어일 때 교정합니다. 설정에서 **Dictionary + AFM**을 선택하면 시스템 사전에 없는 고유명사나 신조어도 Apple의 온디바이스 모델로 추가 판별합니다.

## 제한 사항

- ABC/U.S. ↔ 한국어 두벌식 조합만 지원합니다.
- 편집 가능한 텍스트 영역이 아닌 곳에서는 동작하지 않습니다.
- 브라우저 및 Electron 앱의 웹 기반 편집 영역은 입력 상태 손상을 막기 위해 교정하지 않습니다.
- 시스템 사전과 선택한 판별 모드에 따라 일부 단어는 교정되지 않거나 잘못 교정될 수 있습니다. 직후 `⌘Z`로 복원할 수 있습니다.

## 개발

```bash
swift test
./Scripts/build_app.sh debug
```

앱은 Swift Package Manager와 macOS 기본 프레임워크만 사용합니다.

## 라이선스

[GNU Affero General Public License v3.0](LICENSE)
