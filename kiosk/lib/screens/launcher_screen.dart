import 'dart:io';

import 'package:flutter/material.dart';

import '../widgets.dart';
import '../youtube.dart';
import 'disks_screen.dart';

class LauncherScreen extends StatelessWidget {
  const LauncherScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: ListenableBuilder(
        listenable: YouTube.instance,
        builder: (context, _) => Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.all(48),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _LauncherTile(
                      icon: Icons.smart_display,
                      title: 'YouTube',
                      autofocus: true,
                      onSelect: () => _launchYouTube(context),
                    ),
                    _LauncherTile(
                      icon: Icons.video_library,
                      title: 'Media',
                      onSelect: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const DisksScreen()),
                      ),
                    ),
                    _LauncherTile(
                      icon: Icons.power_settings_new,
                      title: 'Power',
                      onSelect: () => _showPowerDialog(context),
                    ),
                  ],
                ),
              ),
            ),
            // Chromium needs a few seconds to appear and then covers this.
            // The spinner must stop afterwards: an animation hidden behind
            // Chromium would still render every frame and eat a CPU core.
            if (YouTube.instance.isRunning)
              ColoredBox(
                color: Colors.black,
                child: Center(
                  child: YouTube.instance.isStarting ? const CircularProgressIndicator() : const SizedBox.shrink(),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _launchYouTube(BuildContext context) async {
    try {
      await YouTube.instance.launch();
    } catch (e) {
      if (context.mounted) showToast(context, 'Could not start YouTube: $e');
    }
  }

  Future<void> _showPowerDialog(BuildContext context) async {
    final action = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Power'),
        children: [
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'reboot'),
            child: const ListTile(leading: Icon(Icons.restart_alt), title: Text('Restart')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context, 'poweroff'),
            child: const ListTile(leading: Icon(Icons.power_settings_new), title: Text('Shut down')),
          ),
          SimpleDialogOption(
            onPressed: () => Navigator.pop(context),
            child: const ListTile(leading: Icon(Icons.close), title: Text('Cancel')),
          ),
        ],
      ),
    );
    if (action == null) return;
    // logind lets the user of the active seat session do this without a password
    final result = await Process.run('systemctl', [action]);
    if (result.exitCode != 0 && context.mounted) {
      showToast(context, 'systemctl $action failed: ${(result.stderr as String).trim()}');
    }
  }
}

class _LauncherTile extends StatelessWidget {
  const _LauncherTile({required this.icon, required this.title, required this.onSelect, this.autofocus = false});

  final IconData icon;
  final String title;
  final VoidCallback onSelect;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: SizedBox(
        width: 280,
        height: 280,
        child: TvFocusable(
          autofocus: autofocus,
          borderRadius: 24,
          onSelect: onSelect,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 120),
              const SizedBox(height: 16),
              Text(title, style: Theme.of(context).textTheme.titleLarge),
            ],
          ),
        ),
      ),
    );
  }
}
