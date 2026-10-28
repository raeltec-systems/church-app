import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';

import {
  CORRECTIONS, DEFAULT_OUT, MANUSCRIPT, PROVENANCE, buildBook, cleanLine, convertBook, formatBook,
  formatReport, loadInputs, main, normalizeKey, sha256,
} from './convert.mjs';

// Small test books in the printed layout (pdftotext -layout: pages end with a form feed, a running
// header first, the page number last). Placeholder words only: never hymn text.
const FRONT = 'FIRST EDITION.............1936\nTest Press\n';
const INDEX = [
  '   ZIINDULULO\nMakani Aanyimbo\nTest Opening:\nTest Hymn One ........ 1\nTest Hymn Two .... 2\n'
    + 'Test Life:\nTest Part:\nTest Hymn Three ..... 3\nZiindululo ........ 1 - 2\n  9\n',
  '   MAKANI AANYIMBO\nAlphabetical Index\nINYIMBO\nTest Hymn One ....... 1\nTest Hymn Three ... 3\n'
    + 'Test Hymn Two ......... 2\nZINDULULO\nTest Chorus One ....... 1\nTest Chorus Two ...... 2\n  10\n',
];
const SMALL = [
  FRONT,
  '      TEST OPENING\n\n   1 Test Hymn One (Cila)\n\n(TEST ORIGINAL ONE) (Z.H. 12) Key of A Flat\n\n'
    + '        1 Alpha line one,\n\n           alpha line two.\n\n             Ciindululo:\n'
    + '        Refrain line one,\n          refrain line two.\n\n      2 Beta line one,\n'
    + '    beta line two.\n                1\n',
  '      TEST OPENING\n   2 Test Hymn Two\n\n     Single stanza line one,\n     single stanza line two.\n'
    + '   3 Test Hymn Three (TEST ORIGINAL THREE)\n(Z.H. 9) Key of B\nFlat\n'
    + '   1 Gamma line, with \u201ftwo\u201f marks.\n                2\n',
  '      TEST LIFE\n   2 Delta line.\n     1 Test Chorus One\n   Chorus words only.\n'
    + '     2 Test Chorus Two\n   1 Epsilon line.\n   Ciindululo:\n   First refrain.\n'
    + '   2 Zeta line.\n   Ciindululo:\n   Second refrain.\n                3\n',
  ...INDEX,
].join('\f');

const EXPECTED = [
  {
    id: 'hymn-1', kind: 'hymn', number: 1, section: 'Test Opening', title: 'Test Hymn One (Cila)',
    original: 'TEST ORIGINAL ONE', reference: 'Z.H. 12', key: 'A flat',
    verses: ['Alpha line one,\nalpha line two.', 'Beta line one,\nbeta line two.'],
    choruses: [{ from_verse: 1, text: 'Refrain line one,\nrefrain line two.' }],
  },
  {
    id: 'hymn-2', kind: 'hymn', number: 2, section: 'Test Opening', title: 'Test Hymn Two',
    original: null, reference: null, key: null,
    verses: ['Single stanza line one,\nsingle stanza line two.'], choruses: [],
  },
  {
    id: 'hymn-3', kind: 'hymn', number: 3, section: 'Test Life: Test Part', title: 'Test Hymn Three',
    original: 'TEST ORIGINAL THREE', reference: 'Z.H. 9', key: 'B flat',
    verses: ['Gamma line, with \u2019two\u2019 marks.', 'Delta line.'], choruses: [],
  },
  {
    id: 'chorus-1', kind: 'chorus', number: 1, section: 'Ziindululo', title: 'Test Chorus One',
    original: null, reference: null, key: null, verses: ['Chorus words only.'], choruses: [],
  },
  {
    id: 'chorus-2', kind: 'chorus', number: 2, section: 'Ziindululo', title: 'Test Chorus Two',
    original: null, reference: null, key: null, verses: ['Epsilon line.', 'Zeta line.'],
    choruses: [{ from_verse: 1, text: 'First refrain.' }, { from_verse: 2, text: 'Second refrain.' }],
  },
];

function withTempDir(run) {
  const dir = mkdtempSync(join(tmpdir(), 'hymn-book-'));
  try {
    return run(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function quietMain(argv) {
  const out = [];
  const err = [];
  const code = main(argv, { log: (s) => out.push(s), error: (s) => err.push(s) });
  return { code, out: out.join('\n'), err: err.join('\n') };
}

test('a small printed book becomes hymns and choruses with sections, keys and choruses', () => {
  const result = convertBook(SMALL);
  assert.deepEqual(result.problems, []);
  assert.deepEqual(result.items, EXPECTED);
  assert.deepEqual(result.stats, { pages: 6, hymns: 3, choruses: 2 });
  assert.ok(result.notes.some((n) => /chorus 2 has a different chorus from verse 2 on/.test(n.message)));
});

test('a chorus first printed after a later verse is shown from that verse on, with a note', () => {
  const late = SMALL.replace(
    '             Ciindululo:\n        Refrain line one,\n          refrain line two.\n\n      2 Beta line one,\n    beta line two.\n',
    '      2 Beta line one,\n    beta line two.\n             Ciindululo:\n        Refrain line one,\n          refrain line two.\n',
  );
  assert.notEqual(late, SMALL);
  const result = convertBook(late);
  assert.deepEqual(result.problems, []);
  assert.deepEqual(result.items[0].choruses, [{ from_verse: 2, text: 'Refrain line one,\nrefrain line two.' }]);
  assert.ok(result.notes.some((n) => n.message === 'hymn 1 prints its chorus first after verse 2; it is shown from there on'));
});

test('an English title printed both on the heading and under it is a problem, not a silent choice', () => {
  const both = SMALL.replace('(Z.H. 9) Key of B', '(OTHER TUNE) Key of B');
  assert.deepEqual(convertBook(both).problems.map((p) => p.message),
    ['hymn 3 prints an English title on its heading ("TEST ORIGINAL THREE") and under it ("OTHER TUNE")']);
});

test('a one-line verse 1 completed by verse 2 is noted for the printed book check', () => {
  const split = SMALL.replace(
    '        1 Alpha line one,\n\n           alpha line two.\n',
    '        1 Alpha line one,\n        2 alpha line two.\n',
  ).replace('      2 Beta line one,\n    beta line two.\n', '      3 Beta line one,\n    beta line two.\n      4 Gamma line one,\n    gamma line two.\n');
  const result = convertBook(split);
  assert.deepEqual(result.problems, []);
  assert.deepEqual(result.items[0].verses.map((v) => v.split('\n').length), [1, 1, 2, 2]);
  assert.ok(result.notes.some((n) => n.message === 'hymn 1: verse 1 is one line and verse 2 completes its stanza (lines per verse 1, 1, 2, 2); check the verse numbers against the printed book'));
});

test('reviewed corrections apply only to the exact extracted line', () => {
  const lines = SMALL.split('\n');
  const at = lines.findIndex((l) => l.includes('Beta line one,')) + 1;
  const ok = convertBook(SMALL, {
    corrections: [{ line: at, extracted: '2 Beta line one,', corrected: '2 Beta line ONE,', why: 'test' }],
  });
  assert.deepEqual(ok.problems, []);
  assert.equal(ok.items[0].verses[1], 'Beta line ONE,\nbeta line two.');
  assert.equal(ok.applied.length, 1);
  const stale = convertBook(SMALL, {
    corrections: [{ line: at, extracted: '2 Something else', corrected: 'x', why: 'test' }],
  });
  assert.equal(stale.problems.length, 1);
  assert.match(stale.problems[0].message, /expects "2 Something else" but the text is "2 Beta line one,"/);
});

test('a manuscript with a gap, a repeated number, an empty verse and a stray line is refused', () => {
  const faulty = SMALL
    .replace('      TEST OPENING\n\n   1 Test Hymn One', '      TEST OPENING\nA stray line.\n   1 Test Hymn One')
    .replace('      2 Beta line one,\n    beta line two.', '      2\n      3 Beta line three.')
    .replace('   2 Test Hymn Two\n\n     Single stanza line one,\n     single stanza line two.\n', '')
    .replace('alpha line two.\n', 'alpha line two.\n   1 Test Hymn One (Cila)\n(TEST ORIGINAL ONE)\n');
  const { problems } = convertBook(faulty);
  const messages = problems.map((p) => p.message);
  assert.ok(messages.includes('cannot place this line: it comes before the first heading ("A stray line.")'), messages.join('\n'));
  assert.ok(messages.includes('verse 2 of hymn 1 is empty'), messages.join('\n'));
  assert.ok(messages.includes('hymn 2 is missing before hymn 3'), messages.join('\n'));
  assert.ok(messages.some((m) => /^hymn 1 appears more than once \(first at line \d+\)$/.test(m)), messages.join('\n'));
  assert.ok(messages.includes('hymn numbers missing from the book: 2'), messages.join('\n'));
});

test('titles are checked against the indexes; larger differences need an explanation', () => {
  const close = convertBook(SMALL.replace('1 Test Hymn One (Cila)', '1 Test Hymn Onx (Cila)'));
  assert.deepEqual(close.problems, []);
  assert.ok(close.notes.some((n) => /hymn 1 "Test Hymn Onx \(Cila\)" differs .* by 1 letter; the heading is kept as printed/.test(n.message)));
  const far = SMALL.replace('1 Test Hymn One (Cila)', '1 Test Hymn Something (Cila)');
  const unexplained = convertBook(far);
  assert.match(unexplained.problems.map((p) => p.message).join('\n'),
    /hymn 1 "Test Hymn Something \(Cila\)" differs from its index entry "Test Hymn One" and "Test Hymn One"; explain it/);
  const explained = convertBook(far, {
    explanations: [{ kind: 'hymn', number: 1, why: 'the alphabetical index uses an older title' }],
  });
  assert.deepEqual(explained.problems, []);
  const stale = convertBook(SMALL, { explanations: [{ kind: 'chorus', number: 2, why: 'x' }] });
  assert.deepEqual(stale.problems.map((p) => p.message),
    ['the explanation for chorus 2 no longer matches a title difference']);
});

test('the book stores apostrophes the fonts carry and keys as words', () => {
  assert.equal(cleanLine('Nsius\u201f Insoni').text, 'Nsius\u2019 Insoni');
  assert.equal(cleanLine('ng\u02bcanda e\u0301').text, 'ng\u2019anda \u00e9');
  assert.equal(cleanLine('  \u201eQuoted\u201d  words ').text, '\u201eQuoted\u201d words');
  for (const [input, expected] of [
    ['F', 'F'], ['A Flat', 'A flat'], ['E FLAT', 'E flat'], ['A Flat or D', 'A flat or D'], ['f sharp', 'F sharp'],
  ]) assert.equal(normalizeKey(input), expected, input);
  for (const input of ['H', 'Flat', 'A Flat or', '']) assert.equal(normalizeKey(input), null, input);
  assert.deepEqual(Object.keys(buildBook([], { edition: 'test-1', title: 'T', language: 'toi' })),
    ['format', 'edition', 'title', 'language', 'items']);
  assert.throws(() => buildBook([], { edition: 'Bad', title: 'T', language: 'toi' }), TypeError);
});

test('the church hymn book: 199 hymns and 67 choruses from the pinned PDF, with no problems', () => {
  const inputs = loadInputs();
  assert.equal(inputs.provenance.pdf_sha256, '0733124a4e5376ea8504e4709b77b7d03117f187a1b8b4fd13768a0f4d621139');
  assert.equal(inputs.provenance.pdf_bytes, 1631474);
  const text = inputs.text.replace(/\r\n?/g, '\n');
  assert.equal(sha256(text), inputs.provenance.text_sha256_lf, 'the checked-in text is the pinned extraction');
  assert.equal((text.match(/\f/g) ?? []).length, inputs.provenance.page_breaks);
  const result = convertBook(text, {
    corrections: inputs.corrections.corrections,
    explanations: inputs.corrections.index_differences,
  });
  assert.deepEqual(result.problems, []);
  assert.equal(result.applied.length, inputs.corrections.corrections.length);
  const numbers = (kind) => result.items.filter((i) => i.kind === kind).map((i) => i.number);
  assert.deepEqual(numbers('hymn'), Array.from({ length: 199 }, (_, i) => i + 1));
  assert.deepEqual(numbers('chorus'), Array.from({ length: 67 }, (_, i) => i + 1));
  assert.ok(result.items.every((i) => i.title !== '' && i.verses.length > 0 && i.section));
  // The shipped asset and the committed report are exactly what the converter produces.
  const book = buildBook(result.items, inputs.provenance.book);
  const lines = (s) => s.replace(/\r\n/g, '\n');
  assert.equal(lines(readFileSync(DEFAULT_OUT, 'utf8')), formatBook(book), 'run: node tools/hymn-book/convert.mjs');
  const report = new URL('./conversion-report.txt', import.meta.url);
  assert.equal(lines(readFileSync(report, 'utf8')), formatReport(result, inputs.provenance),
    'run: node tools/hymn-book/convert.mjs --report tools/hymn-book/conversion-report.txt');
});

test('the command line checks, writes, and refuses a faulty book without writing', () => {
  assert.equal(quietMain(['--check']).code, 0);
  withTempDir((dir) => {
    const manuscript = join(dir, 'book.txt');
    const provenance = join(dir, 'provenance.json');
    const corrections = join(dir, 'corrections.json');
    const out = join(dir, 'book.json');
    const faulty = SMALL.replace('   2 Test Hymn Two\n', '');
    writeFileSync(manuscript, faulty);
    const meta = JSON.parse(readFileSync(PROVENANCE, 'utf8'));
    writeFileSync(provenance, JSON.stringify({ ...meta, text_sha256_lf: sha256(faulty) }));
    writeFileSync(corrections, JSON.stringify({ corrections: [], index_differences: [] }));
    const refused = quietMain(['--manuscript', manuscript, '--provenance', provenance,
      '--corrections', corrections, '--out', out]);
    assert.equal(refused.code, 1);
    assert.equal(existsSync(out), false);
    assert.match(refused.err, /no book was written/);
    writeFileSync(manuscript, SMALL);
    writeFileSync(provenance, JSON.stringify({ ...meta, text_sha256_lf: sha256(SMALL) }));
    const written = quietMain(['--manuscript', manuscript, '--provenance', provenance,
      '--corrections', corrections, '--out', out]);
    assert.equal(written.code, 0, written.err);
    assert.equal(JSON.parse(readFileSync(out, 'utf8')).items.length, 5);
    writeFileSync(provenance, JSON.stringify({ ...meta, text_sha256_lf: 'not-the-hash' }));
    assert.equal(quietMain(['--manuscript', manuscript, '--provenance', provenance,
      '--corrections', corrections, '--out', out]).code, 2, 'a text that is not the pinned extraction');
  });
  assert.equal(quietMain(['--bogus']).code, 2);
  assert.ok(existsSync(MANUSCRIPT) && existsSync(CORRECTIONS));
});
