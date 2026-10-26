import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// A filesystem the user can browse: a disk partition or a configured folder.
class Volume {
  const Volume({
    required this.title,
    this.device,
    this.fstype,
    this.size,
    this.available,
    this.mountpoint,
  });

  final String title;
  final String? device;
  final String? fstype;
  final String? size;
  final String? available;
  final String? mountpoint;

  bool get isBookmark => device == null;
  bool get isMounted => mountpoint != null;

  String get subtitle {
    if (isBookmark) return mountpoint!;
    final parts = [
      ?fstype,
      if (available != null) '$available free of $size' else ?size,
      if (!isMounted) 'not mounted',
    ];
    return parts.join(' · ');
  }
}

const _hiddenFsTypes = {'swap', 'LVM2_member', 'crypto_LUKS', 'linux_raid_member', 'zfs_member'};

bool _isSystemMount(String mp) =>
    mp == '/' || mp == '[SWAP]' || mp.startsWith('/boot') || mp == '/var/log' || mp.startsWith('/var/log.');

/// Partitions with a filesystem that aren't part of the running system.
Future<List<Volume>> listVolumes() async {
  final result = await Process.run('lsblk', [
    '--json',
    '--paths',
    '-o',
    'NAME,LABEL,FSTYPE,SIZE,FSAVAIL,MOUNTPOINT,UUID,TYPE',
  ]);
  if (result.exitCode != 0) {
    debugPrint('lsblk failed: ${result.stderr}');
    return [];
  }
  final json = jsonDecode(result.stdout as String) as Map<String, dynamic>;
  final volumes = <Volume>[];

  void visit(Map<String, dynamic> dev) {
    final name = dev['name'] as String;
    final fstype = dev['fstype'] as String?;
    final mountpoint = dev['mountpoint'] as String?;
    final skip = name.startsWith('/dev/zram') ||
        name.startsWith('/dev/loop') ||
        fstype == null ||
        _hiddenFsTypes.contains(fstype) ||
        (mountpoint != null && _isSystemMount(mountpoint));
    if (!skip) {
      volumes.add(Volume(
        title: (dev['label'] as String?) ?? (dev['uuid'] as String?) ?? name,
        device: name,
        fstype: fstype,
        size: dev['size'] as String?,
        available: dev['fsavail'] as String?,
        mountpoint: mountpoint,
      ));
    }
    for (final child in (dev['children'] as List<dynamic>? ?? const [])) {
      visit(child as Map<String, dynamic>);
    }
  }

  for (final dev in json['blockdevices'] as List<dynamic>) {
    visit(dev as Map<String, dynamic>);
  }
  return volumes;
}

/// Mounts through udisks2, which a polkit rule allows for the kiosk user.
/// Returns the mountpoint, or throws with udisks' error message.
Future<String> mountVolume(Volume volume) async {
  final result = await Process.run('udisksctl', ['mount', '--no-user-interaction', '-b', volume.device!]);
  if (result.exitCode != 0) throw Exception((result.stderr as String).trim());
  // "Mounted /dev/sda1 at /media/kiosk/DATA"
  final out = (result.stdout as String).trim();
  final at = out.lastIndexOf(' at ');
  if (at < 0) throw Exception('unexpected udisksctl output: $out');
  var mountpoint = out.substring(at + 4);
  if (mountpoint.endsWith('.')) mountpoint = mountpoint.substring(0, mountpoint.length - 1);
  return mountpoint;
}

Future<void> unmountVolume(Volume volume) async {
  final result = await Process.run('udisksctl', ['unmount', '--no-user-interaction', '-b', volume.device!]);
  if (result.exitCode != 0) throw Exception((result.stderr as String).trim());
}
