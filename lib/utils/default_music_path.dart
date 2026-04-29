import 'dart:io';

class DefaultMusicPath {
  static String get defaultPath {
    final musicPath = "/storage/emulated/0/Music";
    if (Directory(musicPath).existsSync()) {
      return musicPath;
    }
    return "/storage/emulated/0/Music";
  }
}
