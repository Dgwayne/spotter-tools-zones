// Builds the NWS zone-geometry catalog consumed by Spotter Tools Pro.
//
// Output:
//   <out>/zones.bin       — ZGC3 v1 binary catalog (same format the app
//                           writes to disk in zone_geometry_cache.dart).
//   <out>/manifest.json   — Tiny metadata blob the app fetches first.
//
// The binary encoder below is a direct copy of the helpers in
// `lib/data/nws/zone_geometry_cache.dart` of the Spotter Tools Pro
// repo. Keeping a literal copy here (rather than importing across
// repos) means there's nothing to keep in lockstep besides the file
// format constants. If you change the format on either side, bump
// `_binaryFormatVersion` in both places at the same time.
//
// Usage:
//   dart run tool/build_catalog.dart --out dist/
//
// Tunables:
//   --concurrency N   Per-zone fetch concurrency (default 8).
//   --user-agent S    Override the User-Agent. NWS requires a
//                     descriptive UA — see api.weather.gov docs.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:path/path.dart' as p;
import 'package:pool/pool.dart';

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

// ── NWS endpoint constants ───────────────────────────────────────────
const String _nwsBaseUrl = 'https://api.weather.gov';
const List<String> _zoneTypes = [
  'public',
  'marine',
  'fire',
  'forecast',
  'county',
  'offshore',
];

Future<void> main(List<String> args) async {
  exitCode = await _run(args);
}

Future<int> _run(List<String> args) async {
  final outDir = _parseOutDir(args);
  // Concurrency 8 is the sweet spot: NWS throttles individual
  // responses on cloud IPs (some zone responses take 5–10 s), so
  // small concurrency starves on slow ones. 8 absorbs that variance
  // and gets us through the catalog in ~20 min on a fresh runner.
  final concurrency = _parseInt(args, '--concurrency', 8);
  final userAgent = _parseString(
    args,
    '--user-agent',
    'spotter-tools-zones-catalog-builder/1.0 '
        '(https://github.com/Dgwayne/spotter-tools-zones)',
  );

  await Directory(outDir).create(recursive: true);

  stdout.writeln('[build] starting; out=$outDir concurrency=$concurrency');
  final dio = Dio(
    BaseOptions(
      baseUrl: _nwsBaseUrl,
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      headers: {
        'User-Agent': userAgent,
        'Accept': 'application/geo+json',
      },
    ),
  );

  try {
    stdout.writeln('[build] listing zones for ${_zoneTypes.length} types...');
    final paths = await _listAllZonePaths(dio);
    stdout.writeln('[build] ${paths.length} unique zone paths discovered');

    if (paths.length < 10000) {
      // Sanity floor — full catalog hovers around 11–12K depending on
      // marine/offshore listing state. Anything below 10K means the
      // list endpoint is degraded; better to abort than publish a
      // half-empty catalog.
      stderr.writeln(
          '[build] FATAL: only ${paths.length} zones listed (<10000)');
      return 2;
    }

    stdout.writeln('[build] fetching geometries...');
    final geometries = await _fetchAllGeometries(
      dio,
      paths,
      concurrency: concurrency,
    );
    stdout.writeln(
        '[build] ${geometries.length}/${paths.length} zones with geometry');

    if (geometries.length < 10000) {
      stderr.writeln(
          '[build] FATAL: only ${geometries.length} geometries fetched (<10000)');
      return 2;
    }

    final timestamp = DateTime.now().toUtc();
    final binBytes = _encodeAll(geometries, timestamp);
    final binPath = p.join(outDir, 'zones.bin');
    await File(binPath).writeAsBytes(binBytes, flush: true);

    final sha = sha256.convert(binBytes).toString();
    final manifest = {
      'format_version': _binaryFormatVersion,
      'generated_at': timestamp.toIso8601String(),
      'zone_count': geometries.length,
      'size_bytes': binBytes.length,
      'sha256': sha,
    };
    final manifestJson =
        const JsonEncoder.withIndent('  ').convert(manifest) + '\n';
    final manifestPath = p.join(outDir, 'manifest.json');
    await File(manifestPath).writeAsString(manifestJson, flush: true);

    stdout.writeln('[build] wrote $binPath (${binBytes.length} bytes)');
    stdout.writeln('[build] wrote $manifestPath');
    stdout.writeln('[build] sha256=$sha');
    return 0;
  } catch (e, st) {
    stderr.writeln('[build] FATAL: $e\n$st');
    return 1;
  } finally {
    dio.close(force: true);
  }
}

// ── NWS API helpers ──────────────────────────────────────────────────

Future<List<String>> _listAllZonePaths(Dio dio) async {
  final results = await Future.wait(_zoneTypes.map((type) async {
    final paths = <String>[];
    try {
      final res = await dio.get<String>(
        '/zones',
        queryParameters: {'type': type},
        options: Options(
          receiveTimeout: const Duration(seconds: 60),
          responseType: ResponseType.plain,
        ),
      );
      if (res.data == null) return paths;
      final parsed = jsonDecode(res.data!) as Map<String, dynamic>;
      final features =
          (parsed['features'] as List?)?.cast<Map<String, dynamic>>() ?? [];
      for (final f in features) {
        // Prefer the feature's own `id` field (full URL), which is
        // the *canonical* path NWS expects. Falling back to
        // `properties.type` + `properties.id` was the bug: NWS lists
        // a marine zone with `properties.type = "coastal"` but the
        // actual zone URL is `/zones/forecast/{id}`, producing
        // 404-cascade for every coastal & offshore zone we tried.
        final featureUrl = f['id'] as String?;
        if (featureUrl != null && featureUrl.contains('/zones/')) {
          final idx = featureUrl.indexOf('/zones/');
          paths.add(featureUrl.substring(idx));
          continue;
        }
        // Last-resort fallback if the feature is malformed (we still
        // include the candidate so de-dupe + later fetch tries it).
        final props = f['properties'] as Map<String, dynamic>? ?? {};
        final id = props['id'] as String?;
        if (id == null) continue;
        final featType = props['type'] as String? ?? type;
        paths.add('/zones/$featType/$id');
      }
    } catch (e) {
      stderr.writeln('[build] WARN: listing $type failed: $e');
    }
    return paths;
  }));
  // De-dupe across types, but keep the ORIGINAL case for the URL.
  // NWS zone IDs are case-sensitive in the path — /zones/county/AKC020
  // returns 200, /zones/county/akc020 returns 404 — so we can't
  // lowercase the path itself. We lowercase only the dedup key
  // (separately from the stored path) so duplicates from multiple
  // listing types still collapse.
  final dedup = <String, String>{};
  for (final list in results) {
    for (final p in list) {
      dedup.putIfAbsent(p.toLowerCase(), () => p);
    }
  }
  return dedup.values.toList()..sort();
}

Future<Map<String, List<List<List<double>>>>> _fetchAllGeometries(
  Dio dio,
  List<String> paths, {
  required int concurrency,
}) async {
  final out = <String, List<List<List<double>>>>{};
  var done = 0;
  var lastLog = DateTime.now();
  final errorSamples = <String>[];
  final perTypeOk = <String, int>{};
  final perTypeFail = <String, int>{};
  String typeOf(String path) {
    final parts = path.split('/');
    return parts.length > 2 ? parts[2] : path;
  }

  // True worker-pool: every released slot grabs the next available
  // path instead of waiting for the rest of its "batch" to drain.
  // This matters because NWS responses have a long tail (most are
  // sub-second, some take 10+ seconds), and a batched `Future.wait`
  // pattern leaves 7 slots idle every time the 8th hits a slow
  // response.
  final pool = Pool(concurrency);

  await Future.wait(paths.map((path) {
    return pool.withResource(() async {
      try {
        // Use plain response type + manual jsonDecode. NWS responds
        // with `Content-Type: application/geo+json`, which Dio's
        // default transformer does NOT recognise as JSON.
        final res = await dio.get<String>(
          path,
          options: Options(
            receiveTimeout: const Duration(seconds: 12),
            responseType: ResponseType.plain,
          ),
        );
        final body = res.data;
        if (body == null) {
          perTypeFail[typeOf(path)] = (perTypeFail[typeOf(path)] ?? 0) + 1;
          return;
        }
        final parsed = jsonDecode(body) as Map<String, dynamic>;
        final rings = _parseGeometry(parsed['geometry']);
        if (rings != null && rings.isNotEmpty) {
          // Fetch with original-case path; store under lowercase key
          // so the app's `_normalize`-based lookups match.
          out[path.toLowerCase()] = _truncateRings(rings);
          perTypeOk[typeOf(path)] = (perTypeOk[typeOf(path)] ?? 0) + 1;
        } else {
          perTypeFail[typeOf(path)] = (perTypeFail[typeOf(path)] ?? 0) + 1;
          if (errorSamples.length < 5) {
            errorSamples.add(
              'no-geometry: $path bodyHead=${body.substring(0, body.length.clamp(0, 200))}',
            );
          }
        }
      } catch (e) {
        perTypeFail[typeOf(path)] = (perTypeFail[typeOf(path)] ?? 0) + 1;
        if (errorSamples.length < 5) {
          final dioMsg = e is DioException
              ? 'DioException type=${e.type} status=${e.response?.statusCode} msg=${e.message}'
              : 'other: $e';
          errorSamples.add('throw on $path: $dioMsg');
        }
      }
      done++;
      final now = DateTime.now();
      if (now.difference(lastLog).inSeconds >= 10) {
        lastLog = now;
        stdout.writeln('[build]   ${done}/${paths.length} fetched');
      }
    });
  }));

  await pool.close();

  stdout.writeln('[build]   ${done}/${paths.length} fetched (done)');
  stdout.writeln('[build]   per-type ok: $perTypeOk');
  stdout.writeln('[build]   per-type fail: $perTypeFail');
  for (final s in errorSamples) {
    stderr.writeln('[build]   error sample: $s');
  }
  return out;
}

/// Extracts every outer ring as `[[lat, lon], ...]` from any GeoJSON
/// geometry NWS might return. Behaviour mirrors `NwsAlert.parseGeometry`
/// in the app — only outer rings are kept, holes are dropped, and
/// coords are flipped from GeoJSON `[lon, lat]` to the in-app
/// `[lat, lon]` order.
List<List<List<double>>>? _parseGeometry(dynamic geo) {
  if (geo == null) return null;
  final out = <List<List<double>>>[];
  _collect(geo, out);
  return out.isEmpty ? null : out;
}

void _collect(dynamic geo, List<List<List<double>>> out) {
  if (geo is! Map) return;
  final type = geo['type'];
  if (type == 'Polygon') {
    final coords = geo['coordinates'] as List?;
    if (coords == null || coords.isEmpty) return;
    final ring = _ringFromCoords(coords[0]);
    if (ring != null && ring.length >= 3) out.add(ring);
  } else if (type == 'MultiPolygon') {
    final polys = geo['coordinates'] as List?;
    if (polys == null) return;
    for (final pp in polys) {
      if (pp is List && pp.isNotEmpty) {
        final ring = _ringFromCoords(pp[0]);
        if (ring != null && ring.length >= 3) out.add(ring);
      }
    }
  } else if (type == 'GeometryCollection') {
    final geoms = geo['geometries'] as List?;
    if (geoms == null) return;
    for (final g in geoms) {
      _collect(g, out);
    }
  }
}

List<List<double>>? _ringFromCoords(dynamic coords) {
  if (coords is! List) return null;
  final ring = <List<double>>[];
  for (final c in coords) {
    if (c is List && c.length >= 2) {
      ring.add([
        (c[1] as num).toDouble(), // lat
        (c[0] as num).toDouble(), // lon
      ]);
    }
  }
  return ring;
}

List<List<List<double>>> _truncateRings(List<List<List<double>>> rings) {
  return rings.map((ring) {
    return ring.map((point) {
      return [
        double.parse(point[0].toStringAsFixed(_coordPrecision)),
        double.parse(point[1].toStringAsFixed(_coordPrecision)),
      ];
    }).toList(growable: false);
  }).toList(growable: false);
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

String _parseOutDir(List<String> args) {
  final idx = args.indexOf('--out');
  if (idx >= 0 && idx + 1 < args.length) return args[idx + 1];
  return 'dist';
}

int _parseInt(List<String> args, String flag, int fallback) {
  final idx = args.indexOf(flag);
  if (idx >= 0 && idx + 1 < args.length) {
    return int.tryParse(args[idx + 1]) ?? fallback;
  }
  return fallback;
}

String _parseString(List<String> args, String flag, String fallback) {
  final idx = args.indexOf(flag);
  if (idx >= 0 && idx + 1 < args.length) return args[idx + 1];
  return fallback;
}
