//! Waldlust: 브랜드 전용 빌드(DSK-01, 결정 D53).
//!
//! 빌드 환경변수 `WALDLUST_BRAND` 에 브랜드 코드(소문자·숫자 8~12자 — 어드민이 브랜드마다 한 번 발급한다)를 주면
//! 그 브랜드 전용 빌드가 된다. 비우면 일반 빌드다. 형식 검사는 build.rs 가 한다.
//! 코드는 로그인 요청(화면 — `main_get_common("wald-brand")`), 포크 heartbeat, 새 버전 확인 요청에 실린다.
//! 서버가 이 값으로 범위를 좁힌다: 그 브랜드 계정(과 관리자 이상)만 로그인되고, 주소록은 그 브랜드만 보이고,
//! 앱 안 업데이트는 그 브랜드의 설치 파일만 받는다. 코드는 바이너리에 들어가므로 비밀이 아니다 — 인증이 아니라
//! 범위를 좁히는 값이다. 이 저장소에는 브랜드 이름도 실제 코드도 두지 않는다(테스트는 가짜 코드를 쓴다).

const BRAND: Option<&str> = option_env!("WALDLUST_BRAND");

/// 이 빌드의 브랜드 코드. 일반 빌드는 빈 문자열.
pub fn code() -> &'static str {
    match BRAND {
        Some(c) if is_code(c) => c,
        _ => "",
    }
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

    // 테스트 빌드는 WALDLUST_BRAND 없이 돈다 — 그때 code() 는 비어 있다. 값을 주고 돌리면 그 값이 형식에 맞아야 한다.
    #[test]
    fn test_code_is_empty_or_valid() {
        assert!(code().is_empty() || is_code(code()));
    }
}
