# bic_kafue_mobile

Flutter mobile client (Android, iOS; Linux desktop is used only as interim native evidence).
A go_router app over the shared packages (`packages/design_system`, `packages/client_core`).
The current five-tab experience includes public content and giving, membership and current
access, duties/follow-ups and cell programmes. Backend adapters are composed through the
shared client core. This directory has Android, iOS and Linux targets; it has no web target.

For current setup, fictional accounts and realistic Epic 6 workflows, use the
[owner walkthrough](../../docs/runbooks/content-owner-walkthrough.md). The original
[client-shell evidence](../../docs/runbooks/client-shells.md) records the story 1.7 tracer;
it is historical scaffolding evidence, not current member acceptance.

```sh
flutter run -d linux \
  --dart-define=SUPABASE_URL=http://127.0.0.1:54321 \
  --dart-define=SUPABASE_PUBLISHABLE_KEY=<publishable key from `npx supabase status`>
```

Only the project URL and the publishable key may be passed to the client.
Use the walkthrough's emulator/device URL mapping; a phone's localhost is not the host machine.
