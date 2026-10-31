# Client commissioning protocol ? implementation contract, not a deployed API

This documents the Dart client added by the approved onboarding feature. The corresponding database, Edge Function and operator commands remain unfinished. Do not activate the client as proof that privileged provisioning exists.

## Transport and input

The client calls POST `/functions/v1/identity-admin-onboarding` with only its publishable API key; there is no ambient user session or server key. It refuses redirects and accepts a bounded JSON response. All actions carry `version = 1`, `invitation` and normalized `phone_username` in the request body, never in the URL.

| Action | Additional fields | Meaning |
| --- | --- | --- |
| `inspect` | None | Validate authority for this intended enrollment; return only the permitted next state, notice and mode. A returning holder may learn the correlated pending/completed state. |
| `complete` | `full_name`, privately entered `password`, `privacy_notice_version`, `privacy_accepted = true`, `request_id` | Request commissioning. For an existing account the password is authentication, never permission to reset it. |
| `status` | Original `request_id` | Reconcile the existing operation without resending a password. |

The client request ID is an idempotency correlation value, not evidence of identity or authority. The backend must create and verify its own ownership/provisioning correlation and never adopt an arbitrary Auth account because a request ID, phone or user-editable metadata happens to match.

## Responses the client understands

| `outcome` | Required extra fields | Client behaviour |
| --- | --- | --- |
| `ready` | `mode` = `new_account` or `existing_account`; nonempty `privacy_notice_version`, `privacy_notice_text`; UTC `expires_at` | Show appropriate details/password form and explicit notice acknowledgement. |
| `pending` | `request_id` UUID | Retain or recover the original operation and offer status checking only. |
| `completed` | `sign_in_required = true` | Clear setup state; require ordinary sign-in, never accept a token from this response. |
| `activation_pending` | `sign_in_required = true` | Explain that the account is prepared but private access has not been activated. |
| `refused` | No sensitive explanation | Generic invalid/expired/revoked/wrong-account/used outcome; do not enumerate another account. |
| `password_rejected` | No password or account detail | Allow private re-entry only when the server can prove no uncertain provisioning remains. |
| `rate_limited`, `unavailable`, `uncertain` | No secret values | Tell the truth about failure. After a mutation these cannot prove it did not commit, so the client offers status reconciliation rather than provisioning again. |

Malformed, oversized, unexpected or non-200 success-shaped replies cannot produce confirmed success. Terminal outcomes from inspect are allowed only for the holder's own correlated operation; replays must never repeat privilege creation.

## Server obligations still to implement and prove

Owner-only issue/revoke/reissue; account/environment binding; 24-hour expiry; digest-only secret storage; durable terminal commissioning, including upgrade from prior Admin grants; rate limiting; closed-policy and closed-signup behaviour; current account/session/identity checks; provider-operation fencing; atomic member/link/Admin/audit completion; uncertain provider recovery; lifecycle/erasure coverage. A held/deleted or subsequently unlinked account must not be revived by replaying setup. Existing last-Admin recovery remains distinct.

Status-only recovery must work after a client reload, and a server timeout must not result in the operator issuing a second competing setup. The setup cannot hold privileged credentials or Auth session tokens in its public response or audit.
