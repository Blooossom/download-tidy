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

## v0.2.0 검증

- `zsh scripts/test.sh`: 기존 테스트와 커스텀 폴더 테스트와 `/private/tmp` 경로 회귀 테스트를 포함한 16개 통과.
- 커스텀 폴더 미리보기에서 폴더가 생성되지 않는지, 서로 다른 종류와 기타 파일을 실제 이동할 수 있는지 확인.
- 앱 재실행에 해당하는 기록 재로딩 후 커스텀 폴더 파일 탐색·본문 검색·되돌리기 확인.
- 기존 커스텀 폴더의 이름 충돌, 잘못된 이름·경로 이탈, 파일·링크 목적지, 미리보기 이후 링크 교체를 검증.

- UI에서 카테고리 글자와 개수 사이의 빈 공간 클릭으로 분류가 전환되는지 확인.
- UI에서 ‘가을 프로젝트’를 입력해 새 폴더를 생성하고 파일 이동·정리 기록·되돌리기까지 확인.
- Release 앱 서명 검증 통과. 바탕화면 `줍줍.app` 바로가기가 현재 앱을 가리키는지 확인.
