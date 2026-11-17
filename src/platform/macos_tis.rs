//! Waldlust: macOS 입력 소스(한국어 ↔ 영문) 읽기·바꾸기.
//!
//! - 제어 쪽: Android 상대에 한글을 조합해 보낼지 정하려고 지금 입력 소스가 한국어인지 읽는다.
//! - 수신 쪽: 원격의 한/영 키(ControlKey::Hangul)를 받으면 입력 소스를 한국어 ↔ 영문으로 바꾼다.
//!   CGEvent 로 Caps Lock 등을 넣어서는 입력 소스가 바뀌지 않아 TIS 로 직접 고른다.
//!
//! TIS 는 메인 스레드에서 불러야 한다(macOS 14 부터 다른 스레드에서 부르면 멈출 수 있다).

use core_foundation::{
    array::{CFArray, CFArrayRef},
    base::{CFRelease, CFType, TCFType},
    boolean::CFBoolean,
    string::{CFString, CFStringRef},
};
use hbb_common::log;
use objc::{class, msg_send, runtime::BOOL, runtime::NO, sel, sel_impl};
use std::ffi::c_void;

type TISInputSourceRef = *mut c_void;

#[link(name = "Carbon", kind = "framework")]
extern "C" {
    fn TISCopyCurrentKeyboardInputSource() -> TISInputSourceRef;
    fn TISCopyCurrentASCIICapableKeyboardInputSource() -> TISInputSourceRef;
    fn TISCreateInputSourceList(properties: *const c_void, include_all_installed: u8) -> CFArrayRef;
    fn TISGetInputSourceProperty(source: TISInputSourceRef, key: CFStringRef) -> *const c_void;
    fn TISSelectInputSource(source: TISInputSourceRef) -> i32;
    static kTISPropertyInputSourceID: CFStringRef;
    static kTISPropertyInputSourceLanguages: CFStringRef;
    static kTISPropertyInputSourceIsSelectCapable: CFStringRef;
}

fn is_main_thread() -> bool {
    let b: BOOL = unsafe { msg_send![class!(NSThread), isMainThread] };
    b != NO
}

fn on_main<T: Send + 'static>(f: impl FnOnce() -> T + Send + 'static) -> T {
    if is_main_thread() {
        f()
    } else {
        dispatch::Queue::main().exec_sync(f)
    }
}

unsafe fn source_id(src: TISInputSourceRef) -> String {
    let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID);
    if p.is_null() {
        return String::new();
    }
    CFString::wrap_under_get_rule(p as CFStringRef).to_string()
}

unsafe fn first_language(src: TISInputSourceRef) -> String {
    let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages);
    if p.is_null() {
        return String::new();
    }
    let arr = CFArray::<CFString>::wrap_under_get_rule(p as CFArrayRef);
    arr.get(0).map(|s| s.to_string()).unwrap_or_default()
}

unsafe fn is_korean(src: TISInputSourceRef) -> bool {
    if src.is_null() {
        return false;
    }
    let id = source_id(src);
    if id.contains("Roman") {
        return false;
    }
    first_language(src) == "ko" || id.contains("inputmethod.Korean.")
}

unsafe fn is_select_capable(src: TISInputSourceRef) -> bool {
    let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceIsSelectCapable);
    if p.is_null() {
        return false;
    }
    CFBoolean::wrap_under_get_rule(p as _).into()
}

/// 지금 입력 소스가 한국어(한글 입력)인지.
pub fn is_korean_input_source() -> bool {
    on_main(|| unsafe {
        let cur = TISCopyCurrentKeyboardInputSource();
        let r = is_korean(cur);
        if !cur.is_null() {
            CFRelease(cur as _);
        }
        r
    })
}

/// 한국어 ↔ 영문 입력 소스를 바꾼다. 켜 둔 한국어 입력 소스가 없으면 아무것도 하지 않는다.
pub fn toggle_korean_input_source() {
    on_main(|| unsafe {
        let cur = TISCopyCurrentKeyboardInputSource();
        let cur_korean = is_korean(cur);
        if !cur.is_null() {
            CFRelease(cur as _);
        }
        if cur_korean {
            let ascii = TISCopyCurrentASCIICapableKeyboardInputSource();
            if ascii.is_null() {
                log::warn!("hangul toggle: no ASCII-capable input source");
                return;
            }
            let id = source_id(ascii);
            let st = TISSelectInputSource(ascii);
            CFRelease(ascii as _);
            log::info!("hangul toggle: -> {} ({})", id, st);
            return;
        }
        let list = TISCreateInputSourceList(std::ptr::null(), 0);
        if list.is_null() {
            log::warn!("hangul toggle: no input source list");
            return;
        }
        let list = CFArray::<CFType>::wrap_under_create_rule(list);
        for item in list.iter() {
            let src = item.as_CFTypeRef() as TISInputSourceRef;
            if is_korean(src) && is_select_capable(src) {
                let id = source_id(src);
                let st = TISSelectInputSource(src);
                log::info!("hangul toggle: -> {} ({})", id, st);
                return;
            }
        }
        log::info!("hangul toggle: no enabled Korean input source");
    })
}
