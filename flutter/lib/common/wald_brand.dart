import 'package:flutter_hbb/models/platform_model.dart';

/// Waldlust(DSK-01, 결정 D53): 브랜드 전용 빌드의 코드(빌드 환경변수 WALDLUST_BRAND — src/wald_brand.rs).
/// 일반 빌드는 빈 문자열이다. 코드는 로그인 요청에 실리고(common/hbbs/hbbs.dart), 서버가 그 브랜드 계정만
/// 로그인시키고 주소록을 그 브랜드로 좁힌다. 화면은 '발견됨' 탭과 주소록의 '전체' 항목을 숨긴다.
/// 처음 읽을 때 한 번만 가져온다(빌드에 구운 값이라 바뀌지 않는다).
final String waldBrandCode = bind.mainGetCommonSync(key: 'wald-brand');

bool get isWaldBrandBuild => waldBrandCode.isNotEmpty;
