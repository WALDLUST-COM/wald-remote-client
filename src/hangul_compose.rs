//! 두벌식 한글 조합기 (Waldlust).
//!
//! Android 상대는 입력기 없이 접근성으로 글자를 넣기 때문에 원격에서 한글을 조합할 곳이 없다.
//! 그래서 제어 PC 가 자모를 조합하고, 화면에 이미 넣은 조합 중 글자를 지우고 새 글자를 넣는
//! 편집(`Edit`)으로 바꿔 보낸다. 이 모듈은 순수 로직만 담는다(키 이벤트 연결은 keyboard.rs).

/// 원격에 적용할 편집: 커서 앞 글자 `backspaces` 개를 지운 뒤 `text` 를 넣는다.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Edit {
    pub backspaces: usize,
    pub text: String,
}

const CHO: [char; 19] = [
    'ㄱ', 'ㄲ', 'ㄴ', 'ㄷ', 'ㄸ', 'ㄹ', 'ㅁ', 'ㅂ', 'ㅃ', 'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅉ', 'ㅊ', 'ㅋ', 'ㅌ',
    'ㅍ', 'ㅎ',
];
const JUNG: [char; 21] = [
    'ㅏ', 'ㅐ', 'ㅑ', 'ㅒ', 'ㅓ', 'ㅔ', 'ㅕ', 'ㅖ', 'ㅗ', 'ㅘ', 'ㅙ', 'ㅚ', 'ㅛ', 'ㅜ', 'ㅝ', 'ㅞ', 'ㅟ',
    'ㅠ', 'ㅡ', 'ㅢ', 'ㅣ',
];
// 0 번은 받침 없음.
const JONG: [char; 28] = [
    '\0', 'ㄱ', 'ㄲ', 'ㄳ', 'ㄴ', 'ㄵ', 'ㄶ', 'ㄷ', 'ㄹ', 'ㄺ', 'ㄻ', 'ㄼ', 'ㄽ', 'ㄾ', 'ㄿ', 'ㅀ', 'ㅁ',
    'ㅂ', 'ㅄ', 'ㅅ', 'ㅆ', 'ㅇ', 'ㅈ', 'ㅊ', 'ㅋ', 'ㅌ', 'ㅍ', 'ㅎ',
];

/// 두벌식 자판: 영문 소문자 키 → (자모, Shift 자모).
pub fn jamo_for_key(letter: char, shift: bool) -> Option<char> {
    let (normal, shifted) = match letter.to_ascii_lowercase() {
        'q' => ('ㅂ', 'ㅃ'),
        'w' => ('ㅈ', 'ㅉ'),
        'e' => ('ㄷ', 'ㄸ'),
        'r' => ('ㄱ', 'ㄲ'),
        't' => ('ㅅ', 'ㅆ'),
        'y' => ('ㅛ', 'ㅛ'),
        'u' => ('ㅕ', 'ㅕ'),
        'i' => ('ㅑ', 'ㅑ'),
        'o' => ('ㅐ', 'ㅒ'),
        'p' => ('ㅔ', 'ㅖ'),
        'a' => ('ㅁ', 'ㅁ'),
        's' => ('ㄴ', 'ㄴ'),
        'd' => ('ㅇ', 'ㅇ'),
        'f' => ('ㄹ', 'ㄹ'),
        'g' => ('ㅎ', 'ㅎ'),
        'h' => ('ㅗ', 'ㅗ'),
        'j' => ('ㅓ', 'ㅓ'),
        'k' => ('ㅏ', 'ㅏ'),
        'l' => ('ㅣ', 'ㅣ'),
        'z' => ('ㅋ', 'ㅋ'),
        'x' => ('ㅌ', 'ㅌ'),
        'c' => ('ㅊ', 'ㅊ'),
        'v' => ('ㅍ', 'ㅍ'),
        'b' => ('ㅠ', 'ㅠ'),
        'n' => ('ㅜ', 'ㅜ'),
        'm' => ('ㅡ', 'ㅡ'),
        _ => return None,
    };
    Some(if shift { shifted } else { normal })
}

fn is_vowel(c: char) -> bool {
    JUNG.contains(&c)
}

fn combine_vowel(a: char, b: char) -> Option<char> {
    Some(match (a, b) {
        ('ㅗ', 'ㅏ') => 'ㅘ',
        ('ㅗ', 'ㅐ') => 'ㅙ',
        ('ㅗ', 'ㅣ') => 'ㅚ',
        ('ㅜ', 'ㅓ') => 'ㅝ',
        ('ㅜ', 'ㅔ') => 'ㅞ',
        ('ㅜ', 'ㅣ') => 'ㅟ',
        ('ㅡ', 'ㅣ') => 'ㅢ',
        _ => return None,
    })
}

fn combine_jong(a: char, b: char) -> Option<char> {
    Some(match (a, b) {
        ('ㄱ', 'ㅅ') => 'ㄳ',
        ('ㄴ', 'ㅈ') => 'ㄵ',
        ('ㄴ', 'ㅎ') => 'ㄶ',
        ('ㄹ', 'ㄱ') => 'ㄺ',
        ('ㄹ', 'ㅁ') => 'ㄻ',
        ('ㄹ', 'ㅂ') => 'ㄼ',
        ('ㄹ', 'ㅅ') => 'ㄽ',
        ('ㄹ', 'ㅌ') => 'ㄾ',
        ('ㄹ', 'ㅍ') => 'ㄿ',
        ('ㄹ', 'ㅎ') => 'ㅀ',
        ('ㅂ', 'ㅅ') => 'ㅄ',
        _ => return None,
    })
}

#[derive(Default, Clone, Copy)]
struct Syllable {
    cho: Option<char>,
    jung: Option<char>,
    jong: Option<char>,
}

impl Syllable {
    /// 한 음절 안에서 자모를 더한다. 이 음절에 들어갈 수 없으면 None.
    fn add(mut self, c: char) -> Option<Self> {
        if is_vowel(c) {
            if self.jong.is_some() {
                return None;
            }
            match self.jung {
                None => self.jung = Some(c),
                Some(v) => self.jung = Some(combine_vowel(v, c)?),
            }
        } else {
            match (self.cho, self.jung, self.jong) {
                (None, None, _) => self.cho = Some(c),
                // 초성만 있거나 모음만 있으면 새 음절.
                (_, None, _) | (None, Some(_), _) => return None,
                (Some(_), Some(_), None) => {
                    if !JONG.contains(&c) {
                        return None; // ㄸ ㅃ ㅉ 은 받침이 될 수 없다.
                    }
                    self.jong = Some(c);
                }
                (Some(_), Some(_), Some(j)) => self.jong = Some(combine_jong(j, c)?),
            }
        }
        Some(self)
    }

    fn render(&self) -> String {
        match (self.cho, self.jung) {
            (Some(cho), Some(jung)) => {
                let ci = CHO.iter().position(|&x| x == cho).unwrap_or(0) as u32;
                let ji = JUNG.iter().position(|&x| x == jung).unwrap_or(0) as u32;
                let ti = self
                    .jong
                    .and_then(|t| JONG.iter().position(|&x| x == t))
                    .unwrap_or(0) as u32;
                char::from_u32(0xAC00 + (ci * 21 + ji) * 28 + ti)
                    .map(|c| c.to_string())
                    .unwrap_or_default()
            }
            (Some(cho), None) => cho.to_string(),
            (None, Some(jung)) => jung.to_string(),
            (None, None) => String::new(),
        }
    }
}

fn fold(inputs: &[char]) -> Option<Syllable> {
    inputs
        .iter()
        .try_fold(Syllable::default(), |s, &c| s.add(c))
}

/// 조합 중인 한 음절(입력한 자모 순서)과 화면에 넣어 둔 글자를 기억한다.
#[derive(Default)]
pub struct Composer {
    inputs: Vec<char>,
    shown: String,
}

impl Composer {
    pub fn is_composing(&self) -> bool {
        !self.inputs.is_empty()
    }

    /// 조합을 끝낸다. 이미 화면에 넣은 글자는 그대로 둔다.
    pub fn reset(&mut self) {
        self.inputs.clear();
        self.shown.clear();
    }

    /// 자모 하나를 넣는다.
    pub fn input(&mut self, c: char) -> Edit {
        let mut trial = self.inputs.clone();
        trial.push(c);
        let committed;
        if fold(&trial).is_some() {
            committed = String::new();
            self.inputs = trial;
        } else {
            let cur = fold(&self.inputs).unwrap_or_default();
            if is_vowel(c) && cur.jong.is_some() {
                // 받침(겹받침이면 마지막 자음)이 다음 음절 초성으로 넘어간다: 각+ㅏ → 가가, 닭+ㅏ → 달가
                let moved = self.inputs.pop().unwrap_or(c);
                committed = fold(&self.inputs).unwrap_or_default().render();
                self.inputs = vec![moved, c];
            } else {
                committed = cur.render();
                self.inputs = vec![c];
            }
        }
        let new_shown = fold(&self.inputs).unwrap_or_default().render();
        self.apply(committed + &new_shown, new_shown)
    }

    /// 조합 중 지우기: 마지막 자모만 뺀다. 조합 중이 아니면 None(보통 Backspace 로 보낸다).
    pub fn backspace(&mut self) -> Option<Edit> {
        if !self.is_composing() {
            return None;
        }
        self.inputs.pop();
        let new_shown = fold(&self.inputs).unwrap_or_default().render();
        let edit = Edit {
            backspaces: self.shown.chars().count(),
            text: new_shown.clone(),
        };
        self.shown = new_shown;
        if self.inputs.is_empty() {
            self.shown.clear();
        }
        Some(edit)
    }

    fn apply(&mut self, full: String, new_shown: String) -> Edit {
        let edit = if !self.shown.is_empty() && full.starts_with(&self.shown) {
            Edit {
                backspaces: 0,
                text: full[self.shown.len()..].to_string(),
            }
        } else {
            Edit {
                backspaces: self.shown.chars().count(),
                text: full,
            }
        };
        self.shown = new_shown;
        edit
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 편집을 실제 문자열에 적용해 본다.
    fn type_keys(keys: &str) -> String {
        let mut out = String::new();
        let mut c = Composer::default();
        let apply = |out: &mut String, e: Edit| {
            for _ in 0..e.backspaces {
                out.pop();
            }
            out.push_str(&e.text);
        };
        for k in keys.chars() {
            if k == '<' {
                match c.backspace() {
                    Some(e) => apply(&mut out, e),
                    None => {
                        out.pop();
                    }
                }
            } else if k == ' ' {
                c.reset();
                out.push(' ');
            } else {
                let shift = k.is_ascii_uppercase();
                let j = jamo_for_key(k, shift).unwrap();
                let e = c.input(j);
                apply(&mut out, e);
            }
        }
        out
    }

    #[test]
    fn words() {
        assert_eq!(type_keys("dkssudgktpdy"), "안녕하세요");
        assert_eq!(type_keys("rkqt"), "값");
        assert_eq!(type_keys("ekfr"), "닭");
        assert_eq!(type_keys("T"), "ㅆ");
        assert_eq!(type_keys("rkrk"), "가가");
        assert_eq!(type_keys("ekfrk"), "달가");
        assert_eq!(type_keys("dhkd"), "왕");
        assert_eq!(type_keys("dml"), "의");
        assert_eq!(type_keys("RkTek"), "깠다");
        assert_eq!(type_keys("gksrmf dlqfur"), "한글 입력");
        assert_eq!(type_keys("rr"), "ㄱㄱ");
        assert_eq!(type_keys("kk"), "ㅏㅏ");
        assert_eq!(type_keys("Ekf"), "딸");
        // ㄸ 은 받침이 될 수 없다: 가 + ㄸ → 가ㄸ
        assert_eq!(type_keys("rkE"), "가ㄸ");
    }

    #[test]
    fn backspace_in_composition() {
        assert_eq!(type_keys("rks<"), "가");
        assert_eq!(type_keys("rks<<"), "ㄱ");
        assert_eq!(type_keys("rks<<<"), "");
        assert_eq!(type_keys("ekfr<"), "달");
        // 조합이 끝난 뒤에는 보통 지우기(글자 단위)
        assert_eq!(type_keys("rk <"), "가");
        assert_eq!(type_keys("rkrk<"), "가ㄱ");
    }

    #[test]
    fn edits_are_minimal() {
        let mut c = Composer::default();
        assert_eq!(c.input('ㄱ'), Edit { backspaces: 0, text: "ㄱ".into() });
        assert_eq!(c.input('ㅏ'), Edit { backspaces: 1, text: "가".into() });
        assert_eq!(c.input('ㄴ'), Edit { backspaces: 1, text: "간".into() });
        // 간 + ㄱ → 간 은 그대로 두고 ㄱ 만 더함
        assert_eq!(c.input('ㄱ'), Edit { backspaces: 0, text: "ㄱ".into() });
    }
}
