import 'dart:math' as math;
import 'dart:typed_data';
import 'bitmap.dart';

abstract final class T02Protocol {
  static const service = '0000ff00-0000-1000-8000-00805f9b34fb';
  static const write = '0000ff02-0000-1000-8000-00805f9b34fb';
  static const notify = '0000ff03-0000-1000-8000-00805f9b34fb';
  static const handshake = <int>[
    0x1f,
    0x11,
    0x7b,
    0x1f,
    0x11,
    0x20,
    0x1f,
    0x11,
    0x45,
    0x1f,
    0x11,
    0x0e,
    0x1f,
    0x11,
    0x07,
    0x1f,
    0x11,
    0x5e,
    0x1f,
    0x11,
    0x08,
    0x1f,
    0x11,
    0x09,
    0x1f,
    0x11,
    0x38,
    0x1f,
    0x11,
    0x8b,
    0x1f,
    0x11,
    0x63,
  ];

  /// Uncompressed baseline; feed occurs once, after all raster blocks.
  /// No opaque 1F 11 37 parameter, capability-75 or compression is guessed.
  static Uint8List printJob(
    MonoBitmap bitmap, {
    int feed = 4,
    int blockRows = 255,
  }) {
    if (feed < 0 || feed > 10) throw ArgumentError.value(feed, 'feed', '0…10');
    if (blockRows < 1 || blockRows > 255) {
      throw ArgumentError.value(blockRows, 'blockRows');
    }
    final out = BytesBuilder(copy: false);
    out.add([0x1b, 0x40, 0x1b, 0x61, 0x01, 0x1f, 0x11, 0x35, 0x00]);
    final data = bitmap.bytes;
    for (var row = 0; row < bitmap.height; row += blockRows) {
      final h = math.min(blockRows, bitmap.height - row);
      out.add([0x1d, 0x76, 0x30, 0, 48, 0, h & 255, h >> 8]);
      out.add(Uint8List.sublistView(data, row * 48, (row + h) * 48));
    }
    if (feed > 0) out.add([0x1b, 0x64, feed]);
    return out.takeBytes();
  }
}

enum ReplyKind {
  credits,
  packetLimit,
  paperPresent,
  coverClosed,
  temperatureNormal,
  cancelled,
  complete,
  unknown,
}

class T02Reply {
  final ReplyKind kind;
  final int value;
  final List<int> bytes;
  T02Reply(this.kind, this.value, List<int> bytes)
    : bytes = List.unmodifiable(bytes);
}

/// Bounded decoder for known T02 frames. Unknown replies are retained as opaque
/// notifications, never searched for embedded credit markers. This is purposely
/// not a decoder for all variable-length Phomemo capability messages.
class T02ReplyDecoder {
  final List<int> _pending = [];
  DateTime? _last;
  bool _sizePadding = false;
  void reset() {
    _pending.clear();
    _last = null;
    _sizePadding = false;
  }

  List<T02Reply> add(List<int> notification, {DateTime? now}) {
    now ??= DateTime.now();
    final out = <T02Reply>[];
    if (_last != null && now.difference(_last!) > const Duration(seconds: 1)) {
      if (_pending.isNotEmpty) {
        out.add(T02Reply(ReplyKind.unknown, 0, _pending));
      }
      reset();
    }
    _last = now;
    _pending.addAll(notification);
    while (_pending.isNotEmpty) {
      if (_sizePadding) {
        _sizePadding = false;
        if (_pending.first == 0) {
          _pending.removeAt(0);
          continue;
        }
      }
      final tag = _pending.first;
      if (tag == 1 || tag == 2) {
        if (_pending.length < 2) break;
        final frame = _pending.sublist(0, 2);
        _pending.removeRange(0, 2);
        out.add(
          T02Reply(
            tag == 1 ? ReplyKind.credits : ReplyKind.packetLimit,
            frame[1],
            frame,
          ),
        );
        _sizePadding = tag == 2; // observed 02 B6 00, not a UInt16 assumption
      } else if (tag == 0x1a) {
        if (_pending.length < 2) break;
        final type = _pending[1];
        if (![3, 5, 6, 11, 15].contains(type)) {
          out.add(T02Reply(ReplyKind.unknown, 0, _pending));
          _pending.clear();
          break;
        }
        if (_pending.length < 3) break;
        final frame = _pending.sublist(0, 3);
        _pending.removeRange(0, 3);
        final v = frame[2];
        final (kind, value) = switch ((type, v)) {
          (3, 0xa9) => (ReplyKind.temperatureNormal, 0),
          (3, 0xa8) => (ReplyKind.temperatureNormal, 1),
          (5, 0x99) => (ReplyKind.coverClosed, 0),
          (5, 0x98) => (ReplyKind.coverClosed, 1),
          (6, 0x88) => (ReplyKind.paperPresent, 0),
          (6, 0x89) => (ReplyKind.paperPresent, 1),
          (11, 0xb8) => (ReplyKind.cancelled, 1),
          (15, 0x0c) => (ReplyKind.complete, 1),
          _ => (ReplyKind.unknown, 0),
        };
        out.add(T02Reply(kind, value, frame));
      } else {
        out.add(T02Reply(ReplyKind.unknown, 0, _pending));
        _pending.clear();
      }
    }
    return out;
  }
}
