AGENTS.md
@AGENTS.md

<!-- wald-remote fork only: 첫 줄 `AGENTS.md` 는 업스트림 원문이라 그대로 둔다(병합 충돌 최소화). 둘째 줄 import 와 이 아래는 포크가 덧붙였다 -->
## Claude Code 작업 메모
- 공통 규칙(구조·Rust·Tokio·Editing Hygiene·번역)은 위에서 import 한 `AGENTS.md` 를 따른다. `AGENTS.md` 는 업스트림 소유라 고치지 않는다. 포크 규칙은 이 파일에 적는다.
- 기본 브랜치는 `waldlust` 다. 클론은 `git clone --recursive`(이미 받았으면 `git submodule update --init --recursive`)로 한다. 서브모듈 `libs/hbb_common` 도 포크 저장소의 `waldlust` 브랜치를 가리킨다(`.gitmodules`).
- `origin/master` 는 업스트림 미러다(2026-09-29 기준 분기점 4a54029ca 에 멈춰 있다). 포크 고유 변경은 `git log origin/master..HEAD` 와 `git diff --submodule=diff origin/master...HEAD`(서브모듈 포함)로 본다.
- `git diff 1.4.8` 은 쓰지 않는다. 포크는 1.4.8 태그 뒤 업스트림 17커밋에서 갈라져 업스트림 변경이 섞인다. 1.4.8 태그(`origin` 에도 있다)는 명세 코드 힌트(`rustdesk@1.4.8:…`)를 열 때만 쓴다. `upstream`(rustdesk/rustdesk) 리모트는 업스트림 최신이 필요할 때만 추가한다.
- 포크 빌드 워크플로는 `.github/workflows/wald-*.yml` 이다(전부 수동 `workflow_dispatch`). Secret `WALDLUST_PRESET_PASSWORD` 가 있으면 관리(무인 키오스크) 빌드가 된다. 이 값은 표식일 뿐 접속 비밀번호가 아니다. 접속 비밀번호는 기기마다 랜덤으로 만들어 heartbeat 로 어드민에 보고한다(`src/common.rs` 의 `set_waldlust_preset_password`).
- 빌드 변형(DSK-01): `WALDLUST_VARIANT` 를 비우거나 `bidirectional` 이면 양방향(위 관리·비관리 규칙 그대로), `incoming` 이면 수신 전용이다(`src/wald_variant.rs`, 프리셋 `res/wald-variant/incoming.json`). 수신 전용은 전 기기 공통 영구 비밀번호의 해시(`WALDLUST_INCOMING_PW_STORAGE`·`WALDLUST_INCOMING_PW_SALT`)가 없으면 `build.rs` 에서 실패한다. 해시는 `res/wald-variant/preset_hash.py` 로 만들고 평문은 환경변수 `WALDLUST_INCOMING_PASSWORD` 로만 넘긴다(저장소·로그에 쓰지 않는다). 솔트는 비밀번호를 바꿀 때만 바꾼다(제어측이 기억한 비밀번호가 솔트에 묶인다). 옛 `WALDLUST_PRESET_PASSWORD` 값을 공통 비밀번호로 다시 쓰지 않는다(명세 F-09). 로컬 테스트는 운영 값이 아닌 테스트 비밀번호로 한다.
- 로컬 테스트 빌드는 `WALDLUST_PRESET_PASSWORD` 없이(비관리 빌드) 하고, `WALDLUST_HEARTBEAT_URL` 을 더미(예 `http://127.0.0.1:9/api/heartbeat`)로 줘서 운영 어드민에 보고하지 않게 한다. 로컬 Android 빌드 절차·주의점은 명세 F-46.
- 포크는 `api-server` 를 설정하지 않아 데스크탑 로그인·주소록 요청이 `https://admin.rustdesk.com` 으로 간다(명세 F-39). DSK-01 에서 `api-server` 를 고정하기 전에는 실제 운영자 계정으로 로그인을 시험하지 않는다.
- 비밀번호·키·토큰으로 의심되는 값은 대화 출력·커밋·PR·로그에 원문으로 쓰지 않는다. 파일:줄, 길이, 5자 이내 접두만 적는다(명세 §0 규칙 7). 검색 결과를 옮길 때도 값을 가린다.
- 이 저장소와 `hbb_common` 포크는 공개 저장소다. 명세·인수인계 문서·인계 산출물·운영 서버 정보는 커밋하지 않는다(명세 Q-43). `docs/HANDOVER_SPEC.md`(명세), `docs/HANDOVER.md`(인수인계 문서 원본), 인계 산출물(`docs/handover/` 등 명세 §6 경로)의 정본은 비공개 저장소 `WALDLUST-COM/wald-remote-docs` 다. 이 작업 폴더에는 링크로 두고 `.git/info/exclude` 로 뺀다. 새 PC 설정과 새 산출물 추가는 그 저장소 README 를 따른다.
- `docs/HANDOVER_SPEC.md` 는 통째로 읽지 않는다. `grep -n '^#' docs/HANDOVER_SPEC.md` 로 절 위치를 찾아 그 범위만 연다.

<!-- wald-remote fork only. docs/HANDOVER_SPEC.md 는 수만 토큰이라 @import 하지 않는다 -->
## wald-remote 포크 작업 규칙
- 작업 전 `docs/HANDOVER_SPEC.md` 의 §0 사용 규칙·§3 용어집, 그리고 맡은 요구의 '관련 Q'(★ = 차단)와 '의존'을 확인한다. 착수 조건이 안 되면 착수하지 않는다.
- 저장소·CI·관리 빌드·heartbeat·API 서버·운영 인프라의 확인된 사실은 명세 §2(F-32 이후)와 부록 C(인수인계 문서 요지, 원본은 `docs/HANDOVER.md`)에 있다. 운영 서버·어드민 작업은 이 저장소 밖(비공개 저장소)에서 한다.
- 커밋·PR 제목에 요구 ID(P0-xx, ADM-xx, DSK-xx, UI-xx, SRV-xx)를 적는다. 예: `feat(DSK-08): 로컬 파일 더블클릭 열기`
- 업스트림 기준 버전은 1.4.8 이고 포크 분기점은 그 뒤 17커밋이다(명세 F-33). 업스트림 파일은 최소 diff 로 고친다(AGENTS.md 'Editing Hygiene').
