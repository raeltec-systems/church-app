// Story 6.7: turns the church's hymn book, "Inyimbo zya Bakristo" (Brethren in Christ Church,
// Choma, 2012 reprint), into the app's built-in book: packages/client_core/assets/hymn_book/
// hymn_book.json (format 1), which both apps bundle. Nothing about hymn text is stored on a server.
//
// Input (checked in, so the build is reproducible without a PDF library):
//   tools/hymn-book/manuscript/inyimbo_zyabakristo.txt  the PDF's text, extracted with the command
//                                                        and checked against the SHA-256 in
//   tools/hymn-book/manuscript/provenance.json          (with the book's edition, title, language)
//   tools/hymn-book/corrections.json                    reviewed fixes for extraction glitches and
//                                                        explanations of index differences
//
// The printed layout (pdftotext -layout; pages end with a form feed):
//   * front matter (editions, preface, symbols), then content pages, then the indexes: the topical
//     index "Makani Aanyimbo" (every hymn under its section, then "Ziindululo 1 - 67"), the
//     alphabetical hymn index (INYIMBO) and the alphabetical chorus index (ZINDULULO);
//   * each content page starts with a running section header and ends with its page number;
//   * two number sequences: hymns 1..N, then the choruses (ziindululo) 1..M; a heading is
//     "<number> <title>", optionally followed by a line in parentheses holding the English title
//     or tune name, an optional hymnal reference (Z.H. = Zulu Hymnal, M.H. = Methodist Hymn Book)
//     and an optional "Key of ...";
//   * verses are numbered "1 ...", "2 ..."; blank lines carry no meaning; "Ciindululo:" starts the
//     chorus, printed once and sung after each verse; some items are one unnumbered stanza.
// Headings are found by the expected next number of each sequence, checked against the indexes.
//
// Any problem (a gap, a repeated or out-of-order number, an empty verse, a line that cannot be
// placed, an unexplained title difference from the indexes, a limit exceeded) refuses the whole
// book: nothing is written.
//
// Usage: node tools/hymn-book/convert.mjs [--check] [--out <book.json>] [--report <report.txt>]
// Exit codes: 0 converted or checked cleanly, 1 the book has problems, 2 usage or input error.
import { createHash } from 'node:crypto';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = (path) => fileURLToPath(new URL(path, import.meta.url));

export const MANUSCRIPT = here('./manuscript/inyimbo_zyabakristo.txt');
export const PROVENANCE = here('./manuscript/provenance.json');
export const CORRECTIONS = here('./corrections.json');
export const DEFAULT_OUT = here('../../packages/client_core/assets/hymn_book/hymn_book.json');

/** The limits the app's strict model also enforces (hymn_book.dart). */
export const LIMITS = Object.freeze({
  maxNumber: 999,
  maxTitle: 120,
  maxOriginal: 200,
  maxReference: 60,
  maxVerses: 40,
  maxLinesPerBlock: 40,
  maxLine: 200,
});

export const KEY_PATTERN = /^[A-G](?: flat| sharp)?(?: or [A-G](?: flat| sharp)?)?$/;
export const EDITION_PATTERN = /^[a-z0-9][a-z0-9.-]{0,63}$/;
export const LANGUAGE_PATTERN = /^[a-z]{2,3}(?:-[A-Za-z0-9]{2,8})*$/;

/** The printed book's layout. Adapt here if another edition is laid out differently. */
export const LAYOUT = Object.freeze({
  frontMatter: [/^FIRST EDITION/, /^Preface$/, /^DEFINITION OF SYMBOLS$/],
  topicalIndex: /^Makani Aanyimbo$/,
  hymnIndex: /^INYIMBO$/,
  chorusIndex: /^ZINDULULO$/,
  indexNoise: [/^MAKANI AANYIMBO$/, /^ALPHABETICAL INDEX$/i, /^ZIINDULULO$/],
  indexEntry: /^(.*?)\s*(?:\.{2,}|\u2026)[.\u2026\s]*(\d{1,3})(?:\s*-\s*(\d{1,3}))?$/,
  pageNumber: /^\d{1,3}$/,
  numbered: /^(\d{1,3})\s+(\S.*)$/,
  // An English title printed on the heading line itself: a trailing group without lower case.
  headingOriginal: /^(.*\S)\s*\(([^()a-z]*[A-Z][^()a-z]*)\)$/,
  keyContinuation: /^(Flat|Sharp)$/i,
  bareNumber: /^(\d{1,2})$/,
  key: /^Key of\s+(.+)$/i,
  reference: /^(?:Z\.H\.|M\.H\.)/,
  chorusLabel: /^Ciindululo\s*:?$/i,
  chorusSection: /^Ziindululo$/i,
});

const SPACES = /[\t\u00a0\u1680\u2000-\u200a\u202f\u205f\u3000]/g;
const INVISIBLE = /[\u00ad\u200b-\u200d\u2060\ufeff]/g;
const FORBIDDEN = /[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/;

/**
 * One line as the book stores it: NFC; the double high-reversed-9 quotation mark (U+201F, used as
 * an apostrophe in this book and missing from the app's fonts) and the modifier-letter apostrophe
 * (U+02BC) as the typographic apostrophe U+2019; every kind of space as one space; trimmed.
 */
export function cleanLine(raw) {
  const text = String(raw)
    .normalize('NFC')
    .replace(/[\u201f\u02bc]/g, '\u2019')
    .replace(INVISIBLE, '')
    .replace(SPACES, ' ')
    .replace(/ {2,}/g, ' ')
    .trim();
  return { text, forbidden: FORBIDDEN.test(text) };
}

/** "A Flat" -> "A flat"; "A Flat or D" -> "A flat or D"; null when it is not a key. */
export function normalizeKey(raw) {
  const key = String(raw).trim().replace(/\s+/g, ' ').replace(/[.;,]$/, '')
    .replace(/\b(flat|sharp)\b/gi, (word) => word.toLowerCase())
    .replace(/^([a-g])/, (letter) => letter.toUpperCase())
    .replace(/ or ([a-g])/, (_, letter) => ` or ${letter.toUpperCase()}`);
  return KEY_PATTERN.test(key) ? key : null;
}

/** Letters and digits only, lower case, without apostrophes, accents or "(Cila)". */
export function titleKey(title) {
  return String(title)
    .normalize('NFKD')
    .replace(/[\u0300-\u036f]/g, '')
    .toLowerCase()
    .replace(/\(cila\)/g, '')
    .replace(/['`\u2018\u2019\u201b\u201f\u02bc]/g, '')
    .replace(/[^a-z0-9]+/g, ' ')
    .trim();
}

/** Edit distance between two short strings. */
export function editDistance(a, b) {
  const row = Array.from({ length: b.length + 1 }, (_, j) => j);
  for (let i = 1; i <= a.length; i++) {
    let diagonal = row[0];
    row[0] = i;
    for (let j = 1; j <= b.length; j++) {
      const above = row[j];
      row[j] = Math.min(row[j] + 1, row[j - 1] + 1, diagonal + (a[i - 1] === b[j - 1] ? 0 : 1));
      diagonal = above;
    }
  }
  return row[b.length];
}

function similarity(a, b) {
  const x = titleKey(a);
  const y = titleKey(b);
  if (x === '' || y === '') return 0;
  return 1 - editDistance(x, y) / Math.max(x.length, y.length);
}

/** Splits the text into numbered lines and pages; a form feed ends a page. */
function readPages(text) {
  const pages = [];
  let page = { index: 0, lines: [] };
  text.split('\n').forEach((raw, i) => {
    const parts = raw.split('\f');
    parts.forEach((part, k) => {
      if (k > 0) {
        pages.push(page);
        page = { index: page.index + 1, lines: [] };
      }
      page.lines.push({ n: i + 1, raw: part });
    });
  });
  pages.push(page);
  return pages
    .map((p) => ({ ...p, lines: p.lines.filter((l) => l.raw.trim() !== '') }))
    .filter((p) => p.lines.length > 0);
}

/**
 * Converts the extracted text. Returns { items, problems, notes, applied, stats }; a book is
 * written only when problems is empty. Each problem and note is { line, message }.
 */
export function convertBook(rawText, { corrections = [], explanations = [], layout = LAYOUT } = {}) {
  const problems = [];
  const notes = [];
  const report = (list) => (line, message) => list.push({ line, message });
  const problem = report(problems);
  const note = report(notes);

  // Reviewed corrections, applied by line number to the exact extracted text.
  const text = String(rawText).replace(/^\ufeff/, '').replace(/\r\n?/g, '\n');
  const lines = text.split('\n');
  const applied = [];
  for (const fix of corrections) {
    const index = fix.line - 1;
    const current = lines[index];
    const visible = current === undefined ? undefined : current.replace(/\f/g, '').trim();
    if (visible !== fix.extracted) {
      problem(fix.line, `the correction for this line expects "${fix.extracted}" but the text is "${visible}"`);
      continue;
    }
    const feeds = current.match(/^\f*/)[0];
    lines[index] = `${feeds}${fix.corrected}`;
    applied.push(fix);
  }
  const pages = readPages(lines.join('\n'));

  // Classify pages: front matter, content, indexes (everything from the topical index on).
  const content = [];
  const indexPages = [];
  let inIndex = false;
  for (const page of pages) {
    const first = cleanLine(page.lines[0].raw).text;
    const second = page.lines[1] ? cleanLine(page.lines[1].raw).text : '';
    if (!inIndex && layout.topicalIndex.test(second)) inIndex = true;
    if (inIndex) indexPages.push(page);
    else if (layout.frontMatter.some((re) => re.test(first))) continue;
    else content.push(page);
  }

  // The indexes: topical (section of every hymn), alphabetical hymns, alphabetical choruses.
  const topical = new Map();
  const hymnTitles = new Map();
  const chorusTitles = new Map();
  let chorusSection = null;
  let chorusRange = null;
  let list = null;
  let pendingSection = [];
  let section = null;
  for (const page of indexPages) {
    const body = page.lines.slice(1);
    if (body.length > 0 && layout.pageNumber.test(cleanLine(body.at(-1).raw).text)) body.pop();
    for (const row of body) {
      const t = cleanLine(row.raw).text;
      if (layout.topicalIndex.test(t)) { list = 'topical'; continue; }
      if (/^Alphabetical Index$/i.test(t)) { list = null; continue; }
      if (layout.hymnIndex.test(t)) { list = 'hymns'; continue; }
      if (layout.chorusIndex.test(t)) { list = 'choruses'; continue; }
      if (layout.indexNoise.some((re) => re.test(t))) continue;
      const entry = t.match(layout.indexEntry);
      if (list === 'topical' && !entry && t.endsWith(':')) {
        pendingSection.push(t.replace(/:$/, '').trim());
        continue;
      }
      if (!entry) {
        problem(row.n, `cannot read this index line: "${t}"`);
        continue;
      }
      const title = entry[1].trim();
      const number = Number(entry[2]);
      if (list === 'topical') {
        if (entry[3] !== undefined) {
          chorusSection = title;
          chorusRange = [number, Number(entry[3])];
          continue;
        }
        if (pendingSection.length > 0) {
          section = pendingSection.join(': ');
          pendingSection = [];
        }
        if (section === null) problem(row.n, 'a topical index entry comes before any section');
        if (topical.has(number)) problem(row.n, `hymn ${number} is listed twice in the topical index`);
        topical.set(number, { section, title, line: row.n });
      } else if (list === 'hymns' || list === 'choruses') {
        const map = list === 'hymns' ? hymnTitles : chorusTitles;
        if (map.has(number)) problem(row.n, `number ${number} is listed twice in the ${list} index`);
        map.set(number, { title, line: row.n });
      } else {
        problem(row.n, `cannot tell which index this line belongs to: "${t}"`);
      }
    }
  }
  const counts = { hymn: hymnTitles.size, chorus: chorusTitles.size };
  if (counts.hymn === 0) problem(null, 'no alphabetical hymn index was found');
  if (counts.chorus === 0) problem(null, 'no alphabetical chorus index was found');
  for (const [kind, map] of [['hymn', hymnTitles], ['chorus', chorusTitles]]) {
    for (let n = 1; n <= map.size; n++) {
      if (!map.has(n)) problem(null, `the ${kind} index has no number ${n}`);
    }
  }
  if (chorusSection === null || chorusRange[0] !== 1 || chorusRange[1] !== counts.chorus) {
    problem(null, `the topical index must end with the choruses 1 - ${counts.chorus}`);
  }

  // The content: headings by the expected next number of each sequence.
  const items = [];
  const seen = { hymn: new Map(), chorus: new Map() };
  let kind = 'hymn';
  let next = 1;
  let item = null;
  let block = null;
  const indexTitles = (k, n) => (k === 'hymn'
    ? [hymnTitles.get(n)?.title, topical.get(n)?.title]
    : [chorusTitles.get(n)?.title]).filter(Boolean);
  const looksLikeHeading = (k, n, rest) => {
    const title = rest.match(layout.headingOriginal)?.[1] ?? rest;
    return indexTitles(k, n).some((t) => similarity(title, t) >= 0.7);
  };
  const finishBlock = () => {
    if (!item || !block) return;
    if (block.lines.length === 0) {
      problem(block.line, block.kind === 'chorus'
        ? `the chorus of ${item.kind} ${item.number} has no words`
        : `verse ${block.number} of ${item.kind} ${item.number} is empty`);
    } else if (block.lines.length > LIMITS.maxLinesPerBlock) {
      problem(block.line, `this block of ${item.kind} ${item.number} has more than ${LIMITS.maxLinesPerBlock} lines`);
    }
    const value = block.lines.join('\n');
    if (block.kind === 'chorus') {
      // Printed once and sung after each verse; a different chorus printed after a later verse
      // is sung from that verse on. A repeat of the current one adds nothing.
      const current = item.choruses.at(-1);
      if (block.lines.length > 0 && current === undefined) {
        // Printed once, normally after verse 1, and sung after that verse and every later one.
        if (block.afterVerse > 1) {
          note(block.line, `${item.kind} ${item.number} prints its chorus first after verse ${block.afterVerse}; it is shown from there on`);
        }
        item.choruses.push({ from_verse: block.afterVerse, text: value });
      } else if (block.lines.length > 0 && current.text !== value) {
        if (current.from_verse === block.afterVerse) {
          problem(block.line, `${item.kind} ${item.number} prints two different choruses after verse ${block.afterVerse}`);
        } else {
          item.choruses.push({ from_verse: block.afterVerse, text: value });
          note(block.line, `${item.kind} ${item.number} has a different chorus from verse ${block.afterVerse} on`);
        }
      }
    } else if (block.lines.length > 0) {
      item.verses.push(value);
    }
    block = null;
  };
  const startItem = (row, n, rest, header) => {
    finishBlock();
    const own = cleanLine(rest).text.match(layout.headingOriginal);
    item = {
      kind, number: n, title: own ? own[1] : rest, line: row.n, header,
      original: own ? own[2].trim() : null, reference: null, key: null, verses: [], choruses: [],
      versesSeen: 0, stage: 'heading',
    };
    items.push(item);
    seen[kind].set(n, row.n);
    next = n + 1;
  };

  for (const page of content) {
    const header = cleanLine(page.lines[0].raw).text;
    const body = page.lines.slice(1);
    if (body.length > 0 && layout.pageNumber.test(cleanLine(body.at(-1).raw).text)) body.pop();
    body.forEach((row, at) => {
      const { text: t, forbidden } = cleanLine(row.raw);
      if (forbidden) problem(row.n, 'this line contains a control character');
      if (t.length > LIMITS.maxLine) problem(row.n, `this line is longer than ${LIMITS.maxLine} characters`);
      if (kind === 'hymn' && next > counts.hymn && counts.hymn > 0) {
        kind = 'chorus';
        next = 1;
      }
      const numbered = t.match(layout.numbered);
      if (numbered) {
        const n = Number(numbered[1]);
        const rest = numbered[2];
        const expectedVerse = item ? item.versesSeen + 1 : null;
        const nextRow = body[at + 1] ? cleanLine(body[at + 1].raw).text : '';
        const headingLike = looksLikeHeading(kind, n, rest) || nextRow.startsWith('(');
        if (n === next && (n !== expectedVerse || headingLike)) {
          startItem(row, n, rest, header);
          return;
        }
        if (n !== expectedVerse && headingLike) {
          if (seen[kind].has(n)) {
            problem(row.n, `${kind} ${n} appears more than once (first at line ${seen[kind].get(n)})`);
          } else if (n > next) {
            problem(row.n, `${kind}${n - next > 1 ? `s ${next}-${n - 1} are` : ` ${next} is`} missing before ${kind} ${n}`);
            startItem(row, n, rest, header);
            return;
          } else {
            problem(row.n, `${kind} ${n} is out of order (expected ${kind} ${next})`);
          }
          return;
        }
        if (item && n === expectedVerse) {
          finishBlock();
          item.versesSeen = n;
          item.stage = 'verse';
          block = { kind: 'verse', number: n, line: row.n, lines: [rest] };
          return;
        }
        if (item) {
          problem(row.n, `verse ${n} of ${item.kind} ${item.number} is out of order (expected verse ${expectedVerse})`);
          return;
        }
      }
      const bare = t.match(layout.bareNumber);
      if (bare && item && Number(bare[1]) === item.versesSeen + 1) {
        finishBlock();
        item.versesSeen = Number(bare[1]);
        item.stage = 'verse';
        block = { kind: 'verse', number: item.versesSeen, line: row.n, lines: [] };
        return;
      }
      if (!item) {
        problem(row.n, `cannot place this line: it comes before the first heading ("${t}")`);
        return;
      }
      if (item.stage === 'heading' && t.startsWith('(')) {
        const groups = [...t.matchAll(/\(([^()]*)\)/g)].map((g) => g[1].trim());
        const rest = t.replace(/\([^()]*\)/g, '').trim();
        if (groups.length === 0 || /[()]/.test(rest)) {
          problem(row.n, `cannot read the line under the heading of ${item.kind} ${item.number}: "${t}"`);
          return;
        }
        const references = groups.filter((g) => layout.reference.test(g));
        const names = groups.filter((g) => !layout.reference.test(g));
        if (names.length > 0) {
          const printed = [names[0], ...names.slice(1).map((g) => `(${g})`)].join(' ');
          if (item.original !== null) {
            problem(row.n, `${item.kind} ${item.number} prints an English title on its heading ("${item.original}") and under it ("${printed}")`);
          } else {
            item.original = printed;
          }
        }
        item.reference = references.length > 0 ? references.join('; ') : null;
        if (rest !== '') {
          const keyText = rest.match(layout.key);
          const key = keyText ? normalizeKey(keyText[1]) : null;
          if (key === null) {
            problem(row.n, `cannot read "${rest}" as the key of ${item.kind} ${item.number}`);
          } else {
            item.key = key;
          }
        }
        item.stage = 'info';
        return;
      }
      if (item.stage === 'info' && layout.keyContinuation.test(t) && /^[A-G]$/.test(item.key ?? '')) {
        // "Key of A" at the end of the line under the heading, "Flat" on the next line.
        item.key = normalizeKey(`${item.key} ${t}`);
        return;
      }
      if ((item.stage === 'heading' || item.stage === 'info') && layout.key.test(t)) {
        const key = normalizeKey(t.match(layout.key)[1]);
        if (key === null) problem(row.n, `cannot read "${t}" as the key of ${item.kind} ${item.number}`);
        else item.key = key;
        return;
      }
      if (t.startsWith('(') && item.stage !== 'verse' && item.stage !== 'chorus') {
        problem(row.n, `cannot place this line under ${item.kind} ${item.number}: "${t}"`);
        return;
      }
      if (layout.chorusLabel.test(t)) {
        finishBlock();
        if (item.versesSeen === 0) note(row.n, `${item.kind} ${item.number} prints its chorus before the first verse`);
        item.stage = 'chorus';
        block = { kind: 'chorus', line: row.n, lines: [], afterVerse: Math.max(1, item.versesSeen) };
        return;
      }
      if (block === null) {
        // An unnumbered stanza: the item's only verse (or a stanza after its chorus).
        if (item.versesSeen > 0 || item.verses.length > 0) {
          problem(row.n, `cannot place this line in ${item.kind} ${item.number}: it follows its chorus without a verse number`);
          return;
        }
        item.versesSeen = 1;
        item.stage = 'verse';
        block = { kind: 'verse', number: 1, line: row.n, lines: [] };
      }
      block.lines.push(t);
    });
  }
  finishBlock();

  // Every number of both sequences, the sections and the titles against the indexes.
  for (const [k, map] of [['hymn', hymnTitles], ['chorus', chorusTitles]]) {
    const found = new Set(items.filter((i) => i.kind === k).map((i) => i.number));
    const missing = [];
    for (let n = 1; n <= map.size; n++) if (!found.has(n)) missing.push(n);
    if (missing.length > 0) problem(null, `${k} numbers missing from the book: ${missing.join(', ')}`);
    for (const n of found) if (!map.has(n)) problem(null, `${k} ${n} is in the book but not in its index`);
  }
  const explained = new Map(explanations.map((e) => [`${e.kind}-${e.number}`, e]));
  const usedExplanations = new Set();
  for (const it of items) {
    if (it.title.length > LIMITS.maxTitle) problem(it.line, `the title of ${it.kind} ${it.number} is too long`);
    if ((it.original ?? '').length > LIMITS.maxOriginal) problem(it.line, `the English title of ${it.kind} ${it.number} is too long`);
    if ((it.reference ?? '').length > LIMITS.maxReference) problem(it.line, `the hymnal reference of ${it.kind} ${it.number} is too long`);
    if (it.verses.length === 0) problem(it.line, `${it.kind} ${it.number} has no verses`);
    if (it.verses.length > LIMITS.maxVerses) problem(it.line, `${it.kind} ${it.number} has too many verses`);
    // A one-line verse 1 that verse 2 completes into a full stanza: a "2" printed on the
    // stanza's second line, or two short verses? The printed book has to say.
    const lineCounts = it.verses.map((v) => v.split('\n').length);
    const stanza = lineCounts[2];
    if (lineCounts.length >= 3 && lineCounts[0] === 1 && stanza >= 2
        && lineCounts.slice(2).every((c) => c === stanza) && lineCounts[0] + lineCounts[1] === stanza) {
      note(it.line, `${it.kind} ${it.number}: verse 1 is one line and verse 2 completes its stanza (lines per verse ${lineCounts.join(', ')}); check the verse numbers against the printed book`);
    }
    if (it.kind === 'hymn') {
      const entry = topical.get(it.number);
      it.section = entry?.section ?? null;
      if (!entry) problem(it.line, `hymn ${it.number} is not in the topical index`);
      else if (titleKey(it.header) !== titleKey(entry.section.replace(/:/g, ' '))
               && similarity(it.header, entry.section) < 0.9) {
        note(it.line, `hymn ${it.number} is printed under the running header "${it.header}"; the topical index places it in "${entry.section}"`);
      }
    } else {
      it.section = chorusSection;
    }
    const titles = indexTitles(it.kind, it.number);
    if (titles.length > 0 && !titles.some((t) => titleKey(t) === titleKey(it.title))) {
      const id = `${it.kind}-${it.number}`;
      const closest = titles.reduce((a, b) => (similarity(it.title, a) >= similarity(it.title, b) ? a : b));
      const letters = editDistance(titleKey(it.title), titleKey(closest));
      const explanation = explained.get(id);
      if (explanation) usedExplanations.add(id);
      const listed = titles.map((t) => `"${t}"`).join(' and ');
      if (letters <= 2) {
        note(it.line, `${it.kind} ${it.number} "${it.title}" differs from its index entry ${listed} by ${letters} letter${letters === 1 ? '' : 's'}; the heading is kept as printed`);
      } else if (explanation) {
        note(it.line, `${it.kind} ${it.number} "${it.title}" differs from its index entry ${listed}: ${explanation.why}`);
      } else {
        problem(it.line, `${it.kind} ${it.number} "${it.title}" differs from its index entry ${listed}; explain it in corrections.json or fix the extraction`);
      }
    }
  }
  for (const e of explanations) {
    if (!usedExplanations.has(`${e.kind}-${e.number}`)) {
      problem(null, `the explanation for ${e.kind} ${e.number} no longer matches a title difference`);
    }
  }
  const byLine = (a, b) => (a.line ?? Infinity) - (b.line ?? Infinity);
  problems.sort(byLine);
  notes.sort(byLine);
  return {
    items: items.map((it) => ({
      id: `${it.kind}-${it.number}`,
      kind: it.kind,
      number: it.number,
      section: it.section,
      title: it.title,
      original: it.original,
      reference: it.reference,
      key: it.key,
      verses: it.verses,
      choruses: it.choruses,
    })),
    problems,
    notes,
    applied,
    stats: { pages: pages.length, hymns: counts.hymn, choruses: counts.chorus },
  };
}

/** The book file's object (format 1); throws a TypeError on bad metadata. */
export function buildBook(items, { edition, title, language }) {
  if (!EDITION_PATTERN.test(edition ?? '')) throw new TypeError('the edition must be lower-case letters, digits, dots or dashes');
  const bookTitle = cleanLine(title ?? '').text;
  if (bookTitle === '' || bookTitle.length > LIMITS.maxTitle) throw new TypeError('the book needs a title');
  if (!LANGUAGE_PATTERN.test(language ?? '')) throw new TypeError('the language must be a tag such as toi');
  return { format: 1, edition, title: bookTitle, language, items };
}

export function formatBook(book) {
  return `${JSON.stringify(book, null, 2)}\n`;
}

const where = (entry) => (entry.line === null ? '' : `line ${entry.line}: `);

/** The human-readable conversion report (also written by --report). */
export function formatReport(result, provenance) {
  const { items, problems, notes, applied, stats } = result;
  const out = [];
  out.push(`Source: ${provenance.pdf} (SHA-256 ${provenance.pdf_sha256}), extracted with: ${provenance.extraction_command}`);
  out.push(`Pages read: ${stats.pages}. Items: ${items.filter((i) => i.kind === 'hymn').length} hymns `
    + `(index ${stats.hymns}) and ${items.filter((i) => i.kind === 'chorus').length} choruses (index ${stats.choruses}).`);
  out.push(`Unplaced lines and other problems: ${problems.length}.`);
  for (const p of problems) out.push(`  PROBLEM ${where(p)}${p.message}`);
  out.push(`Corrections applied: ${applied.length}.`);
  for (const c of applied) out.push(`  line ${c.line}: "${c.extracted}" -> "${c.corrected}" (${c.why})`);
  out.push(`Notes (index and section cross-checks): ${notes.length}.`);
  for (const n of notes) out.push(`  ${where(n)}${n.message}`);
  return `${out.join('\n')}\n`;
}

export function sha256(text) {
  return createHash('sha256').update(text).digest('hex');
}

/** The checked-in manuscript text, its provenance and the reviewed corrections. */
export function loadInputs({ manuscript = MANUSCRIPT, provenance = PROVENANCE, corrections = CORRECTIONS } = {}) {
  const text = readFileSync(manuscript, 'utf8');
  return {
    text,
    provenance: JSON.parse(readFileSync(provenance, 'utf8')),
    corrections: JSON.parse(readFileSync(corrections, 'utf8')),
  };
}

function parseArgs(argv) {
  const options = { check: false, out: DEFAULT_OUT, report: null, manuscript: MANUSCRIPT,
    provenance: PROVENANCE, corrections: CORRECTIONS };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    const value = () => {
      if (i + 1 >= argv.length) throw new TypeError(`${arg} needs a value`);
      return resolve(argv[++i]);
    };
    switch (arg) {
      case '--check': options.check = true; break;
      case '--out': options.out = value(); break;
      case '--report': options.report = value(); break;
      case '--manuscript': options.manuscript = value(); break;
      case '--provenance': options.provenance = value(); break;
      case '--corrections': options.corrections = value(); break;
      default: throw new TypeError(`unknown option ${arg}`);
    }
  }
  return options;
}

/** The command line; returns the exit code. */
export function main(argv, { log = console.log, error = console.error } = {}) {
  let options;
  let inputs;
  try {
    options = parseArgs(argv);
    inputs = loadInputs(options);
  } catch (e) {
    error('usage: node tools/hymn-book/convert.mjs [--check] [--out <book.json>] [--report <report.txt>]'
      + ' [--manuscript <text>] [--provenance <json>] [--corrections <json>]');
    error(e.message);
    return 2;
  }
  const lf = inputs.text.replace(/\r\n?/g, '\n');
  if (sha256(lf) !== inputs.provenance.text_sha256_lf) {
    error(`the manuscript text does not match provenance.json (text_sha256_lf); re-extract it with: ${inputs.provenance.extraction_command}`);
    return 2;
  }
  const result = convertBook(lf, {
    corrections: inputs.corrections.corrections ?? [],
    explanations: inputs.corrections.index_differences ?? [],
  });
  const reportText = formatReport(result, inputs.provenance);
  if (options.report) {
    mkdirSync(dirname(options.report), { recursive: true });
    writeFileSync(options.report, reportText, 'utf8');
  }
  if (result.problems.length > 0) {
    error(reportText);
    error(`${result.problems.length} problem${result.problems.length === 1 ? '' : 's'}; no book was written.`);
    return 1;
  }
  let book;
  try {
    book = buildBook(result.items, inputs.provenance.book);
  } catch (e) {
    error(e.message);
    return 2;
  }
  const hymns = book.items.filter((i) => i.kind === 'hymn').length;
  const choruses = book.items.length - hymns;
  if (options.check) {
    log(`${hymns} hymns and ${choruses} choruses; no problems.`);
    return 0;
  }
  mkdirSync(dirname(options.out), { recursive: true });
  writeFileSync(options.out, formatBook(book), 'utf8');
  log(`Wrote ${hymns} hymns and ${choruses} choruses (edition ${book.edition}) to ${options.out}`);
  return 0;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  process.exitCode = main(process.argv.slice(2));
}
