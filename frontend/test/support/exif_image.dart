import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// A decodable JPEG with independently controlled EXIF dates and byte order.
Uint8List exifImage({
  String? original,
  String? digitized,
  String? modified,
  Endian endian = Endian.little,
}) {
  final jpeg = File('test/fixtures/photo.jpg').readAsBytesSync();
  final rootDates = {0x0132: ?modified};
  final captureDates = {0x9003: ?original, 0x9004: ?digitized};
  final nestedAt = 8 + 2 + (rootDates.length + 1) * 12 + 4;
  var valueAt = nestedAt + 2 + captureDates.length * 12 + 4;
  final tiff = ByteData(
    valueAt + (rootDates.length + captureDates.length) * 20,
  );
  void u16(int at, int value) => tiff.setUint16(at, value, endian);
  void u32(int at, int value) => tiff.setUint32(at, value, endian);
  void dateTag(int at, int tag, String value) {
    final text = ascii.encode('$value\u0000');
    assert(text.length == 20);
    u16(at, tag);
    u16(at + 2, 2);
    u32(at + 4, text.length);
    u32(at + 8, valueAt);
    tiff.buffer.asUint8List().setRange(valueAt, valueAt + text.length, text);
    valueAt += text.length;
  }

  u16(0, endian == Endian.little ? 0x4949 : 0x4d4d);
  u16(2, 42);
  u32(4, 8);
  u16(8, rootDates.length + 1);
  var at = 10;
  for (final date in rootDates.entries) {
    dateTag(at, date.key, date.value);
    at += 12;
  }
  u16(at, 0x8769);
  u16(at + 2, 4);
  u32(at + 4, 1);
  u32(at + 8, nestedAt);
  u16(nestedAt, captureDates.length);
  at = nestedAt + 2;
  for (final date in captureDates.entries) {
    dateTag(at, date.key, date.value);
    at += 12;
  }
  final payload = [
    ...ascii.encode('Exif\u0000\u0000'),
    ...tiff.buffer.asUint8List(),
  ];
  final length = payload.length + 2;
  return Uint8List.fromList([
    0xff,
    0xd8,
    0xff,
    0xe1,
    length >> 8,
    length & 0xff,
    ...payload,
    ...jpeg.sublist(2),
  ]);
}
