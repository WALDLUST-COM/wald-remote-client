//! Waldlust: 앱 안 업데이트 서명 확인(명세 P0-02 — 보안 재점검 2026-11-13 H2).
//!
//! 어드민 `/api/app/latest` 가 주는 SHA-256 만 믿으면, 어드민 서버를 장악한 사람이 설치 파일과 해시를 함께 바꿔
//! 현장 Windows(SYSTEM 이 UAC 없이 설치한다)에 코드를 깔 수 있다. 그래서 게시 PC 가 서버 밖에 둔 개인키로
//! "어느 빌드의 무슨 파일인가"를 서명하고(어드민 `scripts/publish-installer.sh`), 앱은 여기 넣은 공개키로 확인한다.
//! 서버는 서명을 전달만 한다(`updateSig`) — 개인키가 없어 서명을 만들 수 없다.
//!
//! 서명 문서(UTF-8, 줄 끝 `\n`, 마지막 줄에도 `\n`)는 게시 스크립트와 글자 하나까지 같아야 한다:
//! ```text
//! waldlust-update-v1
//! os=<windows|macos|android>
//! variant=<bidirectional|incoming|outgoing>
//! arch=<x86 또는 빈 값>
//! brand=<브랜드 코드 또는 빈 값>
//! version=<버전>
//! sha256=<소문자 hex 64자>
//! size=<바이트 수>
//! ```
//! os·variant·arch·brand 는 앱이 제 값으로 채운다. 그래서 서명이 맞으면 이 빌드에 맞는 설치 파일이기도 하다
//! (다른 변형·브랜드·32/64비트 파일은 서명이 맞지 않는다). arch 는 어드민 카탈로그와 같게 32비트 Windows 만 `x86` 이다.

use hbb_common::{base64, sodiumoxide::crypto::sign};

/// 게시 키의 공개키(Ed25519 32바이트, 표준 base64). 앞 = 주 키, 뒤 = 예비 키.
/// 개인키는 게시 PC(Mac)의 `~/wald-build/keys/update-signing-ed25519.pem`·`…-spare.pem` 에만 둔다(저장소·서버에 두지 않는다).
/// 주 키를 잃거나 유출되면 예비 키로 서명해 게시하고, 다음 빌드에서 이 목록을 새 주 키·새 예비 키로 바꾼다
/// (유출이면 옛 주 키를 뺀다). 이미 깔린 앱은 이 목록에 든 키만 믿는다.
pub(crate) const UPDATE_SIGN_KEYS: &[&str] = &[
    "CY+ogYnPPWh2NJEeZc8Yc1/gv5TmkR0Al+RUF/iu2/0=",
    "1m9eD6yuLvOAKgxgcxsKKPlMbiFlzApGUqWJUhfdCG8=",
];

const LABEL: &str = "waldlust-update-v1";

/// 서명 문서. os·variant·arch·brand = 이 빌드, 나머지 = 어드민이 알린 게시 정보.
pub(crate) fn payload(
    os: &str,
    variant: &str,
    arch: &str,
    brand: &str,
    version: &str,
    sha256: &str,
    size: u64,
) -> String {
    format!(
        "{LABEL}\nos={os}\nvariant={variant}\narch={arch}\nbrand={brand}\nversion={version}\nsha256={sha256}\nsize={size}\n"
    )
}

/// 이 빌드의 서명 문서 — 어드민 카탈로그의 match 와 같은 값(arch 는 32비트 Windows 만 `x86`).
pub(crate) fn payload_for_this_build(version: &str, sha256: &str, size: u64) -> String {
    let arch = if std::env::consts::ARCH == "x86" { "x86" } else { "" };
    payload(
        std::env::consts::OS,
        crate::wald_variant::name(),
        arch,
        crate::wald_brand::code(),
        version,
        sha256,
        size,
    )
}

/// `sig_b64`(표준 base64, 64바이트)가 `keys` 가운데 하나로 `doc` 에 맞는 서명인가. 형식이 틀리면 false.
pub(crate) fn verify(sig_b64: &str, doc: &[u8], keys: &[&str]) -> bool {
    #[allow(deprecated)]
    let Ok(raw) = base64::decode(sig_b64.trim()) else {
        return false;
    };
    let Ok(sig) = sign::Signature::from_bytes(&raw) else {
        return false;
    };
    keys.iter().any(|k| {
        #[allow(deprecated)]
        let pk = base64::decode(k).ok().and_then(|b| sign::PublicKey::from_slice(&b));
        pk.map_or(false, |pk| sign::verify_detached(&sig, doc, &pk))
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc() -> String {
        payload(
            "windows",
            "incoming",
            "x86",
            "",
            "1.5.13",
            &"ab".repeat(32),
            24125624,
        )
    }

    #[test]
    fn test_payload_format() {
        assert_eq!(
            doc(),
            format!(
                "waldlust-update-v1\nos=windows\nvariant=incoming\narch=x86\nbrand=\nversion=1.5.13\nsha256={}\nsize=24125624\n",
                "ab".repeat(32)
            )
        );
    }

    // 게시 스크립트(Node crypto.sign — Ed25519)로 만든 서명이 여기서 맞아야 한다. 시험용 일회 키다(게시 키 아님).
    #[test]
    fn test_verify_node_signature() {
        const PUB: &str = "3C2JhgxnHzZeEsfWB3vJsO55BhFwMfHREXuv8EMi/AM=";
        const SIG: &str = "mqj8WqxeC9trpDdzKOdXrzssYWwzcQ5J+cR4d3MQuaPStHErPEvqi1CRHfgwHkm6PsqChqTCHsCUlLd46qPNDA==";
        assert!(verify(SIG, doc().as_bytes(), &[PUB]));
        // 예비 키 자리에 있어도 맞는다
        assert!(verify(SIG, doc().as_bytes(), &[UPDATE_SIGN_KEYS[0], PUB]));
        // 문서가 한 글자라도 다르면(64비트 빌드·다른 해시·브랜드 빌드) 틀린다
        let other = doc().replace("arch=x86", "arch=");
        assert!(!verify(SIG, other.as_bytes(), &[PUB]));
        let other = doc().replace("brand=\n", "brand=k7m2x9qdab\n");
        assert!(!verify(SIG, other.as_bytes(), &[PUB]));
        // 게시 키로는 맞지 않는다
        assert!(!verify(SIG, doc().as_bytes(), UPDATE_SIGN_KEYS));
    }

    #[test]
    fn test_verify_rejects_malformed() {
        let d = doc();
        assert!(!verify("", d.as_bytes(), UPDATE_SIGN_KEYS));
        assert!(!verify("not base64!", d.as_bytes(), UPDATE_SIGN_KEYS));
        assert!(!verify("AAAA", d.as_bytes(), UPDATE_SIGN_KEYS));
        assert!(!verify(&"A".repeat(88), d.as_bytes(), &["bad key"]));
    }

    #[test]
    fn test_update_sign_keys_are_valid() {
        assert_eq!(UPDATE_SIGN_KEYS.len(), 2);
        for k in UPDATE_SIGN_KEYS {
            #[allow(deprecated)]
            let b = base64::decode(k).unwrap();
            assert!(sign::PublicKey::from_slice(&b).is_some(), "{k}");
        }
    }
}
