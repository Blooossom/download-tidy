# 첫 버전 검증 기록

2026-10-16, Apple Silicon / macOS 27.0.1 / Swift 6.4.

- `zsh scripts/test.sh`: Swift Testing 10개 통과. 실제 Downloads 대신 각각 독립된 임시 폴더 사용.
- `zsh scripts/build-app.sh`: Release 빌드 성공, 앱 번들 생성 및 ad-hoc 서명.
- `codesign --verify --deep --strict`: 통과.
- 네이티브 UI: 테스트 폴더에서 ‘삼백만원’ 검색으로 파일명이 아닌 TXT 본문 일치 확인.
- 검색 결과 클릭 시 Quick Look 본문 미리보기 확인.
- 한 파일 체크 → 전체 이동 경로 검토 → 실행 → 정리됨 표시 및 이동 후 본문 검색 확인.
- 정리 기록에서 되돌리기 → ‘되돌림’ 표시 확인. 파일시스템에서도 원본 복원과 영구 기록 상태 확인.
- 수정본에서 미리보기 표시 중 제목·검색·목록·하단 정리 버튼이 창 안에 유지되는지 시각 확인.

UI 검증 폴더는 `/private/tmp/download-tidy-ui-fixture`이며 테스트 데이터만 들어 있습니다. 사용자 Downloads 파일은 이동하거나 삭제하지 않았습니다.

기술 참고: [Apple Quick Look 미리보기](https://developer.apple.com/documentation/quicklookui/qlpreviewview/previewitem). UI에는 QLPreviewView를 사용하며 메뉴 막대는 AppKit NSStatusItem으로 구성했습니다.
