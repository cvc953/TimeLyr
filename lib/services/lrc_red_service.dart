import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

/// Error de red o de servicio al consultar lrc.red.
class LrcRedNetworkException implements Exception {
  final String message;
  const LrcRedNetworkException(this.message);

  @override
  String toString() => message;
}

/// Resultado de una búsqueda o de los metadatos de una pista en lrc.red.
class LrcRedTrack {
  final String isrc;
  final String title;
  final String artist;
  final String album;
  final int? year;
  final double durationSeconds;
  final String coverUrl;
  final String sync;
  final String ttmlUrl;
  final String lrcUrl;
  final String pageUrl;

  const LrcRedTrack({
    required this.isrc,
    this.title = '',
    this.artist = '',
    this.album = '',
    this.year,
    this.durationSeconds = 0,
    this.coverUrl = '',
    this.sync = '',
    this.ttmlUrl = '',
    this.lrcUrl = '',
    this.pageUrl = '',
  });

  /// Parsea un elemento de `hits` de `GET /search.json`.
  factory LrcRedTrack.fromSearchJson(Map<String, dynamic> json) {
    return LrcRedTrack(
      isrc: _asString(json['isrc']),
      title: _asString(json['title']),
      artist: _asString(json['artist']),
      album: _asString(json['album']),
      year: _asInt(json['year']),
      durationSeconds: _asDouble(json['duration']),
      coverUrl: _asString(json['cover']),
      sync: _asString(json['sync']),
    );
  }

  /// Parsea la respuesta de `GET /s/{isrc}.json`.
  factory LrcRedTrack.fromTrackJson(Map<String, dynamic> json) {
    final files = _asMap(json['files']);

    return LrcRedTrack(
      isrc: _asString(json['isrc']),
      title: _asString(json['title']),
      artist: _asString(json['artist']),
      album: _asString(json['album']),
      year: _asInt(json['year']),
      durationSeconds: _asDouble(json['duration']),
      coverUrl: _asString(json['cover']),
      sync: _asString(json['sync']),
      ttmlUrl: _resolveUrl(_asString(files['ttml'])),
      lrcUrl: _resolveUrl(_asString(files['lrc'])),
      pageUrl: _resolveUrl(_asString(json['page'])),
    );
  }

  bool get hasTtml => ttmlUrl.isNotEmpty;

  static String _asString(dynamic value) {
    if (value == null) return '';
    if (value is String) return value.trim();
    return value.toString().trim();
  }

  static double _asDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value.trim()) ?? 0;
    return 0;
  }

  static int? _asInt(dynamic value) {
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static Map<String, dynamic> _asMap(dynamic value) {
    if (value is Map) {
      return value.map((key, entry) => MapEntry(key.toString(), entry));
    }
    return const <String, dynamic>{};
  }

  static String _resolveUrl(String value) {
    if (value.isEmpty) return '';
    final parsed = Uri.tryParse(value);
    if (parsed != null && parsed.hasScheme) return value;
    if (value.startsWith('/')) return '${LrcRedService.baseUrl}$value';
    return '${LrcRedService.baseUrl}/$value';
  }
}

/// Cliente de lrc.red para búsqueda y descarga de TTML.
///
/// Serializa las peticiones y las espacia al menos [minimumRequestInterval]
/// para respetar los términos de uso de la API.
class LrcRedService {
  static const String baseUrl = 'https://lrc.red';
  static const String userAgent =
      'TimeLyr/1.1.0 (+https://github.com/cvc953/TimeLyr; contact: https://github.com/cvc953/TimeLyr/issues)';
  static const Duration requestTimeout = Duration(seconds: 12);
  static const Duration minimumRequestInterval = Duration(milliseconds: 200);
  static const String _accept =
      'application/json, application/ttml+xml, text/plain, */*';
  static const double _minMatchScore = 0.7;

  static Future<void> _gate = Future<void>.value();
  static DateTime? _lastRequestAt;

  static const Map<String, String> _diacritics = {
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'â': 'a',
    'ã': 'a',
    'å': 'a',
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
    'ø': 'o',
    'ú': 'u',
    'ù': 'u',
    'ü': 'u',
    'û': 'u',
    'ñ': 'n',
    'ç': 'c',
    'ý': 'y',
    'š': 's',
    'ž': 'z',
    'ł': 'l',
  };

  static final RegExp _versionMarker = RegExp(
    r'[\(\[]([^\)\]]*(remaster|live|version|edit|deluxe|acoustic|mono|stereo)[^\)\]]*)[\)\]]',
    caseSensitive: false,
  );

  /// Busca pistas por artista y título.
  ///
  /// Devuelve una lista vacía si no hay resultados o si lrc.red responde 404
  /// o cualquier otro estado distinto de 200 (salvo 429 y 5xx, que se
  /// reportan como error de red).
  static Future<List<LrcRedTrack>> search({
    required String title,
    required String artist,
    String album = '',
  }) async {
    final trimmedTitle = title.trim();
    final trimmedArtist = artist.trim();
    var query = '$trimmedArtist $trimmedTitle'.trim();
    if (query.isEmpty) query = album.trim();
    if (query.isEmpty) return const <LrcRedTrack>[];

    final uri = Uri.parse('$baseUrl/search.json').replace(
      queryParameters: {'q': query},
    );

    final response = await _get(uri);
    if (response.statusCode != 200) {
      _throwIfTransient(response);
      return const <LrcRedTrack>[];
    }

    return _parseSearchHits(_bodyText(response));
  }

  /// Elige la mejor coincidencia, o `null` si ninguna alcanza el umbral.
  static LrcRedTrack? selectBest(
    List<LrcRedTrack> tracks, {
    required String title,
    required String artist,
    String album = '',
    int durationSeconds = 0,
  }) {
    LrcRedTrack? best;
    var bestScore = double.negativeInfinity;

    for (final track in tracks) {
      final score = scoreTrack(
        track,
        title: title,
        artist: artist,
        album: album,
        durationSeconds: durationSeconds,
      );
      if (score > bestScore) {
        bestScore = score;
        best = track;
      }
    }

    if (best == null || bestScore < _minMatchScore) return null;
    return best;
  }

  /// Puntúa una pista contra los metadatos locales.
  static double scoreTrack(
    LrcRedTrack track, {
    required String title,
    required String artist,
    String album = '',
    int durationSeconds = 0,
  }) {
    final normalizedTitle = _normalizeText(title);
    final normalizedArtist = _normalizeText(artist);

    var score = _fieldScore(
      source: normalizedTitle,
      target: _normalizeText(track.title),
      exactWeight: 0.6,
      containsWeight: 0.4,
      overlapWeight: 0.35,
    );

    score += _fieldScore(
      source: normalizedArtist,
      target: _normalizeText(track.artist),
      exactWeight: 0.3,
      containsWeight: 0.2,
      overlapWeight: 0.2,
    );

    if (durationSeconds > 0 && track.durationSeconds > 0) {
      score += _durationScore(track.durationSeconds, durationSeconds);
    }

    return score;
  }

  /// Busca y devuelve la mejor coincidencia para una canción.
  static Future<LrcRedTrack?> findBest({
    required String title,
    required String artist,
    String album = '',
    int durationSeconds = 0,
  }) async {
    final tracks = await search(title: title, artist: artist, album: album);
    if (tracks.isEmpty) return null;

    return selectBest(
      tracks,
      title: title,
      artist: artist,
      album: album,
      durationSeconds: durationSeconds,
    );
  }

  /// Obtiene los metadatos de una pista por ISRC.
  static Future<LrcRedTrack?> getTrack(String isrc) async {
    final id = isrc.trim();
    if (id.isEmpty) return null;

    final uri = Uri.parse('$baseUrl/s/${Uri.encodeComponent(id)}.json');
    final response = await _get(uri);
    if (response.statusCode != 200) {
      _throwIfTransient(response);
      return null;
    }

    try {
      final decoded = json.decode(_bodyText(response));
      if (decoded is! Map) return null;
      final map = decoded.map((key, value) => MapEntry(key.toString(), value));
      return LrcRedTrack.fromTrackJson(map);
    } catch (_) {
      return null;
    }
  }

  /// Descarga el TTML de una pista por ISRC.
  static Future<String?> fetchTtml(String isrc) async {
    final id = isrc.trim();
    if (id.isEmpty) return null;

    final uri = Uri.parse('$baseUrl/s/${Uri.encodeComponent(id)}.ttml');
    final response = await _get(uri);
    if (response.statusCode != 200) {
      _throwIfTransient(response);
      return null;
    }

    final body = _bodyText(response);
    if (body.trim().isEmpty) return null;
    // Evita guardar una página HTML de error como si fuera TTML.
    if (!body.contains('<tt') && !body.contains('<?xml')) return null;
    return body;
  }

  /// Busca y descarga el TTML de una canción en una sola llamada.
  static Future<String?> fetchTtmlForSong({
    required String title,
    required String artist,
    String album = '',
    int durationSeconds = 0,
  }) async {
    final best = await findBest(
      title: title,
      artist: artist,
      album: album,
      durationSeconds: durationSeconds,
    );
    if (best == null) return null;
    return fetchTtml(best.isrc);
  }

  static Future<http.Response> _get(Uri uri) {
    return _serialize(() async {
      try {
        return await http
            .get(uri, headers: {'User-Agent': userAgent, 'Accept': _accept})
            .timeout(requestTimeout);
      } on SocketException {
        throw const LrcRedNetworkException(
          'No se pudo conectar con lrc.red. Revisa tu conexión a internet.',
        );
      } on HandshakeException {
        throw const LrcRedNetworkException(
          'Error de seguridad (TLS) al conectar con lrc.red.',
        );
      } on TimeoutException {
        throw const LrcRedNetworkException(
          'lrc.red tardó demasiado en responder. Inténtalo de nuevo.',
        );
      } on http.ClientException catch (e) {
        throw LrcRedNetworkException(
          'Error de red al conectar con lrc.red: ${e.message}',
        );
      }
    });
  }

  /// Encadena las peticiones y aplica el espaciado mínimo entre ellas.
  static Future<T> _serialize<T>(Future<T> Function() task) {
    final previous = _gate;
    final done = Completer<void>();
    _gate = done.future;

    return previous.then((_) async {
      try {
        await _throttle();
        return await task();
      } finally {
        done.complete();
      }
    });
  }

  static Future<void> _throttle() async {
    final lastRequestAt = _lastRequestAt;
    if (lastRequestAt != null) {
      final elapsed = DateTime.now().difference(lastRequestAt);
      if (elapsed < minimumRequestInterval) {
        await Future<void>.delayed(minimumRequestInterval - elapsed);
      }
    }
    _lastRequestAt = DateTime.now();
  }

  static void _throwIfTransient(http.Response response) {
    if (response.statusCode == 429) {
      throw const LrcRedNetworkException(
        'lrc.red limitó las solicitudes (HTTP 429). Espera un momento y vuelve a intentarlo.',
      );
    }
    if (response.statusCode >= 500) {
      throw LrcRedNetworkException(
        'lrc.red no está disponible en este momento (HTTP ${response.statusCode}).',
      );
    }
  }

  static String _bodyText(http.Response response) {
    try {
      return utf8.decode(response.bodyBytes, allowMalformed: true);
    } catch (_) {
      return response.body;
    }
  }

  static List<LrcRedTrack> _parseSearchHits(String body) {
    try {
      final decoded = json.decode(body);
      if (decoded is! Map) return const <LrcRedTrack>[];
      final hits = decoded['hits'];
      if (hits is! List) return const <LrcRedTrack>[];

      final tracks = <LrcRedTrack>[];
      for (final hit in hits) {
        if (hit is! Map) continue;
        final map = hit.map((key, value) => MapEntry(key.toString(), value));
        final track = LrcRedTrack.fromSearchJson(map);
        if (track.isrc.isEmpty) continue;
        tracks.add(track);
      }
      return tracks;
    } catch (_) {
      return const <LrcRedTrack>[];
    }
  }

  static double _fieldScore({
    required String source,
    required String target,
    required double exactWeight,
    required double containsWeight,
    required double overlapWeight,
  }) {
    if (source.isEmpty || target.isEmpty) return 0;
    if (source == target) return exactWeight;
    if (source.contains(target) || target.contains(source)) {
      return containsWeight;
    }
    return _tokenOverlap(source, target) * overlapWeight;
  }

  static double _tokenOverlap(String a, String b) {
    final aTokens = a.split(' ').where((token) => token.isNotEmpty).toSet();
    final bTokens = b.split(' ').where((token) => token.isNotEmpty).toSet();
    if (aTokens.isEmpty || bTokens.isEmpty) return 0;

    final intersection = aTokens.intersection(bTokens).length;
    final union = aTokens.union(bTokens).length;
    if (union == 0) return 0;
    return intersection / union;
  }

  static double _durationScore(double candidateSeconds, int expectedSeconds) {
    final diff = (candidateSeconds - expectedSeconds).abs();
    if (diff <= 2) return 0.15;
    if (diff <= 5) return 0.10;
    if (diff <= 12) return 0.05;
    return -0.10;
  }

  static String _normalizeText(String value) {
    final lowered = _stripDiacritics(value.toLowerCase());
    return lowered
        .replaceAll(_versionMarker, ' ')
        .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static String _stripDiacritics(String input) {
    return input.split('').map((char) => _diacritics[char] ?? char).join();
  }
}
