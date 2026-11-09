<p align="center">
  <img src="docs/images/mascot.gif" width="240" alt="MacHelper 슬라임: 숨 쉬기, 손 흔들기, 점프, 축하">
</p>

<h1 align="center">MacHelper</h1>

<p align="center">
  <b>모든 것이 Mac 안에서 동작하는 유틸리티. 시스템 모니터, 팬 제어, 정리, 디스크 분석을 하나의 메뉴 막대 앱에 담았습니다.</b>
</p>

<p align="center">
  <a href="https://github.com/smile-minecraft/MacHelper/releases/latest"><img src="https://img.shields.io/github/v/release/smile-minecraft/MacHelper?label=release&color=5b8def" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1f2430" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Apple%20Silicon-arm64-1f2430" alt="Apple Silicon">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-4cc38a" alt="MIT"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <a href="README.zh-Hant.md">繁體中文</a> · <a href="README.zh-Hans.md">简体中文</a> · <a href="README.ja.md">日本語</a> · 한국어 · <a href="README.es.md">Español</a>
</p>

<p align="center">
  <img src="docs/images/menubar.png" width="320" alt="메뉴 막대의 MacHelper: CPU 꺾은선, 메모리, 온도">
</p>

<p align="center">
  <img src="docs/images/overview.png" width="860" alt="개요: 건강 점수, 실시간 값, 리소스를 가장 많이 쓰는 앱">
</p>

<p align="center">
  <a href="#설치"><b>설치</b></a> ·
  <a href="#기능"><b>기능</b></a> ·
  <a href="#처음-실행"><b>처음 실행</b></a> ·
  <a href="#명령줄"><b>명령줄</b></a> ·
  <a href="#소스에서-빌드"><b>소스에서 빌드</b></a>
</p>

---

MacHelper가 측정하고 저장하는 모든 데이터는 Mac 안에 남습니다. 계정도 분석도 없고, 업데이트 확인 외에는 네트워크를 쓰지 않습니다. macOS 14 이상의 Apple Silicon Mac이 필요하며 MIT 라이선스 오픈 소스입니다.

## 설치

```sh
brew install --cask smile-minecraft/tap/machelper
```

[Releases](https://github.com/smile-minecraft/MacHelper/releases/latest)에서 `MacHelper-<버전>.dmg`를 내려받아 MacHelper를 응용 프로그램 폴더로 드래그해도 됩니다. 모든 릴리스는 Developer ID로 서명되고 Apple의 공증을 받아 바로 열 수 있습니다. 체크섬은 릴리스 페이지의 `SHA256SUMS.txt`에 있습니다.

MacHelper는 스스로 최신 상태를 유지합니다. 백그라운드 확인에서 새 버전을 찾으면 사이드바, 메뉴 막대 패널, 설정에 **x.y.z(으)로 업데이트** 버튼이 나타나고, 누를 때만 설치합니다. 업데이트 창은 앱의 표시 언어로 새로운 기능을 보여 줍니다.

## 기능

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>모니터</h3>
      <img src="docs/images/monitor.png" alt="모니터: CPU, GPU, 메모리, 온도, 팬, 전력 그래프와 경고선">
      <p>CPU(성능 코어와 효율 코어), GPU, 메모리 압력, 온도, 팬, 전력, 배터리, 디스크와 네트워크 속도. 실시간 그래프와 1분 단위 기록을 1시간, 24시간, 7일로 볼 수 있고, 메모리와 온도에는 경고선이 있습니다. 메뉴 막대의 각 항목은 텍스트, 꺾은선, 세로 막대, 막대, 링, 블록, 히트 필, 이중선으로 표시할 수 있습니다.</p>
    </td>
    <td width="50%" valign="top">
      <h3>건강 점검</h3>
      <img src="docs/images/health.png" alt="건강 점검: 점수, 최근 24시간의 값, 사용 가능 공간 변화">
      <p>최근 몇 시간의 기록, 사용 가능 공간, 백그라운드 항목으로 건강 점수를 내고, 점수가 내려간 이유와 할 일을 알려 줍니다. Gatekeeper, FileVault, 방화벽, 시스템 무결성 보호, 자동 보안 업데이트, XProtect도 읽기 전용으로 확인합니다.</p>
    </td>
  </tr>
  <tr>
    <td colspan="2" valign="top">
      <h3>디스크 분석</h3>
      <img src="docs/images/disk.png" alt="디스크 분석: 홈 폴더의 선버스트와 가장 큰 폴더">
      <p>선버스트와 트리맵(어떤 폴더든 클릭하면 바로 들어갑니다), 종류와 기간으로 거를 수 있는 큰 파일, 중복 파일(APFS 복제본과 하드 링크 구분), 지난 스캔 이후의 변화, 오래 쓰지 않은 큰 파일과 부풀어 오른 폴더를 찾아 주는 공간 제안. 항목을 수집함으로 끌어다 놓으면 한 번에 휴지통으로 옮길 수 있습니다.</p>
    </td>
  </tr>
</table>

| | |
|---|---|
| **팬 제어** | 자동, 고정 속도, 온도 곡선(조용함, 균형, 성능, 사용자 지정), ‘올리기만’ 모드, 안전 상한, 실행 중인 앱이나 전원에 따른 프로필 자동 전환. |
| **원클릭 최적화** | 미리 본 뒤 정리합니다. 위험이 낮은 캐시는 삭제하고, 중간·높은 위험 항목은 휴지통으로 옮깁니다. 보호된 경로, 정리하지 않을 목록, 작업 기록, 유지 관리 작업, 프로젝트 빌드 산출물 정리, 예약 자동 정리. |
| **앱 제거** | 번들 ID, 내장 도우미, 권한, 컨테이너 정보, launchd 소유자, Homebrew zap 목록, 앱별 규칙으로 앱이 남긴 것을 찾습니다. 이름으로만 일치한 항목은 확인용으로 표시되며, 이미 삭제된 앱의 잔여 파일도 찾습니다. |
| **시동 항목** | 내 Launch Agent(비활성화, 활성화, 제거), 모든 사용자의 Agent, 시스템 Daemon. 소속 앱과 깨진 항목을 표시합니다. |
| **Homebrew 업데이트** | Homebrew로 설치한 앱을 업데이트합니다. |
| **AI 에이전트 스킬** | Claude Code와 Codex에 스킬을 추가해 MacHelper를 안전하게 쓰게 합니다. 항상 먼저 미리 보고, 제거하기 전에 묻습니다. |
| **알림** | CPU 온도가 높을 때, 메모리 압력이 위험할 때, 디스크 공간이 부족할 때 알려 줍니다. |
| **선택적 기록** | 프로세스, 센서, 코어 기록은 기본적으로 꺼져 있습니다. 프로세스 기록은 이름, CPU, 메모리만 남기며(경로, 인수, 사용자 이름은 남기지 않음) 1~30일 동안 보관합니다. |
| **슬라임** | 마스코트는 Mac 상태에 따라 색이 바뀌고(파랑, 노랑, 빨강), 클릭, 포인터, 드래그와 과열·정리 완료 같은 이벤트에 반응합니다. ‘동작 줄이기’와 VoiceOver를 지원합니다. |
| **언어** | 영어, 번체 중국어, 간체 중국어, 일본어, 한국어, 스페인어. 설정 → 일반 → 언어에서 시스템과 다른 언어를 고를 수 있습니다. |

## 처음 실행

MacHelper는 두 가지 권한을 하나씩 안내합니다. 둘 다 선택 사항이며, 나머지 기능은 없어도 작동합니다.

1. **전체 디스크 접근 권한**이 있으면 디스크 분석과 정리가 ‘메일’ 다운로드나 다른 앱의 캐시 같은 보호된 위치를 볼 수 있습니다. **시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한**에서 MacHelper를 켜면 안내 창이 알아서 확인합니다. 시스템 무결성 보호 대상 폴더는 켜도 읽을 수 없으며, 디스크 분석에서 따로 보여 줍니다.
2. **Helper**는 팬 제어, 시스템 캐시와 로그 정리, 시스템 백그라운드 항목, 시스템 프로세스 사용량을 맡는 작은 root 데몬입니다. 안내에 따라 설치하고 **시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램**에서 허용하면 응답하는지 확인합니다. 모든 호출자의 코드 서명을 검증합니다. 꺼져 있는 동안에는 사이드바 아래의 **Helper 설정…**으로 안내를 다시 열 수 있습니다.

## 명령줄

앱에는 `machelper` 명령이 들어 있습니다(Homebrew가 링크를 만들어 줍니다). 모든 명령은 기본적으로 미리 보기만 하고 `--json`을 지원하므로 스크립트나 AI 에이전트에서 쓰기 좋습니다. 개요는 `machelper guide`, 각 명령 설명은 `machelper <명령> --help`로 확인합니다.

```sh
machelper status --json                 # 현재의 모든 값
machelper clean                         # 정리될 항목 미리 보기
machelper clean --max-risk low --yes    # 위험이 낮은 항목만 정리
```

## 소스에서 빌드

Xcode 16 이상과 [XcodeGen](https://github.com/yonaskolb/XcodeGen)이 필요합니다.

```sh
xcodegen generate
scripts/install.sh          # Release 빌드 → /Applications/MacHelper.app, 그다음 다시 실행
swift test                  # Swift 패키지 단위 테스트
```

서명, 프로젝트 구조, 스크린샷 만들기, 릴리스 절차(언어별 업데이트 안내 포함), 번역 방법은 [영어 README](README.md)를 참고하십시오.

## 라이선스

MIT. [LICENSE](LICENSE)를 참고하십시오.
