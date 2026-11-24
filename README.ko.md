<p align="center">
  <img src="docs/images/mascot.gif" width="200" alt="MacHelper 슬라임: 숨 쉬기, 손 흔들기, 점프, 축하">
</p>

<h1 align="center">MacHelper</h1>

<p align="center">
  <b>네이티브 macOS 시스템 모니터, 팬 제어, 정리, 디스크 분석 및 AI 지원 CLI — 로컬 우선, 오픈 소스, Apple Silicon 및 Intel 지원.</b>
</p>

<p align="center">
  <a href="https://github.com/smile-minecraft/MacHelper/releases/latest"><img src="https://img.shields.io/github/v/release/smile-minecraft/MacHelper?label=Release&color=5b8def" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-1f2430" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Universal-Apple%20Silicon%20%26%20Intel-1f2430" alt="Universal (Apple Silicon & Intel)">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-4cc38a" alt="MIT license"></a>
  <a href="https://smile-minecraft.github.io/MacHelper/"><img src="https://img.shields.io/badge/Website-Docs-5b8def" alt="웹사이트 및 문서"></a>
</p>

<p align="center">
  <a href="README.md">English</a> ·
  <a href="README.zh-Hant.md">繁體中文</a> ·
  <a href="README.zh-Hans.md">简体中文</a> ·
  <a href="README.ja.md">日本語</a> ·
  <b>한국어</b> ·
  <a href="README.es.md">Español</a>
</p>

<p align="center">
  <a href="#왜-machelper인가요">왜 MacHelper인가요</a> ·
  <a href="#설치">설치</a> ·
  <a href="#기능">기능</a> ·
  <a href="#개인정보-보호-및-텔레메트리">개인정보</a> ·
  <a href="#처음-실행">처음 실행</a> ·
  <a href="#명령줄">CLI</a> ·
  <a href="#ai-에이전트와-함께-쓰기">AI 에이전트</a> ·
  <a href="#자주-묻는-질문">FAQ</a> ·
  <a href="#소스에서-빌드">빌드</a>
</p>

<p align="center">
  <img src="docs/images/menubar.png" width="320" alt="메뉴 막대의 MacHelper: CPU 꺾은선, 메모리, 온도">
</p>

<p align="center">
  <img src="docs/images/overview.png" width="860" alt="개요: 건강 점수, 실시간 값, 리소스를 가장 많이 쓰는 앱">
</p>

---

MacHelper는 macOS 14 이상의 Apple Silicon 및 Intel Mac용 네이티브 Swift로 제작된 무료·MIT 라이선스 메뉴 막대 앱이자 명령줄 도구입니다. **시스템 모니터**(CPU, GPU, 메모리, 온도, 팬, 전력, 배터리, 디스크, 네트워크), **팬 제어**, **캐시 및 정크 정리**, **디스크 공간 분석**, **앱 완전 삭제**를 가벼운 앱 하나로 제공합니다.

또한 `--json` 출력을 지원하는 `machelper` CLI, 한 번에 개인정보를 가린 진단 리포트를 생성하는 `machelper report --json`, 그리고 Claude Code·Codex·OpenCode 같은 AI 코딩 어시스턴트용 스킬을 함께 제공합니다. 항상 먼저 미리 보기를 보여 주고, 무엇이든 지우기 전에 동의를 구합니다.

## 왜 MacHelper인가요

다섯 개의 유료 유틸리티를 따로 구매해 띄워 둘 필요 없이, MacHelper 하나면 충분합니다:

| 핵심 기능 | 대체하는 앱 | MacHelper의 방식 |
|---|---|---|
| **시스템 및 메뉴 막대 모니터** | iStat Menus | 네이티브 SwiftUI/AppKit 센서, P/E 코어 분리, 1시간/24시간/7일 기록, 8가지 메뉴 막대 스타일 |
| **팬 속도 및 곡선 제어** | Macs Fan Control | 고정 RPM 또는 사용자 지정 온도 곡선, ‘올리기만’ 모드, 실행 앱·전원별 프로필 |
| **정리 및 유지 관리** | CleanMyMac | 선언적 정리 규칙, 기본 미리 보기, 중·고위험 항목 휴지통 이동, 보호 경로 차단 |
| **디스크 공간 분석** | DaisyDisk | 초고속 `getattrlistbulk` 선버스트 및 트리맵, APFS 클론 인식 중복 탐지, 증가 추적 |
| **앱 제거** | AppCleaner | 번들 ID, 내장 도우미, 컨테이너, launchd, Homebrew zap 매칭 및 잔여 파일 정리 |
| **AI 에이전트 자동화** | *MacHelper 고유* | `machelper report --json` 비식별화 진단 리포트, `--yes` 안전 장치, 에이전트 스킬 |

> **무료 · 오픈 소스 (MIT) · 네이티브 Swift · Apple Silicon & Intel · 기본 로컬 우선**

## 설치

```sh
brew install --cask smile-minecraft/tap/machelper
```

또는 [Releases](https://github.com/smile-minecraft/MacHelper/releases/latest)에서 `MacHelper-<버전>.dmg`를 내려받아 **MacHelper**를 응용 프로그램 폴더로 드래그하세요. 모든 릴리스는 Developer ID로 서명되고 Apple 공증을 거쳤으며, 체크섬은 각 릴리스 페이지의 `SHA256SUMS.txt`에 게시됩니다. [MacHelper 웹사이트](https://smile-minecraft.github.io/MacHelper/)에서도 개요와 릴리스 주요 내용을 확인할 수 있습니다.

**자동 업데이트:** MacHelper는 백그라운드에서 새 버전을 확인하고 사이드바, 메뉴 막대 패널, 설정에 **x.y.z(으)로 업데이트** 버튼을 띄웁니다. 사용자가 직접 클릭하기 전에는 아무것도 설치하지 않으며, 릴리스 노트는 설정된 앱 언어로 표시됩니다.

## 기능

<table>
  <tr>
    <td width="50%" valign="top">
      <h3>시스템 모니터</h3>
      <img src="docs/images/monitor.png" alt="모니터: CPU, GPU, 메모리, 온도, 팬, 전력 그래프와 경고선">
      <p>CPU(성능 코어와 효율 코어), GPU, 메모리 압력, 온도, 팬, 전력, 배터리, 디스크 및 네트워크 처리량을 실시간 그래프와 1분 단위 기록(1시간, 24시간, 7일)으로 확인하세요. 메모리와 온도에는 경고선을 둘 수 있으며, 각 메뉴 막대 항목은 텍스트, 꺾은선, 세로 막대, 막대, 링, 블록, 히트 필, 이중선 중 선택해 꾸밀 수 있습니다.</p>
    </td>
    <td width="50%" valign="top">
      <h3>건강 점검</h3>
      <img src="docs/images/health.png" alt="건강 점검: 점수, 최근 24시간의 값, 사용 가능 공간 변화">
      <p>최근 몇 시간의 시스템 기록, 사용 가능 공간, 백그라운드 항목을 바탕으로 건강 점수를 매기고, 점수가 떨어진 원인과 해결 방법을 알려 줍니다. Gatekeeper, FileVault, 방화벽, 시스템 무결성 보호(SIP), 자동 보안 업데이트, XProtect에 대한 읽기 전용 보안 점검도 포함됩니다.</p>
    </td>
  </tr>
  <tr>
    <td colspan="2" valign="top">
      <h3>디스크 분석</h3>
      <img src="docs/images/disk.png" alt="디스크 분석: 홈 폴더의 선버스트와 가장 큰 폴더">
      <p>인터랙티브 선버스트와 트리맵(폴더를 클릭해 바로 탐색), 종류·기간 필터가 있는 대용량 파일 목록, 중복 파일 탐지(APFS 클론과 하드 링크 구분), 이전 스캔 대비 용량 변화 추적, 오래 쓰지 않은 큰 파일과 비대해진 폴더 정리 제안을 제공합니다. 항목을 수집함으로 끌어다 놓고 한 번에 휴지통으로 옮길 수 있습니다.</p>
    </td>
  </tr>
</table>

| 영역 | 주요 기능 |
|---|---|
| **팬 제어** | 자동, 고정 속도, 온도 곡선(조용함, 균형, 성능, 사용자 지정), ‘올리기만’ 모드, 안전 상한선, 실행 중인 앱이나 전원 소스에 따른 자동 프로필 전환. |
| **원클릭 최적화** | 미리 보기를 제공하는 선언적 정리 규칙: 저위험 캐시는 바로 삭제하고 중·고위험 항목은 휴지통으로 이동합니다. 보호된 경로, 제외 목록, 작업 로그, 유지 관리 작업, 빌드 산출물 정리, 예약 자동 정리를 지원합니다. |
| **앱 제거** | 번들 ID, 내장 도우미, 권한, 컨테이너 메타데이터, `launchd` 소유자, Homebrew zap 목록 및 앱별 규칙으로 잔여 파일을 추적합니다. 이름만으로 일치한 항목은 검토 대상으로 표시하며 이미 삭제된 앱의 잔여물도 찾습니다. |
| **시동 항목** | 사용자 Launch Agent를 비활성화·활성화·제거하고, 전체 사용자 Agent와 시스템 Daemon을 소유 앱 및 손상 표시와 함께 살펴볼 수 있습니다. |
| **Homebrew 업데이트** | Homebrew로 설치한 앱과 Cask를 MacHelper 안에서 확인하고 업데이트합니다. |
| **알림** | CPU 과열, 위험한 메모리 압력, 디스크 공간 부족 시 알림을 보냅니다. |
| **선택적 기록** | 프로세스, 센서, 코어 기록은 기본적으로 꺼져 있습니다. 프로세스 기록은 이름, CPU, 메모리만 남기며(경로, 인수, 사용자 이름은 저장 안 함) 1~30일간 보관합니다. |
| **슬라임 마스코트** | Mac 상태에 따라 색상이 바뀌고(파랑, 노랑, 빨강), 클릭·마우스 오버·드래그 및 발열이나 정리 완료 이벤트에 반응합니다. ‘동작 줄이기’와 VoiceOver를 존중합니다. |
| **테마 및 재질** | 라이트·다크·시스템 모드, 솔리드·프로스트·Liquid Glass 표면 재질, Instrument 및 Pixel Retro 프리셋, VS Code 테마 가져오기, 대비 검증을 거친 가독성을 지원합니다. |
| **언어** | 영어, 번체 중국어, 간체 중국어, 일본어, 한국어, 스페인어. **설정 → 일반 → 언어**에서 macOS와 별도로 언어를 지정할 수 있습니다. |

## 개인정보 보호 및 텔레메트리

- **기본값이 로컬 우선(Local-first)입니다.** MacHelper가 측정하고 스캔하고 저장하는 모든 데이터는 사용자의 Mac 안에만 남습니다. 계정, 클라우드 동기화, 백그라운드 추적이 전혀 없으며, 업데이트 확인 외에는 직접 옵트인하지 않는 한 네트워크 요청을 보내지 않습니다.
- **선택적 텔레메트리(기본값 꺼짐).** **설정 → 일반 → 개인정보 보호 및 진단**에서 원할 때만 켜서 엄격히 익명화된 사용 횟수와 거친 성능 진단(앱 버전, macOS 버전, 칩 제품군, 익명 카운터)을 공유할 수 있습니다.
- **민감 정보 수집 제로.** 파일 경로, 프로세스 이름, 디스크 내용, 호스트 이름, 개인 식별자는 절대 수집하지 않습니다. 설정 안에서 전송될 정확한 JSON 페이로드를 미리 확인할 수 있고 언제든 끌 수 있습니다. 끄는 즉시 익명 ID와 대기 중인 이벤트 큐가 모두 삭제됩니다.

## 처음 실행

MacHelper는 6단계 **환영 가이드**(**도움말 → 환영 가이드…**에서 언제든 다시 실행 가능)를 열어 기본 설정과 선택적 **전체 디스크 접근 권한**, **Helper**, **AI 에이전트 스킬** 구성을 안내합니다. 선택적 권한을 켜지 않아도 나머지 기능은 모두 정상 동작합니다:

1. **전체 디스크 접근 권한**을 허용하면 디스크 분석과 정리가 ‘메일’ 다운로드나 다른 앱의 캐시 등 보호된 위치를 읽을 수 있습니다. **시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한**에서 MacHelper를 켜면 환영 가이드가 자동으로 인식합니다. 시스템 무결성 보호(SIP) 대상 폴더는 켜도 읽을 수 없으며 디스크 분석에서 따로 표시됩니다.
2. **Helper**는 팬 제어, 시스템 캐시·로그 정리, 시스템 백그라운드 항목, 시스템 프로세스 사용량을 담당하는 가벼운 root 데몬입니다. 가이드가 설치를 돕고 **시스템 설정 → 일반 → 로그인 항목 및 확장 프로그램**을 열어 허용하도록 안내한 뒤 응답을 확인합니다. 모든 호출자의 코드 서명을 검증하며, 꺼져 있을 때는 사이드바 하단의 **Helper 설정…**으로 언제든 다시 열 수 있습니다.
3. **AI 에이전트 스킬**은 감지된 에이전트(Claude Code, Codex 등)에 대해 가이드에서 바로 설치할 수 있으며, 기존의 사용자 지정 `SKILL.md` 파일은 덮어쓰지 않습니다.

## 명령줄

MacHelper에는 `machelper` CLI가 포함되어 있습니다(Homebrew 설치 시 자동 연결). 모든 명령은 기본적으로 미리 보기만 수행하고 `--json`을 지원해 스크립트나 AI 에이전트에 적합합니다. 전체 개요는 `machelper guide`, 명령별 옵션은 `machelper <명령> --help`로 확인하세요.

```sh
machelper report --json                 # 개인정보가 가려진 전체 시스템 진단 리포트
machelper status --json                 # 실시간 하드웨어, 온도, 팬, 배터리 스냅샷
machelper clean                         # 정리될 항목 미리 보기
machelper clean --max-risk low --yes    # 위험이 낮은 항목만 정리
```

## AI 에이전트와 함께 쓰기

사용자가 Claude Code, Codex, OpenCode 같은 AI 어시스턴트에게 Mac이 느리거나 뜨거운 이유 진단, 디스크 공간 확보, `node_modules` 또는 Xcode 잔여물 정리, 앱 완전 삭제, 시동 항목 점검을 요청할 때 `machelper`가 안전하고 구조화된 인터페이스를 제공합니다.

- **단 한 번의 비식별화 진단 리포트(`machelper report`).** `machelper report --json`(또는 `machelper report --format markdown`)을 실행하면 하드웨어, 실시간 지표, 건강 점수, 저장 공간, 보안 감사, 정리 미리 보기, 시동 항목을 한 번에 수집합니다. 사용자 이름, 홈 경로, 호스트 이름, IP, MAC 주소는 기본적으로 모두 가려지며, JSON 출력에 구조화된 `suggestedActions`와 `availableTools`가 포함되어 AI 에이전트가 후속 `machelper` 명령을 안전하게 이어 갈 수 있습니다.
- **기본이 안전합니다.** 변경을 가하는 모든 명령은 `--yes`를 넘기기 전까지 미리 보기만 수행합니다. 제거된 항목은 `--permanent`를 지정하지 않으면 휴지통으로 이동하며, 보호된 경로(키체인, 메일, 사진, `~/.ssh`, `~/Documents` 등)는 절대 삭제할 수 없습니다.
- **기계 가독성.** 모든 명령이 `--json`, `schemaVersion` 필드, 예측 가능한 종료 코드를 지원하며 `machelper --experimental-dump-help`로 전체 명령 트리를 JSON으로 받을 수 있습니다.
- **내장 에이전트 스킬.** `machelper skill install claude` 또는 `machelper skill install codex`(설정에서도 가능)는 먼저 조사·미리 보기를 수행하고 적용 전에 사용자 확인을 구하도록 지시하는 `SKILL.md`를 설치합니다.

```sh
brew install --cask smile-minecraft/tap/machelper
machelper guide                          # 에이전트가 가장 먼저 읽을 가이드
machelper report --json                  # 비식별화된 전체 진단 리포트 + suggestedActions
machelper insights ~ --json              # 오래 안 쓴 대용량 파일 및 비대해진 폴더
machelper clean --json                   # 정리 미리 보기. --yes 전에 사용자 확인 필요
```

언어 모델용 색인은 [llms.txt](llms.txt)에 있습니다.

## 자주 묻는 질문

**CleanMyMac이나 iStat Menus를 대체할 무료 오픈 소스 앱이 있나요?**
네. MacHelper는 MIT 라이선스이며 정리, 메뉴 막대 시스템 모니터, 팬 제어, 디스크 분석, 앱 제거를 계정이나 구독 없이 네이티브 앱 하나로 제공합니다.

**Mac의 팬 속도는 어떻게 제어하나요?**
MacHelper를 설치하고 Helper(처음 실행 시 안내)를 설정하면 됩니다. 자동, 고정 RPM, 사용자 지정 온도 곡선으로 동작시킬 수 있으며 안전 상한과 앱·전원별 자동 프로필을 지원합니다.

**개인정보를 노출하지 않고 AI 어시스턴트에게 넘길 시스템 리포트는 어떻게 얻나요?**
`machelper report --json`(또는 `--format markdown`)을 실행하세요. 하드웨어, 지표, 건강 점수, 저장 공간, 보안 점검, 정리 미리 보기, 시동 항목을 한 번에 모으면서 사용자 이름, 경로, 호스트 이름, IP, MAC 주소를 자동으로 가려 줍니다.

**터미널에서 Mac 디스크 공간을 확보하려면?**
`brew install --cask smile-minecraft/tap/machelper`로 설치한 뒤 `machelper clean`으로 미리 보고 `machelper clean --max-risk low --yes`로 저위험 캐시를 정리하세요. `machelper insights ~`는 오래 쓰지 않은 큰 파일과 비대해진 폴더를 찾아 주며, `machelper purge --path ~/Developer`는 `node_modules`, `target`, `.build` 같은 빌드 폴더를 정리합니다.

**Mac 앱을 잔여 파일까지 완전히 삭제하려면?**
`machelper uninstall "앱 이름"`으로 환경설정, 캐시, 컨테이너, 로그인 항목, Homebrew zap 항목을 미리 보고 `--yes`를 붙여 휴지통으로 옮기세요. `machelper uninstall --orphans`는 이미 삭제된 앱의 잔여 파일을 찾아 줍니다.

**Intel Mac이나 구형 macOS에서도 동작하나요?**
macOS 14 이상이 설치된 Intel Mac과 Apple Silicon Mac 모두 지원합니다(유니버설 바이너리. Intel Mac에서는 온도와 팬 제어에 SMC를 사용하며, Apple Silicon 전용 전력 세부 항목은 제공되지 않습니다). macOS 13 이하는 지원하지 않습니다.

**MacHelper는 어떤 데이터를 수집하나요?**
기본적으로는 업데이트 확인 외에 어떤 데이터도 Mac 밖으로 나가지 않습니다. **설정 → 일반 → 개인정보 보호 및 진단**에서 명시적으로 옵트인한 경우에만 파일 경로, 프로세스 이름, 개인 식별자 없이 익명 사용 횟수와 거친 성능 진단(앱 버전, macOS 버전, 칩 제품군)만 전송합니다. 언제든 정확한 JSON 페이로드를 확인하고 끌 수 있습니다.

## 소스에서 빌드

요구 사항: Mac(Apple Silicon 또는 Intel), Xcode 26 이상, [XcodeGen](https://github.com/yonaskolb/XcodeGen)(`brew install xcodegen`). `make`를 실행하면 사용 가능한 모든 타깃을 볼 수 있습니다.

```sh
make setup      # 도구 확인, Sparkle 다운로드, MacHelper.xcodeproj 생성
make open       # Xcode에서 프로젝트 열기 (⌘R로 빌드 및 실행)
make run        # 또는 Debug 빌드를 build/에 생성해 바로 실행
make test       # Swift 패키지 단위 테스트 실행
make install    # Release 빌드 → /Applications/MacHelper.app 설치 및 재실행
```

일상적인 개발 빌드는 `/Applications`를 건드리지 않고 `build/`에 생성됩니다. 두 복사본이 설정과 데이터를 공유하므로 `build/`에서 실행하기 전에는 설치된 MacHelper를 먼저 종료하세요. root Helper 변경 사항(팬 제어, 시스템 정리)을 테스트할 때는 `make install`이 가장 편리합니다. 소스 파일을 추가·삭제한 뒤에는 `make project`를 실행하고, 배터리가 없는 데스크톱 Mac에서는 `make run ARGS=--demo-battery`로 배터리 수치를 시뮬레이션할 수 있습니다.

**성능 프로파일링:** MacHelper는 디스크 스캔, 센서 샘플링, UI 핵심 경로에 Apple 네이티브 `OSSignposter` 계측을 포함하고 있으며, 개발 중 `scripts/perf/xctrace-profile.sh`를 사용해 명령줄에서 바로 Instruments 트레이스를 캡처할 수 있습니다.

<details>
<summary><b>개발자 참고: 로컬 서명 설정, 저장소 구조, 스크린샷 내보내기, 릴리스 및 번역</b></summary>

로컬 Xcode/서명 오버라이드(`Config/Local.env`, `Config/Local.xcconfig`), 전체 디렉터리 구조, README 이미지 및 슬라임 GIF 생성 플래그, 릴리스 절차, String Catalog 번역 가이드는 [영어 README](README.md#building)를 참고하세요.

</details>

## 라이선스

MIT — [LICENSE](LICENSE)를 참고하세요.
