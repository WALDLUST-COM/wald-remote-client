import 'package:flutter_hbb/common.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // Waldlust(DSK-04 — 부록 A-76): 주소록 ID 검색은 검색어의 공백을 무시한다.
  test('ID search ignores whitespace in the query', () {
    const id = '1003096058';
    expect(waldIdMatches(id, '1003096058'), isTrue);
    expect(waldIdMatches(id, '1 003 096 058'), isTrue);
    expect(waldIdMatches(id, '003 096'), isTrue);
    expect(waldIdMatches(id, '1 003'), isTrue);
    expect(waldIdMatches(id, '096\t058'), isTrue);
    expect(waldIdMatches(id, '1 004'), isFalse);
    expect(waldIdMatches(id, '   '), isFalse);
    expect(waldIdMatches('AbC123', 'abc 1'), isTrue);
  });
}
