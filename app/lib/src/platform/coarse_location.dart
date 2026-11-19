import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../settings/settings.dart';
import 'device.dart';

/// "Use my approximate location for local answers" (off by default).
///
/// When on, each chat message carries a coarse position: the device rounds
/// it to two decimals (about 1 km) before Dart sees it, and the bridge turns
/// it into one context line for that message ("User's approximate location:
/// Mylapore, Chennai, IN"). The position is refreshed at most every
/// [refreshAfter] and dropped after [forgetAfter]; it is never stored on the
/// device or in chat history beyond that line. Android only.
class LocationService extends ChangeNotifier {
  LocationService({
    required this.settings,
    required this.device,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    settings.addListener(_onSettings);
    _onSettings();
  }

  final SettingsController settings;
  final DeviceServices device;
  final DateTime Function() _clock;

  static const refreshAfter = Duration(minutes: 20);
  static const forgetAfter = Duration(hours: 6);

  ({double lat, double lng})? _fix;
  DateTime? _at;
  bool _busy = false;

  /// Whether this device can share its location (Android).
  bool get available => device.android;
  bool get enabled => settings.locationAnswers;

  /// The `location` field for `/api/chat`, or null. Starts a refresh when
  /// the position is getting old.
  Map<String, Object?>? wire() {
    if (!enabled) return null;
    final at = _at, fix = _fix;
    if (at == null || _clock().difference(at) > refreshAfter) {
      unawaited(refresh());
    }
    if (fix == null || at == null || _clock().difference(at) > forgetAfter) {
      return null;
    }
    return {'lat': fix.lat, 'lng': fix.lng};
  }

  /// Turns the setting on after the permission prompt; false when the user
  /// declined or no position is available.
  Future<bool> enable() async {
    final fix = await device.coarseLocation(ask: true);
    if (fix == null) return false;
    _fix = fix;
    _at = _clock();
    await settings.setLocationAnswers(true);
    notifyListeners();
    return true;
  }

  Future<void> disable() async {
    _fix = null;
    _at = null;
    await settings.setLocationAnswers(false);
    notifyListeners();
  }

  Future<void> refresh() async {
    if (!enabled || _busy) return;
    _busy = true;
    try {
      final fix = await device.coarseLocation();
      if (fix != null) {
        _fix = fix;
        _at = _clock();
      }
    } finally {
      _busy = false;
    }
  }

  void _onSettings() {
    if (!enabled) {
      _fix = null;
      _at = null;
    } else if (_fix == null) {
      unawaited(refresh());
    }
  }

  @override
  void dispose() {
    settings.removeListener(_onSettings);
    super.dispose();
  }
}

/// Gives chat widgets (the `LocationButton` OpenUI component) the service.
class LocationScope extends InheritedNotifier<LocationService> {
  const LocationScope({
    super.key,
    required LocationService service,
    required super.child,
  }) : super(notifier: service);

  static LocationService? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LocationScope>()?.notifier;
}
