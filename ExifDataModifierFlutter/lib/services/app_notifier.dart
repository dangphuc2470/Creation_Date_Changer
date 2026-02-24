import 'package:flutter/material.dart';

enum AppNotifType { error, warning, info, success }

class AppNotif {
  final String message;
  final AppNotifType type;
  final String? detail; // optional extra detail (e.g. exception text)
  AppNotif(this.message, this.type, {this.detail});
}

/// Singleton notification bus.
/// Providers call [AppNotifier.push] (or helpers [error] / [warning] / [info]).
/// The root widget listens via [AppNotifier.stream] and shows a SnackBar.
class AppNotifier {
  AppNotifier._();

  static final ValueNotifier<AppNotif?> _notifier = ValueNotifier(null);

  /// Listen to this in the root widget.
  static ValueNotifier<AppNotif?> get notifier => _notifier;

  static void push(String message, AppNotifType type, {String? detail}) {
    _notifier.value = AppNotif(message, type, detail: detail);
    // Reset so the same message can be pushed again later
    Future.microtask(() => _notifier.value = null);
  }

  static void error(String message, {Object? exception}) {
    final detail = exception?.toString();
    push(message, AppNotifType.error, detail: detail);
    // Also print to debug console
    debugPrint('[ERROR] $message${detail != null ? "\n  $detail" : ""}');
  }

  static void warning(String message, {Object? exception}) {
    final detail = exception?.toString();
    push(message, AppNotifType.warning, detail: detail);
    debugPrint('[WARNING] $message${detail != null ? "\n  $detail" : ""}');
  }

  static void info(String message) {
    push(message, AppNotifType.info);
    debugPrint('[INFO] $message');
  }

  static void success(String message) {
    push(message, AppNotifType.success);
    debugPrint('[SUCCESS] $message');
  }
}
