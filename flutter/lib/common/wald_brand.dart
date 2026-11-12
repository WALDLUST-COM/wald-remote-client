import 'package:flutter_hbb/models/platform_model.dart';

/// Waldlust(DSK-01, 결정 D53·D54): 브랜드 전용 빌드의 코드(빌드 환경변수 WALDLUST_BRAND — src/wald_brand.rs).
/// 일반 빌드는 빈 문자열이다. D54 부터 브랜드 전용 빌드는 수신 전용만 있다(build.rs 가 다른 변형을 거절한다).
/// 코드는 로그인 요청(common/hbbs/hbbs.dart)·heartbeat·새 버전 확인에 실리고, 화면에는 수신 전용 이름표와
/// 정보 창 '브랜드' 줄로만 보인다. 양방향 화면의 범위(브랜드 계정이면 '발견됨' 탭 숨김)는 빌드가 아니라
/// 로그인한 계정의 사용자 정보 wald_brand_scope 로 정한다(models/peer_tab_model.dart).
/// 처음 읽을 때 한 번만 가져온다(빌드에 구운 값이라 바뀌지 않는다).
final String waldBrandCode = bind.mainGetCommonSync(key: 'wald-brand');

bool get isWaldBrandBuild => waldBrandCode.isNotEmpty;

/// 화면에 보이는 브랜드 이름(빌드 환경변수 WALDLUST_BRAND_NAME — 없으면 빈 문자열). 표시용이다.
/// 수신 전용 홈의 ID 줄·앱바와 정보(ⓘ) 창에 보인다(common/widgets/wald_app_info.dart).
final String waldBrandName = bind.mainGetCommonSync(key: 'wald-brand-name');

/// 정보 창 '브랜드' 줄의 값: 이름(코드). 이름이 없으면 코드만.
String get waldBrandInfoText =>
    waldBrandName.isEmpty ? waldBrandCode : '$waldBrandName ($waldBrandCode)';
