import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fooddiary/ui/pages.dart';

import 'support/exif_image.dart';

void main() {
  for (final endian in [Endian.little, Endian.big]) {
    test('EXIF capture date wins over earlier modification tag ($endian)', () {
      expect(
        imageDateFromBytes(
          exifImage(
            original: '2026:09:10 23:45:00',
            digitized: '2026:09:11 08:00:00',
            modified: '2026:10:01 10:00:00',
            endian: endian,
          ),
        ),
        DateTime(2026, 9, 10),
      );
    });
  }

  test(
    'uses digitization or modification date when capture date is missing',
    () {
      expect(
        imageDateFromBytes(
          exifImage(
            digitized: '2026:09:11 08:00:00',
            modified: '2026:10:01 10:00:00',
          ),
        ),
        DateTime(2026, 9, 11),
      );
      expect(
        imageDateFromBytes(exifImage(modified: '2026:10:01 10:00:00')),
        DateTime(2026, 10, 1),
      );
    },
  );

  test('ignores missing, invalid, truncated and unrelated dates', () {
    expect(imageDateFromBytes(exifImage()), isNull);
    expect(
      imageDateFromBytes(exifImage(original: '2026:02:30 08:00:00')),
      isNull,
    );
    final jpeg = exifImage(original: '2026:09:10 08:00:00');
    final segmentEnd = 4 + ByteData.sublistView(jpeg).getUint16(4);
    for (var length = 0; length < segmentEnd; length++) {
      expect(imageDateFromBytes(jpeg.sublist(0, length)), isNull);
    }
    expect(
      imageDateFromBytes(
        Uint8List.fromList([
          ...exifImage(),
          ...ascii.encode('exported 2026-09-10'),
        ]),
      ),
      isNull,
    );
  });
}
