// Builds the NWS zone-geometry catalog consumed by Spotter Tools Pro.
//
// Source: the official NWS AWIPS shapefiles published at
// https://www.weather.gov/gis/ (counties, public forecast zones, fire
// zones, coastal marine zones, offshore marine zones). Five zip
// downloads replace the ~11,650 per-zone api.weather.gov calls the
// builder used to make; those calls failed in bulk whenever the API
// was having a bad morning (Sep 21 and Oct 12 2026 runs). The API
// serves the same shapefile geometry one zone at a time: a full
// comparison on 2026-10-12 matched all 11,651 zone keys exactly, with
// median per-zone overlap 99.99%.
//
// Output:
//   <out>/zones.bin       ZGC3 v1 binary catalog (same format the app
//                         writes to disk in zone_geometry_cache.dart).
//   <out>/manifest.json   Tiny metadata blob the app fetches first.
//
// The app re-downloads zones.bin whenever the manifest's generated_at
// is newer than its local copy. So a release is only worth publishing
// when the zone geometry actually changed: the manifest carries a
// `content_sha256` over everything after the 16-byte header, and when
// it matches the previous release the build reports `changed=false`
// and the workflow publishes nothing. The app ignores the extra field.
//
// The binary encoder below is a direct copy of the helpers in
// `lib/data/nws/zone_geometry_cache.dart` of the Spotter Tools Pro
// repo. Keeping a literal copy here (rather than importing across
// repos) means there's nothing to keep in lockstep besides the file
// format constants. If you change the format on either side, bump
// `_binaryFormatVersion` in both places at the same time.
//
// Usage:
//   dart run tool/build_catalog.dart --out dist/ [--previous prev/]
//
// Flags:
//   --previous DIR        Directory holding the currently published
//                         zones.bin + manifest.json. Enables the
//                         unchanged check and the diff safety gate.
//   --allow-large-diff    Publish even if the diff gate trips (use
//                         after confirming NWS really renumbered or
//                         redrew a large share of zones).
//   --tolerance-m N       Simplification tolerance in meters (default 25).

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

// ── ZGC3 binary format constants ─────────────────────────────────────
// Magic bytes spell "ZGC3" in ASCII. Format version 1. Coords are
// stored as int32 multiplied by [_coordScale]; intake values are
// truncated to [_coordPrecision] decimals first (matches the app).
const int _magicByte0 = 0x5A; // 'Z'
const int _magicByte1 = 0x47; // 'G'
const int _magicByte2 = 0x43; // 'C'
const int _magicByte3 = 0x33; // '3'
const int _binaryFormatVersion = 1;
const int _headerLen = 16;
const double _coordScale = 1e6;
const int _coordPrecision = 4;

// Ring count is a uint8 in the format. Coastal zones with many islands
// exceed it (31 zones as of the April 2026 set), so we keep the 255
// LARGEST rings. That retains >= 99.77% of every such zone's area. The
// old API builder kept the first 255 in NWS order, which for Levy
// County FL kept 0.7% of the county and dropped the mainland.
const int _maxRings = 255;

// Diff gate against the previous release. A normal NWS zone update
// touches a handful of zones; anything beyond these shares means the
// source or the parsing went wrong and we refuse to publish.
const int _minZoneCount = 10000;
const double _maxRemovedShare = 0.02;
const double _maxMovedShare = 0.01;

const String _gisBase = 'https://www.weather.gov';
const String _userAgent = 'spotter-tools-zones-catalog-builder/2.0 '
    '(https://github.com/Dgwayne/spotter-tools-zones)';

enum _Kind { county, publicZone, fire, marine }

class _Source {
  final String page;
  final String prefix;
  final _Kind kind;
  const _Source(this.page, this.prefix, this.kind);
}

// High seas (hz) zones are not in the API zone listing and never were
// in the catalog, so they stay out.
const List<_Source> _sources = [
  _Source('Counties', 'c_', _Kind.county),
  _Source('PublicZones', 'z_', _Kind.publicZone),
  _Source('FireZones', 'fz', _Kind.fire),
  _Source('MarineZones', 'mz', _Kind.marine),
  _Source('MarineZones', 'oz', _Kind.marine),
];

/// Catalog key for one shapefile record, in the form the app looks up:
/// the lower-cased path of the zone's api.weather.gov URL as it appears
/// in alert `affectedZones` lists.
String? _keyFor(_Kind kind, Map<String, String> rec) {
  switch (kind) {
    case _Kind.county:
      final state = rec['STATE'] ?? '';
      final fips = rec['FIPS'] ?? '';
      if (state.length != 2 || fips.length != 5) return null;
      return '/zones/county/${state}C${fips.substring(2)}'.toLowerCase();
    case _Kind.publicZone:
    case _Kind.fire:
      final stateZone = rec['STATE_ZONE'] ?? '';
      final zone = rec['ZONE'] ?? '';
      if (stateZone.length < 2 || zone.isEmpty) return null;
      final type = kind == _Kind.fire ? 'fire' : 'forecast';
      return '/zones/$type/${stateZone.substring(0, 2)}Z$zone'.toLowerCase();
    case _Kind.marine:
      final id = rec['ID'] ?? '';
      if (id.isEmpty) return null;
      return '/zones/forecast/$id'.toLowerCase();
  }
}

Future<void> main(List<String> args) async {
  exitCode = await _run(args);
}

Future<int> _run(List<String> args) async {
  final outDir = _parseString(args, '--out', 'dist');
  final prevDir = _parseString(args, '--previous', '');
  final allowLargeDiff = args.contains('--allow-large-diff');
  final toleranceM = double.parse(_parseString(args, '--tolerance-m', '25'));

  await Directory(outDir).create(recursive: true);
  stdout.writeln('[build] starting; out=$outDir tolerance=${toleranceM}m');

  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 30)
    ..userAgent = _userAgent;
  try {
    final rings = <String, List<List<List<double>>>>{};
    final today = DateTime.now().toUtc();
    final pages = <String, String>{};
    for (final src in _sources) {
      final html = pages[src.page] ??=
          utf8.decode(await _get(client, '$_gisBase/gis/${src.page}'),
              allowMalformed: true);
      final zipPath = _pickInEffect(html, src.prefix, today);
      if (zipPath == null) {
        stderr.writeln('[build] FATAL: no in-effect ${src.prefix} set '
            'listed on /gis/${src.page}');
        return 2;
      }
      stdout.writeln('[build] ${src.page}: $zipPath');
      final zip = ZipDecoder().decodeBytes(await _get(client, '$_gisBase$zipPath'));
      final shp = _member(zip, '.shp');
      final dbf = _member(zip, '.dbf');
      if (shp == null || dbf == null) {
        stderr.writeln('[build] FATAL: $zipPath missing .shp/.dbf');
        return 2;
      }
      final records = _readDbf(dbf);
      final shapes = _readShpPolygons(shp);
      if (records.length != shapes.length) {
        stderr.writeln('[build] FATAL: $zipPath has ${records.length} '
            'records but ${shapes.length} shapes');
        return 2;
      }
      var added = 0;
      for (var i = 0; i < records.length; i++) {
        final key = _keyFor(src.kind, records[i]);
        if (key == null || shapes[i].isEmpty) continue;
        // Counties split across CWAs appear as several records with the
        // same key; their outer rings accumulate under one zone.
        (rings[key] ??= []).addAll(shapes[i]);
        added++;
      }
      stdout.writeln('[build]   ${records.length} records, $added keyed');
    }

    final zones = <String, List<List<List<double>>>>{};
    rings.forEach((key, outer) {
      final finished = _finishZone(outer, toleranceM);
      if (finished.isNotEmpty) zones[key] = finished;
    });
    final points = zones.values
        .fold<int>(0, (s, z) => s + z.fold<int>(0, (s2, r) => s2 + r.length));
    stdout.writeln('[build] ${zones.length} zones, $points points');

    if (zones.length < _minZoneCount) {
      stderr.writeln(
          '[build] FATAL: only ${zones.length} zones (<$_minZoneCount)');
      return 2;
    }

    final timestamp = DateTime.now().toUtc();
    final binBytes = _encodeAll(zones, timestamp);
    final contentSha =
        sha256.convert(Uint8List.sublistView(binBytes, _headerLen)).toString();

    var changed = true;
    if (prevDir.isNotEmpty) {
      final prevManifest = jsonDecode(
              await File(p.join(prevDir, 'manifest.json')).readAsString())
          as Map<String, dynamic>;
      if (prevManifest['content_sha256'] == contentSha) {
        changed = false;
        stdout.writeln('[build] geometry identical to the published '
            'release ($contentSha); nothing to publish');
      } else {
        final prev = _readBboxes(
            await File(p.join(prevDir, 'zones.bin')).readAsBytes());
        if (!_diffGate(prev, zones, allowLargeDiff)) return 3;
      }
    }

    final binPath = p.join(outDir, 'zones.bin');
    await File(binPath).writeAsBytes(binBytes, flush: true);
    final sha = sha256.convert(binBytes).toString();
    final manifest = {
      'format_version': _binaryFormatVersion,
      'generated_at': timestamp.toIso8601String(),
      'zone_count': zones.length,
      'size_bytes': binBytes.length,
      'sha256': sha,
      'content_sha256': contentSha,
    };
    final manifestJson =
        const JsonEncoder.withIndent('  ').convert(manifest) + '\n';
    final manifestPath = p.join(outDir, 'manifest.json');
    await File(manifestPath).writeAsString(manifestJson, flush: true);

    stdout.writeln('[build] wrote $binPath (${binBytes.length} bytes)');
    stdout.writeln('[build] wrote $manifestPath');
    stdout.writeln('[build] sha256=$sha content_sha256=$contentSha');
    stdout.writeln('[build] changed=$changed');
    final ghOutput = Platform.environment['GITHUB_OUTPUT'];
    if (ghOutput != null && ghOutput.isNotEmpty) {
      await File(ghOutput)
          .writeAsString('changed=$changed\n', mode: FileMode.append);
    }
    return 0;
  } catch (e, st) {
    stderr.writeln('[build] FATAL: $e\n$st');
    return 1;
  } finally {
    client.close(force: true);
  }
}

// ── Source discovery + download ──────────────────────────────────────

Future<Uint8List> _get(HttpClient client, String url) async {
  for (var attempt = 1;; attempt++) {
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(minutes: 5));
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res.timeout(const Duration(minutes: 5))) {
        builder.add(chunk);
      }
      if (res.statusCode != 200) {
        throw HttpException('status ${res.statusCode}', uri: Uri.parse(url));
      }
      return builder.toBytes();
    } catch (e) {
      if (attempt >= 4) rethrow;
      stderr.writeln('[build] WARN: $url attempt $attempt failed: $e');
      await Future<void>.delayed(Duration(seconds: 15 * attempt));
    }
  }
}

const Map<String, int> _months = {
  'ja': 1, 'fe': 2, 'mr': 3, 'ap': 4, 'my': 5, 'jn': 6, //
  'jl': 7, 'au': 8, 'se': 9, 'oc': 10, 'no': 11, 'de': 12,
};

/// NWS lists the current set and, ahead of a zone change, the next one
/// too. Each file name carries its valid date (`z_16ap26.zip` = valid
/// 16 April 2026). Pick the newest set that is already valid.
String? _pickInEffect(String html, String prefix, DateTime today) {
  final re = RegExp('href="([^"]*/${RegExp.escape(prefix)}'
      r'(\d{2})([a-z]{2})(\d{2})\.zip)"');
  String? best;
  DateTime? bestDate;
  for (final m in re.allMatches(html)) {
    final month = _months[m.group(3)];
    if (month == null) continue;
    final date = DateTime.utc(
        2000 + int.parse(m.group(4)!), month, int.parse(m.group(2)!));
    if (date.isAfter(today)) continue;
    if (bestDate == null || date.isAfter(bestDate)) {
      bestDate = date;
      best = m.group(1);
    }
  }
  return best;
}

Uint8List? _member(Archive zip, String ext) {
  for (final f in zip.files) {
    if (f.isFile && f.name.toLowerCase().endsWith(ext)) return f.content;
  }
  return null;
}

// ── Shapefile readers ────────────────────────────────────────────────

/// dBase III table → one map per record, values trimmed.
List<Map<String, String>> _readDbf(Uint8List b) {
  final v = ByteData.sublistView(b);
  final count = v.getUint32(4, Endian.little);
  final headerLen = v.getUint16(8, Endian.little);
  final recordLen = v.getUint16(10, Endian.little);
  final names = <String>[];
  final lengths = <int>[];
  for (var off = 32; off < headerLen - 1 && b[off] != 0x0D; off += 32) {
    var end = off;
    while (end < off + 11 && b[end] != 0) {
      end++;
    }
    names.add(latin1.decode(b.sublist(off, end)));
    lengths.add(b[off + 16]);
  }
  final out = <Map<String, String>>[];
  for (var r = 0; r < count; r++) {
    var off = headerLen + r * recordLen + 1; // skip deletion flag
    final rec = <String, String>{};
    for (var f = 0; f < names.length; f++) {
      rec[names[f]] =
          latin1.decode(b.sublist(off, off + lengths[f])).trim();
      off += lengths[f];
    }
    out.add(rec);
  }
  return out;
}

/// Polygon shapefile → per record, its OUTER rings as `[[lat, lon], ...]`.
/// Shapefile outer rings run clockwise and holes counter-clockwise; holes
/// are dropped, matching what the API builder and the app always did.
/// Clockwise (in lon/lat) is also the winding the published catalog has
/// always carried, so rings are stored as-is.
List<List<List<List<double>>>> _readShpPolygons(Uint8List b) {
  final v = ByteData.sublistView(b);
  final out = <List<List<List<double>>>>[];
  var off = 100;
  while (off + 8 <= b.length) {
    final contentLen = v.getInt32(off + 4, Endian.big) * 2;
    final c = off + 8;
    off = c + contentLen;
    final type = v.getInt32(c, Endian.little);
    if (type != 5) {
      out.add(const []);
      continue;
    }
    final numParts = v.getInt32(c + 36, Endian.little);
    final numPoints = v.getInt32(c + 40, Endian.little);
    final partsAt = c + 44;
    final pointsAt = partsAt + numParts * 4;
    final outer = <List<List<double>>>[];
    for (var i = 0; i < numParts; i++) {
      final start = v.getInt32(partsAt + i * 4, Endian.little);
      final end = i + 1 < numParts
          ? v.getInt32(partsAt + (i + 1) * 4, Endian.little)
          : numPoints;
      if (end - start < 4) continue;
      final ring = <List<double>>[];
      for (var k = start; k < end; k++) {
        final lon = v.getFloat64(pointsAt + k * 16, Endian.little);
        final lat = v.getFloat64(pointsAt + k * 16 + 8, Endian.little);
        ring.add([lat, lon]);
      }
      if (_signedArea(ring) < 0) outer.add(ring);
    }
    out.add(outer);
  }
  return out;
}

/// Shoelace area with x = lon, y = lat. Negative = clockwise.
double _signedArea(List<List<double>> ring) {
  var a = 0.0;
  for (var i = 0; i < ring.length - 1; i++) {
    a += ring[i][1] * ring[i + 1][0] - ring[i + 1][1] * ring[i][0];
  }
  return a / 2;
}

// ── Geometry finishing ───────────────────────────────────────────────

/// Largest [_maxRings] rings, simplified, rounded to [_coordPrecision].
/// Ordering is fully deterministic so identical sources give identical
/// bytes (the unchanged check relies on it).
List<List<List<double>>> _finishZone(
    List<List<List<double>>> outer, double toleranceM) {
  final sorted = [...outer]..sort((a, b) {
      final byArea = _signedArea(a).abs().compareTo(_signedArea(b).abs());
      if (byArea != 0) return -byArea;
      final byLat = a[0][0].compareTo(b[0][0]);
      return byLat != 0 ? byLat : a[0][1].compareTo(b[0][1]);
    });
  final out = <List<List<double>>>[];
  for (final ring in sorted.take(_maxRings)) {
    var r = _round(_simplifyRing(ring, toleranceM));
    // A thin sliver can still collapse under the tolerance. Keep it at
    // full detail rather than lose land someone might be standing on.
    if (r.length < 4) r = _round(ring);
    if (r.length >= 4) out.add(r);
  }
  return out;
}

/// Rounds to [_coordPrecision] decimals (as the app does on intake) and
/// drops points that rounding made identical to their predecessor.
List<List<double>> _round(List<List<double>> ring) {
  final out = <List<double>>[];
  for (final pt in ring) {
    final q = [
      double.parse(pt[0].toStringAsFixed(_coordPrecision)),
      double.parse(pt[1].toStringAsFixed(_coordPrecision)),
    ];
    if (out.isNotEmpty && out.last[0] == q[0] && out.last[1] == q[1]) {
      continue;
    }
    out.add(q);
  }
  return out;
}

/// Douglas-Peucker on a closed ring, measured in meters on a local
/// equirectangular projection. The ring is split at the point farthest
/// from its start so both halves are open polylines.
List<List<double>> _simplifyRing(List<List<double>> ring, double tolM) {
  if (ring.length <= 4 || tolM <= 0) return ring;
  final lat0 = ring[0][0] * math.pi / 180;
  final kx = 111320.0 * math.cos(lat0);
  const ky = 110540.0;
  final xs = [for (final pt in ring) pt[1] * kx];
  final ys = [for (final pt in ring) pt[0] * ky];
  // Small islands (under ~40x the tolerance across) keep full detail:
  // a 25 m tolerance visibly reshapes a 300 m atoll, and these rings
  // are only a handful of points anyway.
  final spanX = xs.reduce(math.max) - xs.reduce(math.min);
  final spanY = ys.reduce(math.max) - ys.reduce(math.min);
  if (math.max(spanX, spanY) < tolM * 40) return ring;
  var far = 0;
  var farD = -1.0;
  for (var i = 1; i < ring.length - 1; i++) {
    final dx = xs[i] - xs[0], dy = ys[i] - ys[0];
    final d = dx * dx + dy * dy;
    if (d > farD) {
      farD = d;
      far = i;
    }
  }
  final keep = List<bool>.filled(ring.length, false);
  keep[0] = true;
  keep[far] = true;
  keep[ring.length - 1] = true;
  final tol2 = tolM * tolM;
  final stack = <List<int>>[
    [0, far],
    [far, ring.length - 1],
  ];
  while (stack.isNotEmpty) {
    final seg = stack.removeLast();
    final a = seg[0], z = seg[1];
    if (z - a < 2) continue;
    final ax = xs[a], ay = ys[a];
    final dx = xs[z] - ax, dy = ys[z] - ay;
    final len2 = dx * dx + dy * dy;
    var best = -1;
    var bestD = tol2;
    for (var i = a + 1; i < z; i++) {
      var t = len2 == 0 ? 0.0 : ((xs[i] - ax) * dx + (ys[i] - ay) * dy) / len2;
      t = t < 0 ? 0 : (t > 1 ? 1 : t);
      final ex = ax + t * dx - xs[i], ey = ay + t * dy - ys[i];
      final d = ex * ex + ey * ey;
      if (d > bestD) {
        bestD = d;
        best = i;
      }
    }
    if (best >= 0) {
      keep[best] = true;
      stack
        ..add([a, best])
        ..add([best, z]);
    }
  }
  return [
    for (var i = 0; i < ring.length; i++)
      if (keep[i]) ring[i]
  ];
}

// ── Diff gate against the previous release ───────────────────────────

/// key → [minLat, minLon, maxLat, maxLon] for a ZGC3 catalog.
Map<String, List<double>> _readBboxes(Uint8List b) {
  final v = ByteData.sublistView(b);
  final out = <String, List<double>>{};
  var off = _headerLen;
  while (off + 3 <= b.length) {
    final keyLen = v.getUint16(off, Endian.little);
    off += 2;
    final key = utf8.decode(b.sublist(off, off + keyLen));
    off += keyLen;
    final ringCount = b[off];
    off += 1;
    final box = [90.0, 180.0, -90.0, -180.0];
    for (var r = 0; r < ringCount; r++) {
      final n = v.getUint32(off, Endian.little);
      off += 4;
      for (var k = 0; k < n; k++) {
        final lat = v.getInt32(off, Endian.little) / _coordScale;
        final lon = v.getInt32(off + 4, Endian.little) / _coordScale;
        off += 8;
        box[0] = math.min(box[0], lat);
        box[1] = math.min(box[1], lon);
        box[2] = math.max(box[2], lat);
        box[3] = math.max(box[3], lon);
      }
    }
    out[key] = box;
  }
  return out;
}

double _bboxIou(List<double> a, List<double> b) {
  final h = math.min(a[2], b[2]) - math.max(a[0], b[0]);
  final w = math.min(a[3], b[3]) - math.max(a[1], b[1]);
  if (h <= 0 || w <= 0) return 0;
  final inter = h * w;
  final areaA = (a[2] - a[0]) * (a[3] - a[1]);
  final areaB = (b[2] - b[0]) * (b[3] - b[1]);
  return inter / (areaA + areaB - inter);
}

bool _diffGate(Map<String, List<double>> prev,
    Map<String, List<List<List<double>>>> next, bool allowLargeDiff) {
  final removed = prev.keys.where((k) => !next.containsKey(k)).toList()
    ..sort();
  final added = next.keys.where((k) => !prev.containsKey(k)).toList()..sort();
  final moved = <String>[];
  for (final k in prev.keys) {
    final zone = next[k];
    if (zone == null) continue;
    final box = [90.0, 180.0, -90.0, -180.0];
    for (final ring in zone) {
      for (final pt in ring) {
        box[0] = math.min(box[0], pt[0]);
        box[1] = math.min(box[1], pt[1]);
        box[2] = math.max(box[2], pt[0]);
        box[3] = math.max(box[3], pt[1]);
      }
    }
    if (_bboxIou(prev[k]!, box) < 0.5) moved.add(k);
  }
  moved.sort();
  stdout.writeln('[build] diff vs published: ${removed.length} removed, '
      '${added.length} added, ${moved.length} reshaped');
  if (removed.isNotEmpty) {
    stdout.writeln('[build]   removed: ${removed.take(20).join(' ')}');
  }
  if (added.isNotEmpty) {
    stdout.writeln('[build]   added: ${added.take(20).join(' ')}');
  }
  if (moved.isNotEmpty) {
    stdout.writeln('[build]   reshaped: ${moved.take(40).join(' ')}');
  }
  final tooManyRemoved = removed.length > prev.length * _maxRemovedShare;
  final tooManyMoved = moved.length > prev.length * _maxMovedShare;
  if ((tooManyRemoved || tooManyMoved) && !allowLargeDiff) {
    stderr.writeln('[build] FATAL: diff exceeds the safety gate '
        '(removed share ${_maxRemovedShare * 100}%, reshaped share '
        '${_maxMovedShare * 100}%). If NWS really changed this much, '
        're-run with allow_large_diff.');
    return false;
  }
  return true;
}

// ── ZGC3 binary encoder (copy of zone_geometry_cache.dart helpers) ───

Uint8List _encodeAll(
  Map<String, List<List<List<double>>>> zones,
  DateTime timestamp,
) {
  final builder = BytesBuilder(copy: false);
  builder.add(_buildHeader(timestamp));
  // Stable ordering by key so identical inputs produce identical
  // bytes (and identical sha256s) across runs.
  final keys = zones.keys.toList()..sort();
  for (final key in keys) {
    builder.add(_encodeZone(key, zones[key]!));
  }
  return builder.toBytes();
}

Uint8List _buildHeader(DateTime timestamp) {
  final header = Uint8List(_headerLen);
  final view = ByteData.sublistView(header);
  header[0] = _magicByte0;
  header[1] = _magicByte1;
  header[2] = _magicByte2;
  header[3] = _magicByte3;
  view.setUint32(4, _binaryFormatVersion, Endian.little);
  view.setInt64(8, timestamp.millisecondsSinceEpoch, Endian.little);
  return header;
}

Uint8List _encodeZone(String key, List<List<List<double>>> rings) {
  final keyBytes = utf8.encode(key);
  final ringCount = rings.length > 255 ? 255 : rings.length;
  final usedRings = rings.take(ringCount).toList(growable: false);
  final pointTotal = usedRings.fold<int>(0, (sum, r) => sum + r.length);
  final size =
      2 + keyBytes.length + 1 + (usedRings.length * 4) + (pointTotal * 8);
  final out = Uint8List(size);
  final view = ByteData.sublistView(out);
  var off = 0;
  view.setUint16(off, keyBytes.length, Endian.little);
  off += 2;
  out.setRange(off, off + keyBytes.length, keyBytes);
  off += keyBytes.length;
  view.setUint8(off, usedRings.length);
  off += 1;
  for (final ring in usedRings) {
    view.setUint32(off, ring.length, Endian.little);
    off += 4;
    for (final point in ring) {
      view.setInt32(off, (point[0] * _coordScale).round(), Endian.little);
      off += 4;
      view.setInt32(off, (point[1] * _coordScale).round(), Endian.little);
      off += 4;
    }
  }
  return out;
}

// ── CLI plumbing ─────────────────────────────────────────────────────

String _parseString(List<String> args, String flag, String fallback) {
  final idx = args.indexOf(flag);
  if (idx >= 0 && idx + 1 < args.length) return args[idx + 1];
  return fallback;
}
