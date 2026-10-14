// Composition root: the only file in this app that reaches Supabase (through
// church_client_core's composition library).
import 'package:church_client_core/composition.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

/// Kept for the app's lifetime so the browser semantics tree is always built:
/// a screen-reader user should not need Flutter's hidden "enable
/// accessibility" button (1.6 finding 10).
late final SemanticsHandle semanticsHandle;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  semanticsHandle = SemanticsBinding.instance.ensureSemantics();
  final overrides = await compositionOverrides(AppConfig.fromEnvironment);
  runApp(ProviderScope(overrides: overrides, child: const StaffApp()));
}
