import 'dart:io';

import 'package:path/path.dart' as p;

enum MediaKind { directory, video, audio, image, other }

const _videoExt = {
  '.mkv', '.mp4', '.m4v', '.avi', '.mov', '.webm', '.ts', '.m2ts', '.mts', '.mpg', '.mpeg', '.wmv', '.flv', '.3gp', '.vob', '.ogv',
};
const _audioExt = {
  '.mp3', '.flac', '.m4a', '.aac', '.ogg', '.oga', '.opus', '.wav', '.wma', '.ape', '.alac', '.mka', '.ac3', '.eac3', '.dts',
};
const _imageExt = {'.jpg', '.jpeg', '.png', '.gif', '.webp', '.bmp'};

MediaKind kindOf(FileSystemEntity e) {
  if (e is Directory) return MediaKind.directory;
  final ext = p.extension(e.path).toLowerCase();
  if (_videoExt.contains(ext)) return MediaKind.video;
  if (_audioExt.contains(ext)) return MediaKind.audio;
  if (_imageExt.contains(ext)) return MediaKind.image;
  return MediaKind.other;
}
