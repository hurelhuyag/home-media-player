import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A focusable item that is obvious from across the room: it grows and gets
/// a bright border while focused.
class TvFocusable extends StatefulWidget {
  const TvFocusable({
    super.key,
    required this.child,
    required this.onSelect,
    this.autofocus = false,
    this.focusNode,
    this.borderRadius = 16,
    this.focusScale = 1.04,
  });

  final Widget child;
  final VoidCallback onSelect;
  final bool autofocus;
  final FocusNode? focusNode;
  final double borderRadius;

  /// Zoom while focused; keep 1 for full-width rows.
  final double focusScale;

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onTap: widget.onSelect,
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) Scrollable.ensureVisible(context, alignment: 0.5, duration: const Duration(milliseconds: 150));
      },
      focusColor: Colors.transparent,
      borderRadius: BorderRadius.circular(widget.borderRadius),
      child: AnimatedScale(
        scale: _focused ? widget.focusScale : 1,
        duration: const Duration(milliseconds: 120),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: _focused ? scheme.primaryContainer : scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(widget.borderRadius),
            border: Border.all(color: _focused ? scheme.primary : Colors.transparent, width: 4),
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

/// Full-width row used by the disk and file lists.
class TvListItem extends StatelessWidget {
  const TvListItem({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.onSelect,
    this.autofocus = false,
    this.trailing,
    this.leading,
  });

  final IconData icon;

  /// Shown instead of [icon], e.g. a logo
  final Widget? leading;
  final String title;
  final String? subtitle;
  final VoidCallback onSelect;
  final bool autofocus;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TvFocusable(
              autofocus: autofocus,
              borderRadius: 12,
              focusScale: 1,
              onSelect: onSelect,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  children: [
                    leading ?? Icon(icon, size: 36),
                    const SizedBox(width: 20),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium),
                          if (subtitle != null)
                            Text(
                              subtitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Title bar for list screens: a breadcrumb-like path plus optional actions.
class TvHeader extends StatelessWidget {
  const TvHeader({super.key, required this.title, this.actions = const []});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

void showToast(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
}

/// Shows the mouse pointer only while a mouse is used, like Android TV: it
/// appears on movement and hides on any key press or after a few idle seconds.
/// Needed because keyboards with a touchpad report a pointer device even
/// when nobody uses it.
class AutoHidePointer extends StatefulWidget {
  const AutoHidePointer({super.key, required this.child});

  final Widget child;

  @override
  State<AutoHidePointer> createState() => _AutoHidePointerState();
}

class _AutoHidePointerState extends State<AutoHidePointer> {
  static const _idle = Duration(seconds: 5);

  bool _visible = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    _timer?.cancel();
    super.dispose();
  }

  bool _onKey(KeyEvent event) {
    _hide();
    return false;
  }

  void _hide() {
    _timer?.cancel();
    if (_visible) setState(() => _visible = false);
  }

  void _onMove(PointerEvent event) {
    _timer?.cancel();
    _timer = Timer(_idle, _hide);
    if (!_visible) setState(() => _visible = true);
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        // On top of everything so its cursor wins over the widgets' own
        // (e.g. a button's hand), but translucent so hover and clicks still
        // reach them.
        Positioned.fill(
          child: MouseRegion(
            opaque: false,
            hitTestBehavior: HitTestBehavior.translucent,
            cursor: _visible ? MouseCursor.defer : SystemMouseCursors.none,
            onHover: _onMove,
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerMove: _onMove,
              onPointerDown: _onMove,
            ),
          ),
        ),
      ],
    );
  }
}

/// TV layout with a menu column on the left and the content on the right.
///
/// Up/Down move within the side that has focus. Left from the content goes
/// to the menu once nothing further left is focusable, and Right from the
/// menu returns to the item that was focused before, so a long list never
/// has to be scrolled back to the top to reach a control.
class TvSideMenuLayout extends StatefulWidget {
  const TvSideMenuLayout({super.key, required this.menu, required this.content, this.menuWidth = 260});

  final List<Widget> menu;
  final Widget content;
  final double menuWidth;

  @override
  State<TvSideMenuLayout> createState() => _TvSideMenuLayoutState();
}

class _TvSideMenuLayoutState extends State<TvSideMenuLayout> {
  final _menuScope = FocusScopeNode(debugLabel: 'side menu');
  final _contentScope = FocusScopeNode(debugLabel: 'content');

  @override
  void dispose() {
    _menuScope.dispose();
    _contentScope.dispose();
    super.dispose();
  }

  /// Focuses the scope's last focused item, or its first one.
  static void _enter(FocusScopeNode scope) {
    final last = scope.focusedChild;
    if (last != null && last.canRequestFocus) {
      last.requestFocus();
    } else {
      scope.requestFocus();
      scope.nextFocus();
    }
  }

  KeyEventResult _onContentKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || event.logicalKey != LogicalKeyboardKey.arrowLeft) return KeyEventResult.ignored;
    final focused = FocusManager.instance.primaryFocus;
    if (focused != null && focused.focusInDirection(TraversalDirection.left)) return KeyEventResult.handled;
    _enter(_menuScope);
    return KeyEventResult.handled;
  }

  KeyEventResult _onMenuKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || event.logicalKey != LogicalKeyboardKey.arrowRight) return KeyEventResult.ignored;
    _enter(_contentScope);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: widget.menuWidth,
          child: FocusScope(
            node: _menuScope,
            onKeyEvent: _onMenuKey,
            child: ListView(children: widget.menu),
          ),
        ),
        const SizedBox(width: 24),
        Expanded(
          child: FocusScope(
            node: _contentScope,
            autofocus: true,
            onKeyEvent: _onContentKey,
            child: widget.content,
          ),
        ),
      ],
    );
  }
}

/// Section heading in a [TvSideMenuLayout] menu.
class TvMenuLabel extends StatelessWidget {
  const TvMenuLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(text, style: theme.textTheme.labelLarge?.copyWith(color: theme.hintColor)),
    );
  }
}

/// An entry of a [TvSideMenuLayout] menu; [selected] marks the active option.
class TvMenuButton extends StatelessWidget {
  const TvMenuButton({super.key, required this.icon, required this.label, required this.onSelect, this.selected = false});

  final IconData icon;
  final String label;
  final VoidCallback onSelect;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TvFocusable(
        borderRadius: 12,
        focusScale: 1,
        onSelect: onSelect,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 28, color: selected ? theme.colorScheme.primary : null),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: selected ? FontWeight.bold : null,
                    color: selected ? theme.colorScheme.primary : null,
                  ),
                ),
              ),
              if (selected) Icon(Icons.check, size: 24, color: theme.colorScheme.primary),
            ],
          ),
        ),
      ),
    );
  }
}
