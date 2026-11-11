# RDALL — 리데탑

RustDesk 기반의 개인용 원격 접속 프로젝트. 첫 대상은 안드로이드 클라이언트에서
맥 호스트로 접속하는 흐름이다. 기존 Windows/Linux 지원은 유지한다.

- Upstream: https://github.com/rustdesk/rustdesk
- 최초 기준 커밋: `e4368ab11913ce93ead0f8194b9d5ab339868fd6` (RustDesk 1.5.3)
- Fork: https://github.com/robotmanaiautomation/RDALL
- Android application ID: `com.rdall.app` (기존 RustDesk와 별도 설치)
- 표시 이름: RDALL / 한국어 시스템에서는 리데탑
- Android 연결 링크: `rdall://`
- 원본 AGPL-3.0 라이선스와 저작권 고지는 유지한다.

## 첫 구현: 연결 지연 진단

기존 RustDesk 전송 프로토콜을 사용하므로 맥에는 RustDesk 호스트가 필요하다.
macOS 기본 화면 공유/VNC 서버에 직접 접속하는 앱은 아니다.
이번 변경은 진단을 추가하며 자동 해상도 변경이나 전송 방식 변경은 포함하지 않는다.

새 로그는 `RDALL_DIAG {JSON}` 형식이며 연결 시도별 `attempt` 번호로 묶는다.
번호는 프로세스 내에서 고유하며 앱을 재실행하면 다시 시작한다. 다른 실행의 로그를
분석할 때는 파일을 구분한다. 재접속은 새 시도로 기록한다.

주요 단계:

1. `transport`: ID 서버 선택, IPv6/UDP/WebRTC 사전 준비, ID 서버 접속,
   NAT 통과 시도, 직접/중계 경로 선택, 보안 핸드셰이크.
   세부 이벤트의 `path`는 동시에 경쟁하는 `preferred` / `tcp_fallback` 경로를 구분한다.
2. `authentication`: 전송 연결 이후 인증 완료까지.
   비밀번호 입력, 상대편 승인, 신뢰 확인 등 사람의 대기 시간도 포함한다.
   `authentication_challenge_received`, `credentials_submitted`,
   `authentication_rejected`, `authentication_accepted`로 구간을 확인한다.
3. `await_video`: 인증 완료 후 첫 압축 영상 메시지까지.
   맥의 캡처·인코딩 준비와 네트워크 전송 시간이 합쳐진 값이다.
4. `decode`: 첫 압축 영상 메시지부터 첫 디코딩 성공까지.
   디코더 초기화·키 프레임 대기·큐 대기·색상 변환이 포함될 수 있다.
5. `streaming`: 디코딩 성공 이후. `first_frame_submitted`는 UI 핸들러에
   이미지를 전달한 시점이며 실제 디스플레이 표시 완료나 입력-화면 왕복 지연은 아니다.
6. `closed`: 종료 또는 취소. 도중 실패도 직전 단계의 경과 시간이 남는다.

연결을 기다리는 중에도 별도 비동기 작업이 5초 간격으로 `sample`을 기록한다.
수신 패킷이 없다고 로그 자체가 멈추지 않으며 연결 종료 시 작업을 중단한다.

| 필드 | 의미 |
|---|---|
| `elapsed_ms`, `phase_ms` | monotonic clock 기준 전체/현재 단계 경과 시간 |
| `direct`, `transport` | 선택된 직접/중계 여부와 TCP/KCP/WebRTC 등 전송 종류 |
| `payload_bytes`, `payload_kbps` | 실제 관측 간격 동안 받은 애플리케이션 페이로드. 화면 외 메시지도 포함하며 TCP/UDP/TLS/VPN 헤더 및 재전송은 제외 |
| `video_messages`, `decoded_frames`, `decoded_fps` | 수신 영상 메시지 수와 디코딩 성공 수/초. 메시지당 영상 프레임 수는 다를 수 있음 |
| `decode_mean_ms`, `decode_max_ms` | 성공한 프레임 처리 시간. 디코더 초기화와 색상 변환 포함, UI 전달 전까지 측정 |
| `queue_max`, `queue_overflows` | 클라이언트 영상 큐 관측 최대 길이와 오래된 메시지 밀어내기 횟수. 네트워크 패킷 손실 수가 아님 |
| `decode_errors` | 프레임 처리 오류 횟수 |
| `last_video_age_ms` | 마지막 영상 메시지 이후 경과 시간. 정적인 화면에서도 커질 수 있음 |
| `host_reported_delay_ms` | 호스트가 보고한 지연. 순수 네트워크 RTT 또는 입력 지연으로 단정할 수 없음 |
| `target_bitrate_kbps` | 호스트 인코더 목표 비트레이트. 실측 수신량과 별개 |
| `remote_display` | 원격 디스플레이의 픽셀 크기. 화면 내용은 기록하지 않음 |

코덱 이름만으로 하드웨어 가속 여부를 보장하지 않는다. 맥의 인코더 실패나 캡처 권한
문제를 확정하려면 맥 호스트 로그도 함께 확인해야 한다. 현재 단계는 클라이언트 관측을 제공한다.

## 로그 수집과 분석

디버그/릴리스 Android 빌드 모두 새 진단 이벤트를 logcat으로 출력한다.
릴리스에서는 기존 RustDesk 파일 로그에도 함께 기록한다.

```sh
# 연결 전에 수집을 시작하고 연결 종료 후 Ctrl-C.
adb -e logcat -v threadtime > /tmp/rdall-logcat.txt
python3 tools/rdall/analyze_connection.py /tmp/rdall-logcat.txt > /tmp/rdall-report.json
```

분석기는 `RDALL_DIAG` 레코드만 추출하고 시도별 첫 영상/첫 UI 전달 시간,
단계별 소요 시간, 중계 전환·디코더 오류·큐 넘침 증거를 JSON으로 출력한다.
한 개 관측 구간에서 평균 디코딩 작업이 33.33ms를 넘으면 30fps 처리 예산 초과로
표시한다. 이는 목표 프레임률이 30fps라는 단정이나 지연의 확정 원인이 아니다.

새 진단 레코드는 주소·ID·암호·토큰·화면·키 입력을 기록하지 않는다.
원본 RustDesk 로그나 전체 logcat에는 별도 정보가 있을 수 있으므로 공유용으로는
분석기 결과를 사용한다.

## Tailscale 주소 저장

Android 연결 화면의 **저장한 Tailscale 기기 → +**에서 기기 이름과 주소를 입력한다.
목록의 기기를 누르면 기존 직접 IP 접속 경로로 연결한다. 오른쪽 메뉴에서 수정·삭제한다.
연결하지 않아도 저장되며 앱을 다시 열어도 유지된다. 입력창에 유효한 주소가 있으면
추가 대화상자에 미리 채운다.

- IPv4: `100.90.80.70` 또는 `100.90.80.70:21118`
- 전체 MagicDNS 이름: `my-mac.tailnet.ts.net` 또는 `my-mac.tailnet.ts.net:21118`
- 포트 생략 시 `21118`. 포트 범위는 `1–65535`.
- 짧은 기기 이름(`my-mac`)과 IPv6는 이 저장 UI에서 지원하지 않는다.
  기존 RustDesk 직접 접속 판별과 맞는 주소만 저장하기 위한 초기 지원 범위다.
- 이름과 주소는 기존 로컬 설정의 `rdall-saved-tailscale-hosts` 키에 JSON으로 저장한다.
  암호나 Tailscale 계정은 저장하지 않는다. 중복 주소와 잘못된 주소는 저장을 거부한다.
- 양쪽 기기의 Tailscale 연결과 맥 RustDesk의 직접 IP 접근 허용은 별도로 필요하다.

검증: `flutter test test/saved_tailscale_hosts_test.dart`의 UI 테스트 3개로
저장 후 화면 재생성·접속, MagicDNS 수정·삭제, 잘못된/중복 주소 거부를 확인한다.
기존 코드의 실행 경로 변경은 `connection_page.dart`의 Android 연결 화면에
독립적인 목록 위젯을 추가하는 부분뿐이다. 저장은 기존 로컬 설정 API,
접속은 기존 `connect(context, address)`를 사용한다. 별도 FFI나 전송 프로토콜은 추가하지 않는다.

## 검증

네이티브 코덱/Flutter SDK 없이 진단 로직과 분석기를 검증할 수 있다.

```sh
rustc --edition 2021 --test src/client/diagnostics.rs -o /tmp/rdall-diagnostics-tests
/tmp/rdall-diagnostics-tests
python3 -m unittest discover -s tools/rdall -p 'test_*.py'
```

이 검증은 전체 앱 컴파일 또는 실제 맥 연결 테스트를 대신하지 않는다.
전체 빌드는 upstream의 `.github/workflows/bridge.yml`,
`.github/workflows/flutter-build.yml` Android 작업과 `flutter/ndk_arm64.sh`를 기준으로 한다.
Flutter 브리지 생성, Android NDK, vcpkg 네이티브 코덱 의존성이 필요하다.

2026-11-11 초기 검증: Rust 진단 테스트 5개, Python 분석기 테스트 4개 통과.
변경한 Rust 연결 코드의 구문 파싱, Android XML 파싱 및 `git diff --check`도 통과했다.
`cargo check --lib --features flutter`는 의존성 다운로드 후
`libs/scrap/build.rs`에서 `/opt/homebrew/Cellar/libyuv` 부재로 중단됐다.
초기 시점에는 Flutter SDK와 생성된 Flutter/Rust 브리지도 없었다.
전체 앱 컴파일, APK 실행, 실제 맥 연결/4G 성능은 아직 검증하지 않았다.
주소 저장 기능 작업 중 로컬 Flutter 3.24.5 SDK를 준비했고 해당 기능의
Flutter 위젯 테스트와 정적 분석을 실행했다. 전체 앱 빌드 검증과는 별개다.

실기기 수용 기준: 같은 맥에 같은 1080p 설정으로 Wi-Fi와 4G 연결을 각각 실행해
첫 영상/첫 UI 전달 시간, 선택 경로, 코덱, 큐 넘침, 디코딩 시간을 비교한다.
인증 대기·맥 캡처 준비·클라이언트 디코딩을 분리한 뒤 성능 변경을 진행한다.
