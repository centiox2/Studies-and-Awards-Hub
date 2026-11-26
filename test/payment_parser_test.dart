import 'package:flutter_test/flutter_test.dart';
import 'package:client_tracker/services/payment_text_parser.dart';

void main() {
  // As text recognition returns the example photo: line breaks, and the
  // cut-off end of the previous message at the top.
  const photo = '''
balance is
Ksh4,321.00
EX4AMPO8PA
Confirmed. on 3/11/26 at
1:38 PM Ksh12,345.00
received from ALEX
SAMPLE
PAYER
254700000000.
Account Number
Example Student New
Utility balance is
Ksh67,890.00
Sender can't accept replies. Contact
them directly. Learn more
''';

  test('the example M-Pesa photo: amount received, not the balances', () {
    final found = parsePayments(photo);
    expect(found, hasLength(1));
    final p = found.single;
    expect(p.amountCents, 1234500);
    expect(p.code, 'EX4AMPO8PA');
    expect(p.payer, 'ALEX SAMPLE PAYER');
    expect(p.account, 'Example Student');
    expect(p.time, DateTime(2026, 11, 3, 13, 38));
    expect(p.method, 'M-Pesa');
    expect(p.incoming, isTrue);
    expect(
      p.note,
      'EX4AMPO8PA · M-Pesa · Alex Sample Payer · Acc: Example Student',
    );
    // The phone number is not kept.
    expect(p.note, isNot(contains('2547')));
  });

  test('several messages in one photo, and OCR mistakes in numbers', () {
    const two = '''
EX4AMPO8PA Confirmed. on 3/11/26 at 1:38 PM Ksh12,345.00 received from
EXAMPLE PAYER 254700000000. Account Number Example Student New Utility balance is Ksh67,890.00
EX5TEST2CD Confirmed. on 3/11/26 at 2:05 PM Ksh1O,5OO.00 received from
BLAIR SAMPLE 254700000005. Account Number Brian New Utility balance is Ksh117,020.00
''';
    final found = parsePayments(two);
    expect(found.map((p) => p.amountCents), [1234500, 1050000]);
    expect(found.map((p) => p.code), ['EX4AMPO8PA', 'EX5TEST2CD']);
    expect(found.last.time, DateTime(2026, 11, 3, 14, 5));
  });

  test('personal M-Pesa "You have received" format', () {
    final p = parsePayments(
      'SJK4ABC12D Confirmed.You have received Ksh2,000.00 from JOHN DOE '
      '0700000000 on 5/11/26 at 9:15 AM New M-PESA balance is Ksh12,345.00. '
      'Earn interest daily on Ziidi MMF',
    ).single;
    expect(p.amountCents, 200000);
    expect(p.payer, 'JOHN DOE');
    expect(p.time, DateTime(2026, 11, 5, 9, 15));
  });

  test('money going out is marked, so it is not counted', () {
    final p = parsePayments(
      'SJK4XYZ99Q Confirmed. Ksh500.00 sent to MARY A 0700000002 on 5/11/26 '
      'at 10:00 AM. New M-PESA balance is Ksh900.00. Transaction cost, Ksh7.00.',
    ).single;
    expect(p.amountCents, 50000);
    expect(p.incoming, isFalse);
  });

  test('other payment slips: bank and Airtel', () {
    final bank = parsePayments(
      'Equity Bank: KES 15,000.00 received from PETER OTIENO. Ref: FT26307ABC9 '
      'Avail. Bal: KES 230,000.00',
    ).single;
    expect(bank.amountCents, 1500000);
    expect(bank.method, 'Bank');
    expect(bank.code, 'FT26307ABC9');
    expect(bank.payer, 'PETER OTIENO');

    final airtel = parsePayments(
      'Airtel Money: You have received Ksh 3,200 from ALICE K. '
      'Transaction ID: MP261103XYZ. Your balance is Ksh 8,000.',
    ).single;
    expect(airtel.amountCents, 320000);
    expect(airtel.method, 'Airtel Money');
    expect(airtel.code, 'MP261103XYZ');
  });

  test('nothing to find', () {
    expect(parsePayments(''), isEmpty);
    expect(parsePayments('Hello, see you tomorrow'), isEmpty);
    expect(parsePayments('Your balance is Ksh4,321.00'), isEmpty);
  });

  test('amounts survive what text recognition does to them', () {
    int read(String amount) => parsePayments(
      'EX4AMPO8PA Confirmed. on 3/11/26 at 1:38 PM $amount received from '
      'EXAMPLE PAYER 254700000000. New Utility balance is Ksh67,890.00',
    ).single.amountCents;
    expect(read('Ksh12,345.00'), 1234500);
    expect(read('Ksh12345.00'), 1234500); // commas lost
    expect(read('Ksh12, 345.00'), 1234500); // stray space
    expect(read('Ksh12.345.00'), 1234500); // comma read as a dot
    expect(read('Ksh 12 345.00'), 1234500);
    expect(read('Ksh12,345.0O'), 1234500); // 0 read as O
    expect(read('Ksh1,212,345.00'), 121234500);
    expect(read('Ksh1,500'), 150000);
    expect(read('Ksh500'), 50000);
  });

  test('a name with an initial is kept whole', () {
    final p = parsePayments(
      'SJK4ABC12D Confirmed.You have received Ksh2,000.00 from ALICE K. '
      'MWANGI 0700000000 on 5/11/26 at 9:15 AM New M-PESA balance is Ksh1.00',
    ).single;
    expect(p.payer, 'ALICE K. MWANGI');
    expect(p.amountCents, 200000);
  });

  test('older messages keep their own date', () {
    final p = parsePayments(
      'QF71ABC2XY Confirmed. on 14/2/23 at 9:05 AM Ksh3,500.00 received from '
      'MARY W 254700000004. New Utility balance is Ksh10.00',
    ).single;
    expect(p.time, DateTime(2023, 2, 14, 9, 5));
  });

  test(
    'agent/bank format: dashes in the date, receipt number, masked phone',
    () {
      // As in the photo.
      const photo =
          'Ref:AC4597897426: Dear EVELYNE, You have received KES 3000 on your '
          'M-Pesa from PIUS-6145****354 at 03-10-2026 10:53 AM.The M-Pesa '
          'receipt number is:UJ3H98O13S. We Are You!';
      final p = parsePayments(photo).single;
      expect(p.amountCents, 300000);
      expect(p.time, DateTime(2026, 10, 3, 10, 53));
      expect(p.code, 'UJ3H98O13S');
      expect(p.payer, 'PIUS');
      expect(p.method, 'M-Pesa');

      // As the Windows reader gave it: the phone dropped, slashes.
      const read =
          'Ref:AC4597897426: Dear EVELYNE, You have received KES 3000 on your '
          'M-Pesa from PIUS- at 03/10/2026 10:53 AM.The M-Pesa receipt '
          'number is:UJ3H98013S.';
      final q = parsePayments(read).single;
      expect(q.time, DateTime(2026, 10, 3, 10, 53));
      expect(q.code, 'UJ3H98013S');
      expect(q.payer, 'PIUS');
    },
  );

  test('other date shapes', () {
    DateTime? t(String s) =>
        parsePayments('Ksh100.00 received from A B $s').single.time;
    expect(t('on 3.11.2026 at 13:38'), DateTime(2026, 11, 3, 13, 38));
    expect(t('on 03/10/2026'), DateTime(2026, 10, 3, 12));
    expect(t('at 3/10/26 1:05 p.m.'), DateTime(2026, 10, 3, 13, 5));
  });
}
