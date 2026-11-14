import 'dart:async';

import 'package:fl_clash/common/preferences.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:flutter/widgets.dart';

/// Global on/off for tap haptics, kept as a plain [ValueNotifier] so the
/// feedback layer can read the current value on every pointer event without
/// rebuilding the widget tree -- and without touching any generated Riverpod
/// provider or freezed model. Defaults on, matching Circuit / Surge /
/// Shadowrocket, which all give a subtle tick on taps.
final ValueNotifier<bool> hapticFeedbackEnabled = ValueNotifier<bool>(true);

/// Load the persisted preference once at startup.
Future<void> loadHapticFeedbackPreference() async {
  hapticFeedbackEnabled.value = await preferences.getHapticFeedback();
}

/// App-wide light tap feedback. The upstream UI has no haptics at all, so
/// rather than sprinkling HapticFeedback calls through dozens of views (or the
/// prism_ui submodule), one translucent [Listener] observes pointer events at
/// the app root. Translucent hit testing never consumes a pointer, so the
/// app's own gestures, drag-back and card animations are untouched. Only a
/// real tap (tiny down -> up movement) fires, which keeps scrolling silent.
class HapticFeedbackScope extends StatefulWidget {
  const HapticFeedbackScope({super.key, required this.child});

  final Widget child;

  @override
  State<HapticFeedbackScope> createState() => _HapticFeedbackScopeState();
}

class _HapticFeedbackScopeState extends State<HapticFeedbackScope> {
  static const double _tapSlop = 12.0;
  final Map<int, Offset> _downPositions = {};

  @override
  void initState() {
    super.initState();
    // Self-contained: pick up the persisted on/off value as soon as the scope
    // is mounted. The pointer handler reads the notifier live, so no rebuild
    // is needed when the user toggles the setting later.
    unawaited(loadHapticFeedbackPreference());
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        _downPositions[event.pointer] = event.position;
      },
      onPointerUp: (event) {
        final start = _downPositions.remove(event.pointer);
        if (!hapticFeedbackEnabled.value || start == null) {
          return;
        }
        if ((event.position - start).distance > _tapSlop) {
          return;
        }
        // The iOS selection tick is the lightest system feedback -- the same
        // feel a UISwitch / picker gives. Fire-and-forget; unsupported
        // platforms simply no-op.
        unawaited(HapticFeedback.selectionClick());
      },
      onPointerCancel: (event) {
        _downPositions.remove(event.pointer);
      },
      child: widget.child,
    );
  }
}
