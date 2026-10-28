// Entry 6.16: pieces the staff Content editors (banners and rights, events,
// giving, sermons, announcements) share instead of keeping their own copies.
// Internal: not exported from the package.
import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';

/// Asks the editor to confirm a lifecycle change (publish, withdraw,
/// archive, discard). True only when they chose [yes] and [context] is
/// still mounted. The buttons are keyed `<keyPrefix>-confirm-no` ("Keep
/// it") and `<keyPrefix>-confirm-yes`.
Future<bool> confirmContentChange(
  BuildContext context, {
  required String keyPrefix,
  required String title,
  required String body,
  required String yes,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => ChurchDialog(
      title: title,
      content: Text(body),
      actions: [
        FocusRing(
          child: TextButton(
            key: Key('$keyPrefix-confirm-no'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
        ),
        FocusRing(
          child: FilledButton(
            key: Key('$keyPrefix-confirm-yes'),
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(yes),
          ),
        ),
      ],
    ),
  );
  return ok == true && context.mounted;
}
