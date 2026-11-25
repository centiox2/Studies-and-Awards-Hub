import 'package:excel/excel.dart';

final _formulaPrefix = RegExp(r'^\s*[=+@-]|^[\t\r\n]');

TextCellValue spreadsheetText(Object? value) {
  final text = value?.toString() ?? '';
  return TextCellValue(_formulaPrefix.hasMatch(text) ? "'$text" : text);
}
