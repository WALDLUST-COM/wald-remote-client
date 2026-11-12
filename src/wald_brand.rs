//! Waldlust: 브랜드 전용 빌드(DSK-01, 결정 D53 — D54 로 수신 전용만).
//!
//! 결정 D54(2026-11-12): 브랜드 전용 빌드는 수신 전용(`WALDLUST_VARIANT=incoming`)만 만든다 — build.rs 가 다른 변형에
//! 코드를 주면 빌드를 멈춘다. 양방향·발신 전용은 일반 빌드 하나이고, 범위는 계정 로그인으로만 정한다(서버가 브랜드 계정에
//! 자기 브랜드만 내주고, 사용자 정보 `wald_brand_scope` 가 true 면 화면이 '발견됨' 탭을 숨긴다).
//!
//! 빌드 환경변수 `WALDLUST_BRAND` 에 브랜드 코드(소문자·숫자 8~12자 — 어드민이 브랜드마다 한 번 발급한다)를 주면
//! 그 브랜드 전용 빌드가 된다. 비우면 일반 빌드다. 형식 검사는 build.rs 가 하고, 값은 표식 문자열
//! `wald-brand-build:<코드>`(일반 빌드는 `wald-brand-build:none`)로 넘겨준다 — 빌드 스크립트가 결과물에서 이 표식을
//! 찾아 브랜드가 맞게 들어갔는지(또는 일반 빌드에 브랜드가 섞이지 않았는지) 확인한다.
//! 코드는 로그인 요청(화면 — `main_get_common("wald-brand")`), 포크 heartbeat, 새 버전 확인 요청에 실린다.
//! 서버가 이 값으로 범위를 좁힌다: 그 브랜드 계정(과 관리자 이상)만 로그인되고, 주소록은 그 브랜드만 보이고,
//! 앱 안 업데이트는 그 브랜드의 설치 파일만 받는다. 코드는 바이너리에 들어가므로 비밀이 아니다 — 인증이 아니라
//! 범위를 좁히는 값이다. 이 저장소에는 브랜드 이름도 실제 코드도 두지 않는다(테스트는 가짜 코드를 쓴다).
//!
//! 화면 표시(2026-11-10 사용자): 빌드 환경변수 `WALDLUST_BRAND_NAME`(선택, 30자 이하)에 브랜드 이름을 주면 수신 전용 홈의
//! ID 줄과 정보(ⓘ) 창에 보인다 — 현장에서 이 앱이 어느 브랜드용인지 네트워크 없이 확인한다. 이름은 표시용일 뿐 서버로
//! 보내지 않고 어떤 판정에도 쓰지 않는다. 이름을 바꾸려면 다시 빌드한다.

// build.rs(check_waldlust_brand)가 넣는다. 접두(wald-brand-build:)는 여기 따로 적지 않는다 — 결과물에 표식이 하나만 남게.
const MARK: &str = env!("WALDLUST_BRAND_MARK");

/// 이 빌드의 브랜드 코드. 일반 빌드는 빈 문자열.
pub fn code() -> &'static str {
    // black_box: 표식 문자열이 통째로 결과물에 남게 한다(짧은 문자열은 컴파일러가 쪼개 넣어 찾을 수 없다).
    code_of(std::hint::black_box(MARK))
}

// 표식의 마지막 ':' 뒤가 코드다(일반 빌드의 none 은 코드 형식이 아니다).
fn code_of(mark: &str) -> &str {
    match mark.rsplit_once(':') {
        Some((_, c)) if is_code(c) => c,
        _ => "",
    }
}

/// 화면에 보이는 브랜드 이름(build.rs 가 WALDLUST_BRAND_NAME 을 넘긴다). 일반 빌드와 이름을 주지 않은 브랜드 빌드는 빈 문자열.
pub fn name() -> &'static str {
    if code().is_empty() {
        return "";
    }
    env!("WALDLUST_BRAND_NAME_BUILD")
}

/// 브랜드 코드 형식: 소문자·숫자 8~12자(어드민 lib/brandcode.ts 와 같다).
pub(crate) fn is_code(s: &str) -> bool {
    (8..=12).contains(&s.len())
        && s.bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
}

/// 새 버전 확인 응답의 `brand` 가 이 빌드의 것인가. 브랜드 빌드는 제 코드와 같아야 하고, 일반 빌드는 값이 없어야 한다.
/// 서버가 잘못 내려줘도 다른 브랜드(또는 일반) 설치 파일로 덮어 설치하지 않게 하는 두 번째 확인이다 —
/// 덮이면 접속 비밀번호와 로그인 범위가 그 빌드의 것으로 바뀐다.
// 앱 안 업데이트(src/wald_update.rs)가 있는 플랫폼만 쓴다.
#[allow(dead_code)]
pub(crate) fn response_matches(own: &str, reported: Option<&str>) -> bool {
    reported.unwrap_or_default() == own
}

#[cfg(test)]
mod tests {
    use super::*;

    // 가짜 코드(실제 브랜드 아님).
    const FAKE: &str = "testbrand2";

    #[test]
    fn test_is_code() {
        assert!(is_code("abcd2345"));
        assert!(is_code(FAKE));
        assert!(is_code("abcdefgh2345"));
        assert!(!is_code(""));
        assert!(!is_code("abc2345"));
        assert!(!is_code("abcdefgh23456"));
        assert!(!is_code("ABCD2345"));
        assert!(!is_code("abcd-345"));
        assert!(!is_code("abcd 345"));
        assert!(!is_code("../abcd23"));
        assert!(!is_code("브랜드코드12"));
    }

    #[test]
    fn test_response_matches() {
        // 브랜드 빌드: 응답의 brand 가 제 코드일 때만.
        assert!(response_matches(FAKE, Some(FAKE)));
        assert!(!response_matches(FAKE, None));
        assert!(!response_matches(FAKE, Some("")));
        assert!(!response_matches(FAKE, Some("otherbrand1")));
        // 일반 빌드: 응답에 brand 가 없을 때만.
        assert!(response_matches("", None));
        assert!(response_matches("", Some("")));
        assert!(!response_matches("", Some(FAKE)));
    }

    #[test]
    fn test_code_of_mark() {
        assert_eq!(code_of("wald-brand-build:testbrand2"), FAKE);
        assert_eq!(code_of("wald-brand-build:none"), "");
        assert_eq!(code_of("wald-brand-build:"), "");
        assert_eq!(code_of("wald-brand-build:BAD CODE"), "");
        assert_eq!(code_of("testbrand2"), "");
        assert_eq!(code_of(""), "");
    }

    // 테스트 빌드는 보통 WALDLUST_BRAND 없이 돈다 — 그때 표식은 none 이고 code() 는 비어 있다.
    // 값을 주고 돌리면 그 값이 형식에 맞아야 한다.
    #[test]
    fn test_build_mark() {
        let (prefix, value) = MARK.rsplit_once(':').unwrap();
        assert_eq!(prefix, "wald-brand-build");
        assert!(value == "none" || is_code(value));
        assert_eq!(code().is_empty(), value == "none");
        // 이름은 브랜드 빌드에만 있다.
        assert!(!code().is_empty() || name().is_empty());
        assert!(name().chars().count() <= 30);
    }
}
