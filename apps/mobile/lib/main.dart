// Composition root: the only file in this app that reaches Supabase (through
// church_client_core's composition library).
import 'package:church_client_core/composition.dart';
import 'package:flutter/material.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final overrides = await compositionOverrides(AppConfig.fromEnvironment);
  runApp(ProviderScope(overrides: overrides, child: const MobileApp()));
}
