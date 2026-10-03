// Secret detection rules shared by the repository scan, the client-bundle scan and the
// environment-config check (story 1.8, AD-17: secrets live only in server/CI secret stores).
//
// mode "repo":   tracked source files. Flags real credentials of any kind.
// mode "bundle": built client output. Additionally flags ANY JWT and the literal service_role:
//                clients may only carry the project URL and a publishable (sb_publishable_) key.

const JWT_RE = /\beyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g;

const RULES = [
  { rule: 'supabase_secret_key', re: /\bsb_secret_[A-Za-z0-9_-]{12,}/g },
  { rule: 'supabase_access_token', re: /\bsbp_(?:v0_)?[A-Za-z0-9]{32,}/g },
  // Story 1.9 system credential (tools/ops/system-credential.mjs); only its digest may be stored.
  { rule: 'system_credential', re: /\bsysc_(?:local|staging|production)_[A-Za-z0-9_-]{43}(?![A-Za-z0-9_-])/g },
  { rule: 'private_key', re: /-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY(?: BLOCK)?-----/g },
  { rule: 'github_token', re: /\b(?:gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{60,})/g },
  { rule: 'cloudflare_or_generic_bearer', re: /\bBearer\s+(?!\$|<|\[|\{)[A-Za-z0-9._~+/-]{40,}=*/g },
  // A postgres URL with an inline password, except local-stack defaults and placeholders.
  {
    rule: 'database_url_with_password',
    re: /\bpostgres(?:ql)?:\/\/[^:\s/@]+:([^@\s]+)@([^\s/:?'"]+)/g,
    keep: (m) => {
      const [, password, host] = m;
      if (/^(127\.0\.0\.1|localhost|db|host\.docker\.internal)$/i.test(host)) return false;
      if (/^(\$|<|\[|\{|\*+$|password$|postgres$|your-)/i.test(password)) return false;
      return true;
    },
  },
];

const BUNDLE_RULES = [
  { rule: 'service_role_reference', re: /service_role/gi },
  // The bare "sb_secret_" prefix is NOT flagged: supabase-dart compares key prefixes as string
  // literals. A real secret key (prefix + body) is caught by supabase_secret_key above.
];

function decodeJwtPayload(token) {
  try {
    const payload = token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/');
    return JSON.parse(Buffer.from(payload, 'base64').toString('utf8'));
  } catch {
    return null;
  }
}

function lineOf(text, index) {
  let line = 1;
  for (let i = 0; i < index && i < text.length; i++) if (text.charCodeAt(i) === 10) line++;
  return line;
}

/** Returns [{rule, line, excerpt}] for every secret-like value in `text`. */
export function findSecrets(text, { mode = 'repo' } = {}) {
  const hits = [];
  const push = (rule, m) => hits.push({
    rule,
    line: lineOf(text, m.index),
    // Never echo the value itself: only its first characters.
    excerpt: `${m[0].slice(0, 10)}…`,
  });
  for (const { rule, re, keep } of [...RULES, ...(mode === 'bundle' ? BUNDLE_RULES : [])]) {
    for (const m of text.matchAll(re)) if (!keep || keep(m)) push(rule, m);
  }
  for (const m of text.matchAll(JWT_RE)) {
    const payload = decodeJwtPayload(m[0]);
    const role = payload && typeof payload.role === 'string' ? payload.role : null;
    if (mode === 'bundle') push(role ? `jwt_in_client_bundle(role=${role})` : 'jwt_in_client_bundle', m);
    else push(role ? `jwt(role=${role})` : 'jwt', m);
  }
  return hits;
}
