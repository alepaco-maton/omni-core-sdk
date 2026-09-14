import 'package:omni_mdm_core/omni_mdm_core.dart';
import 'package:test/test.dart';

void main() {
  test('Ok carries value', () {
    final r = resultOk(1);
    expect(r.isOk, isTrue);
    expect(r.when(ok: (v) => v, fail: (_) => -1), 1);
  });

  test('Fail carries failure', () {
    final r = resultFail<int>(const AppFailure(code: 'x', message: 'm'));
    expect(r.isFail, isTrue);
  });
}
