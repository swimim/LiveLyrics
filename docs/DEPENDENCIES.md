# 의존성 기록

- Swift / SwiftUI / AppKit / Foundation / URLSession: Apple SDK. 외부 Swift 패키지 없음.
- 테스트: Apple Swift Testing. CLT 단독 설치에서는 `scripts/test.sh`가 프레임워크 검색 경로와 rpath를 지정한다.
- MediaRemote 어댑터: https://github.com/ungive/mediaremote-adapter
- 고정 커밋: `797729d9b16316dc313844476c153d7a107ca0df`
- 라이선스: BSD-3-Clause, `Vendor/mediaremote-adapter/LICENSE`. 앱 Resources에도 전문을 복사한다.
- 검토 대상: Perl 로더, CMake 빌드, stream/get/test 구현, 마이크로초 및 Unix timestamp 변환.
- 사전 빌드 바이너리를 다운로드하지 않는다. CMake로 vendored Objective-C 소스를 빌드하고 ad-hoc 서명한다.
- 실행 경로: 앱 → `/usr/bin/perl` → 자체 빌드 MediaRemoteAdapter.framework. 비공개 MediaRemote 의존성은 이 공급자에만 격리한다.
- 시스템 보안 설정 변경, 관리자 권한, 데몬 주입, 인증서 검증 해제 없음.
- 원본 저장소를 submodule로 고정한다. 일반 clone 후 `git submodule update --init --recursive`로 가져온다. 의존성 업데이트는 명시적으로 검토 후 진행한다.

API 문서 확인: 2026-10-14, https://lrclib.net/docs 의 공식 웹 클라이언트에 포함된 문서 내용.
순차 요청, 식별 헤더, Retry-After, 선택적 앨범/길이 조건을 반영했다.
LRCLIB 식별 이메일 또는 프로젝트 URL은 사용자별로 메뉴에서 등록하며, 현재 macOS 계정의 UserDefaults에 저장한다. 유효한 연락처 입력 전에는 네트워크 조회를 보내지 않는다.
