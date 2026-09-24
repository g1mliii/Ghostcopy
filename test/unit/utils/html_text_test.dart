import 'package:flutter_test/flutter_test.dart';
import 'package:ghostcopy/utils/html_text.dart';

void main() {
  test('paragraphs, list items and breaks stay on their own lines', () {
    expect(
      htmlToPlainText('<p>First line</p><p>Second line</p>'),
      'First line\nSecond line',
    );
    expect(htmlToPlainText('one<br>two<br/>three'), 'one\ntwo\nthree');
    expect(htmlToPlainText('<ul><li>a</li><li>b</li></ul>'), 'a\nb');
  });

  test('numeric entities decode, decimal and hex', () {
    expect(htmlToPlainText('<p>Second&#8217;s line</p>'), 'Second’s line');
    expect(htmlToPlainText('it&#x2019;s &#39;quoted&#39;'), "it’s 'quoted'");
  });

  test('an escaped entity is decoded once, not twice', () {
    expect(htmlToPlainText('&amp;lt;b&amp;gt;'), '&lt;b&gt;');
  });

  test('an out-of-range entity is left as it was', () {
    expect(htmlToPlainText('&#99999999;'), '&#99999999;');
  });

  test('script and style contents are dropped', () {
    expect(
      htmlToPlainText(
        '<style>p{color:red}</style><span>Fish &amp; chips</span>',
      ),
      'Fish & chips',
    );
  });
}
