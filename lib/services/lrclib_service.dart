import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;
import '../models/lyric_result.dart';

class LRCLibNetworkException implements Exception {
  final String message;
  const LRCLibNetworkException(this.message);

  @override
  String toString() => message;
}

class LRCLibService {
  static Future<LyricResult?> getLyrics({
    required String artist,
    required String title,
    required String album,
    required int durationSeconds,
  }) async {
    final safeArtist = artist.trim();
    final safeTitle = title.trim();
    final safeAlbum = album.trim();

    LRCLibNetworkException? technicalFailure;

    try {
      final exact = await _getExactLyrics(
        artist: safeArtist,
        title: safeTitle,
        album: safeAlbum,
        durationSeconds: durationSeconds,
      );
      if (exact != null) {
        return exact;
      }
    } on LRCLibNetworkException catch (e) {
      technicalFailure = e;
    }

    try {
      final fallback = await _fallbackSearch(
        artist: safeArtist,
        title: safeTitle,
        album: safeAlbum,
        durationSeconds: durationSeconds,
      );
      if (fallback != null) {
        return fallback;
      }
    } on LRCLibNetworkException {
      rethrow;
    }

    if (technicalFailure != null) {
      throw technicalFailure;
    }

    return null;
  }

  // Búsqueda alternativa si get no encuentra nada
  static Future<List<LyricResult>> getManualLyrics({
    required String artist,
    required String title,
    required String album,
  }) async {
    final query = Uri.encodeComponent(_buildSearchQuery(artist, title, album));

    final searchUri = Uri.parse("https://lrclib.net/api/search?q=$query");
    final r = await _safeGet(searchUri);

    if (r.statusCode == 404) {
      return [];
    }

    if (r.statusCode >= 500 || r.statusCode == 429) {
      throw const LRCLibNetworkException(
        "LRCLib devolvió un error temporal.",
      );
    }

    if (r.statusCode != 200) {
      return [];
    }

    final results = json.decode(r.body);
    if (results is! List) {
      return [];
    }

    return results.map<LyricResult>((e) => LyricResult.fromJson(e)).toList();
  }

  static Future<LyricResult?> _getExactLyrics({
    required String artist,
    required String title,
    required String album,
    required int durationSeconds,
  }) async {
    final safeDuration = (durationSeconds <= 0) ? "" : durationSeconds.toString();
    final uri = Uri.parse(
      "https://lrclib.net/api/get"
      "?artist_name=${Uri.encodeComponent(artist)}"
      "&track_name=${Uri.encodeComponent(title)}"
      "&album_name=${Uri.encodeComponent(album)}"
      "&duration=$safeDuration",
    );

    final r = await _safeGet(uri);

    if (r.statusCode == 404 || r.statusCode == 400) {
      return null;
    }

    if (r.statusCode >= 500 || r.statusCode == 429) {
      throw const LRCLibNetworkException(
        "LRCLib devolvió un error temporal.",
      );
    }

    if (r.statusCode == 200 && r.body.isNotEmpty && r.body != "{}") {
      return LyricResult.fromJson(json.decode(r.body));
    }

    return null;
  }

  static Future<LyricResult?> _fallbackSearch({
    required String artist,
    required String title,
    required String album,
    required int durationSeconds,
  }) async {
    final candidates = await getManualLyrics(
      artist: _normalizeArtist(artist),
      title: _normalizeTitle(title),
      album: _normalizeText(album),
    );

    if (candidates.isEmpty) {
      return null;
    }

    final ranked = candidates
        .map(
          (candidate) => (
            candidate,
            _rankCandidate(
              candidate: candidate,
              artist: artist,
              title: title,
              album: album,
              durationSeconds: durationSeconds,
            ),
          ),
        )
        .toList()
      ..sort((a, b) => b.$2.compareTo(a.$2));

    final best = ranked.first;
    final secondScore = ranked.length > 1 ? ranked[1].$2 : 0.0;

    const minScore = 0.72;
    const minGap = 0.08;

    if (best.$2 < minScore || (best.$2 - secondScore) < minGap) {
      return null;
    }

    return best.$1;
  }

  static double _rankCandidate({
    required LyricResult candidate,
    required String artist,
    required String title,
    required String album,
    required int durationSeconds,
  }) {
    final inputTitle = _normalizeTitle(title);
    final inputArtist = _normalizeArtist(artist);
    final inputAlbum = _normalizeText(album);

    final candidateTitle = _normalizeTitle(candidate.title);
    final candidateArtist = _normalizeArtist(candidate.artist);
    final candidateAlbum = _normalizeText(candidate.album);

    double score = 0;

    score += _scoreField(
      source: inputTitle,
      target: candidateTitle,
      exactWeight: 0.55,
      partialWeight: 0.35,
      overlapWeight: 0.40,
    );

    score += _scoreField(
      source: inputArtist,
      target: candidateArtist,
      exactWeight: 0.35,
      partialWeight: 0.20,
      overlapWeight: 0.25,
    );

    score += _scoreField(
      source: inputAlbum,
      target: candidateAlbum,
      exactWeight: 0.10,
      partialWeight: 0.04,
      overlapWeight: 0.06,
    );

    if (durationSeconds > 0 && candidate.durationSeconds > 0) {
      final diff = (durationSeconds - candidate.durationSeconds.round()).abs();
      if (diff <= 2) {
        score += 0.20;
      } else if (diff <= 6) {
        score += 0.12;
      } else if (diff <= 12) {
        score += 0.06;
      } else {
        score -= 0.15;
      }
    }

    return score;
  }

  static double _scoreField({
    required String source,
    required String target,
    required double exactWeight,
    required double partialWeight,
    required double overlapWeight,
  }) {
    if (source.isEmpty || target.isEmpty) {
      return 0;
    }

    if (source == target) {
      return exactWeight;
    }

    if (source.contains(target) || target.contains(source)) {
      return partialWeight;
    }

    final overlap = _tokenOverlap(source, target);
    return overlap * overlapWeight;
  }

  static double _tokenOverlap(String a, String b) {
    final aTokens = a
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toSet();
    final bTokens = b
        .split(' ')
        .where((token) => token.isNotEmpty)
        .toSet();

    if (aTokens.isEmpty || bTokens.isEmpty) {
      return 0;
    }

    final intersection = aTokens.intersection(bTokens).length;
    final union = aTokens.union(bTokens).length;

    if (union == 0) {
      return 0;
    }

    return intersection / union;
  }

  static Future<http.Response> _safeGet(Uri uri) async {
    try {
      return await http.get(uri).timeout(const Duration(seconds: 10));
    } on SocketException {
      throw const LRCLibNetworkException(
        "No se pudo conectar a LRCLib. Revisá tu conexión.",
      );
    } on TimeoutException {
      throw const LRCLibNetworkException(
        "LRCLib tardó demasiado en responder.",
      );
    } on HttpException {
      throw const LRCLibNetworkException(
        "Error técnico al consultar LRCLib.",
      );
    }
  }

  static String _buildSearchQuery(String artist, String title, String album) {
    final parts = [artist.trim(), title.trim(), album.trim()]
        .where((e) => e.isNotEmpty)
        .toList();

    if (parts.isEmpty) {
      return "";
    }

    return parts.join(' ');
  }

  static String _normalizeTitle(String value) {
    final withoutFeaturing = value
        .replaceAll(
          RegExp(
            r'\b(feat\.?|ft\.?)\s+[^\-\(\)\[\]]+',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\(([^)]*(live|remaster|version|edit|mono|stereo)[^)]*)\)',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\[([^\]]*(live|remaster|version|edit|mono|stereo)[^\]]*)\]',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(
          RegExp(
            r'\s-\s*(live|remaster(ed)?|version|edit)\b.*$',
            caseSensitive: false,
          ),
          ' ',
        );

    return _normalizeText(withoutFeaturing);
  }

  static String _normalizeArtist(String value) {
    final normalized = _normalizeText(value);
    if (normalized.isEmpty) {
      return normalized;
    }

    final splitters = RegExp(r'\s*(,|&|;|/| x | and | feat\.? | ft\.? )\s*');
    return normalized.split(splitters).first.trim();
  }

  static String _normalizeText(String value) {
    final base = _stripDiacritics(value.toLowerCase())
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return base;
  }

  static String _stripDiacritics(String input) {
    const map = {
      'á': 'a',
      'à': 'a',
      'ä': 'a',
      'â': 'a',
      'ã': 'a',
      'é': 'e',
      'è': 'e',
      'ë': 'e',
      'ê': 'e',
      'í': 'i',
      'ì': 'i',
      'ï': 'i',
      'î': 'i',
      'ó': 'o',
      'ò': 'o',
      'ö': 'o',
      'ô': 'o',
      'õ': 'o',
      'ú': 'u',
      'ù': 'u',
      'ü': 'u',
      'û': 'u',
      'ñ': 'n',
      'ç': 'c',
    };

    return input.split('').map((char) => map[char] ?? char).join();
  }
}
