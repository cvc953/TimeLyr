import 'dart:async';
import 'package:flutter/services.dart';

class MetadataReader {
  static const MethodChannel _channel = MethodChannel('metadata_reader');

  static Future<Map<String, dynamic>?> getMetadata(String path) async {
    try {
      final result = await _channel.invokeMethod('getMetadata', {'path': path});
      if (result is Map) {
        return Map<String, dynamic>.from(result);
      }
      return null;
    } on PlatformException catch (e) {
      //print('Failed to get metadata: ${e.message}');
      return null;
    }
  }

  static Future<List<dynamic>> scanMusic() async {
    try {
      final result = await _channel.invokeMethod('scanMusic');
      if (result is List) {
        return result;
      }
      return [];
    } on PlatformException catch (e) {
      //print('Failed to scan music: ${e.message}');
      return [];
    }
  }
}
