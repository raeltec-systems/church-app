import 'package:church_design_system/church_design_system.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/access_controllers.dart';
import '../application/providers.dart';
import '../application/user_management_controllers.dart';
import '../domain/membership_review.dart';
import '../domain/user_management.dart';
import 'user_change_banner.dart';

class UserProfileEditor extends ConsumerStatefulWidget {
  const UserProfileEditor({super.key, required this.member});
  final ManagedMember member;
  @override
  ConsumerState<UserProfileEditor> createState() => _UserProfileEditorState();
}

class _ContactFields {
  _ContactFields({
    String phone = '',
    this.owner = ContactOwner.member,
    String? label,
  }) : phone = TextEditingController(text: phone),
       label = TextEditingController(text: label);
  final TextEditingController phone;
  final TextEditingController label;
  ContactOwner owner;
  void dispose() {
    phone.dispose();
    label.dispose();
  }
}

class _UserProfileEditorState extends ConsumerState<UserProfileEditor> {
  final _form = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final int _generation;
  final _contacts = <_ContactFields>[];
  ConsentBasis? _consent;
  bool _closing = false;
  @override
  void initState() {
    super.initState();
    _generation = ref.read(accountGenerationProvider);
    _name = TextEditingController(text: widget.member.record.displayName);
    for (final r in widget.member.record.contactRoutes) {
      _contacts.add(
        _ContactFields(phone: r.phone, owner: r.owner, label: r.holderLabel),
      );
    }
  }

  @override
  void dispose() {
    _name.dispose();
    for (final r in _contacts) {
      r.dispose();
    }
    super.dispose();
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    await ref.read(userManagementProvider.notifier).updateProfile(
      widget.member,
      _name.text,
      [
        for (final r in _contacts)
          {
            'phone': r.phone.text.trim(),
            'belongs_to': r.owner.wire,
            'holder_label': r.owner == ContactOwner.member
                ? null
                : r.label.text.trim(),
          },
      ],
      _consent!,
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(userManagementProvider);
    final allowed = ref.watch(
      myAccessProvider.select((x) => x.grants?.isAdmin == true),
    );
    final generation = ref.watch(accountGenerationProvider);
    if (!allowed || generation != _generation) {
      _close();
      return const ChurchDialog(
        title: 'Access ended',
        content: Text('No member details are shown.'),
        actions: [],
      );
    }
    ref.listen(userManagementProvider.select((x) => x.notice), (_, next) {
      final latest = ref.read(userManagementProvider);
      if (next == UserChangeNotice.saved &&
          latest.change?.memberId == widget.member.id &&
          latest.change?.request.command ==
              UserManagementCommands.updateProfile) {
        _close();
      }
    });
    final changed =
        s.detail != null &&
        s.detail!.member.record.revision != widget.member.record.revision;
    final frozen =
        s.unsettled ||
        changed ||
        s.detailLoading ||
        s.detail?.member.id != widget.member.id;
    return PopScope(
      canPop: !s.busy,
      child: ChurchDialog(
        title: 'Edit name & contacts',
        content: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.member.record.displayName,
                style: ChurchType.cardTitle,
              ),
              const SizedBox(height: 8),
              const Text(
                'These are agreed contact details, not sign-in credentials. Saving will not change the person\'s phone username, recovery email or password.',
              ),
              const SizedBox(height: 16),
              if (s.busy || s.notice != null) ...[
                UserChangeBanner(state: s),
                const SizedBox(height: 16),
              ],
              if (changed) ...[
                const Text(
                  'The record changed. Close this editor and review the latest details before editing again.',
                ),
                const SizedBox(height: 12),
              ],
              TextFormField(
                key: const Key('user-profile-name'),
                controller: _name,
                enabled: !frozen,
                maxLength: 120,
                decoration: const InputDecoration(labelText: 'Full name'),
                validator: (value) =>
                    value == null ||
                        value.trim().isEmpty ||
                        RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)
                    ? 'Enter the agreed full name without control characters.'
                    : null,
              ),
              const SizedBox(height: 12),
              for (final (index, r) in _contacts.indexed)
                Padding(
                  key: ObjectKey(r),
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TextFormField(
                        key: Key('user-profile-phone-$index'),
                        controller: r.phone,
                        enabled: !frozen,
                        keyboardType: TextInputType.phone,
                        maxLength: 16,
                        decoration: const InputDecoration(
                          labelText: 'Contact number with country code',
                          helperText: 'Include + and country code.',
                        ),
                        validator: (value) {
                          final phone = value?.trim() ?? '';
                          if (!RegExp(r'^\+[1-9][0-9]{7,14}$')
                              .hasMatch(phone)) {
                            return 'Enter a full international number.';
                          }
                          if (_contacts
                                  .where(
                                    (x) =>
                                        x.phone.text.trim() == phone &&
                                        x.owner == r.owner,
                                  )
                                  .length >
                              1) {
                            return 'This contact is already listed.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<ContactOwner>(
                        key: ValueKey(
                          'user-profile-owner-$index-${r.owner.name}',
                        ),
                        initialValue: r.owner,
                        isExpanded: true,
                        decoration: const InputDecoration(
                          labelText: 'Whose number is this?',
                        ),
                        items: [
                          for (final owner in ContactOwner.values)
                            DropdownMenuItem(
                              value: owner,
                              child: Text(owner.label),
                            ),
                        ],
                        onChanged: frozen
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => r.owner = value);
                                }
                              },
                      ),
                      if (r.owner != ContactOwner.member) ...[
                        const SizedBox(height: 8),
                        TextFormField(
                          key: Key('user-profile-holder-$index'),
                          controller: r.label,
                          enabled: !frozen,
                          maxLength: 60,
                          decoration: const InputDecoration(
                            labelText: 'Contact holder label',
                          ),
                          validator: (value) =>
                              value == null ||
                                  value.trim().isEmpty ||
                                  RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)
                              ? 'Say whose number this is.'
                              : null,
                        ),
                      ],
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: TextButton.icon(
                          key: Key('user-profile-remove-$index'),
                          onPressed: frozen
                              ? null
                              : () => setState(() {
                                  _contacts.remove(r);
                                  r.dispose();
                                }),
                          icon: const Icon(
                            Icons.remove_circle_outline,
                            size: 18,
                          ),
                          label: const Text('Remove contact route'),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_contacts.length < 5)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: OutlinedButton.icon(
                    key: const Key('user-profile-add-contact'),
                    onPressed: frozen
                        ? null
                        : () => setState(() => _contacts.add(_ContactFields())),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add contact route'),
                  ),
                ),
              const SizedBox(height: 16),
              DropdownButtonFormField<ConsentBasis>(
                key: const Key('user-profile-consent'),
                initialValue: _consent,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'How were these details agreed?',
                ),
                items: [
                  for (final basis in ConsentBasis.values)
                    DropdownMenuItem(value: basis, child: Text(basis.label)),
                ],
                onChanged: frozen
                    ? null
                    : (value) => setState(() => _consent = value),
                validator: (value) =>
                    value == null ? 'Record how the person agreed.' : null,
              ),
            ],
          ),
        ),
        actions: [
          OutlinedButton(
            key: const Key('user-profile-cancel'),
            onPressed: s.busy ? null : () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          FilledButton(
            key: const Key('user-profile-save'),
            onPressed: frozen ? null : _save,
            child: const Text('Save changes'),
          ),
        ],
      ),
    );
  }
}
