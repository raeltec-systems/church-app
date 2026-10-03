// Builds the recording copies of the two prototypes in journeys/proto/.
// The originals in docs/design-handoff/design/ are never touched. Every patch is a plain string
// replacement that must match exactly once (or the script stops), so a prototype update that moves
// the markup fails loudly instead of silently recording the old screens.
//
// What the patches add (see ../JOURNEYS-NEW-SCREENS.md):
//   App   - "Confirm your part" sheet on My cell + the answer chip on the part row   (new screen 3)
//         - s.me: whose phone this is, so the same prototype can stand in for Ruth or Abel
//   Admin - per-part status chip on Cell meetings programme rows + "x of y confirmed" (new screen 4)
//         - a declined visit card state with the member's reason                       (new screen 5)
//   Both  - window.__dc (the component) so the recorder can stage cross-device state
//         - entrance motion for sheets, modals and toasts (the originals switch instantly)
//         - toasts stay up 4 s instead of ~2 s, so they survive the slowed-down capture
//
//   node journeys/patch.mjs
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SRC = path.resolve(HERE, '../../design-handoff/design');
const OUT = path.join(HERE, 'proto');
fs.mkdirSync(OUT, { recursive: true });
for (const f of ['support.js', 'assets']) {
  const dst = path.join(OUT, f);
  if (!fs.existsSync(dst)) fs.symlinkSync(path.join(SRC, f), dst);
}

function patch(file, out, edits) {
  let s = fs.readFileSync(path.join(SRC, file), 'utf8');
  for (const [label, from, to, all] of edits) {
    const n = s.split(from).length - 1;
    if (all ? n < 1 : n !== 1) throw new Error(`${file}: "${label}" matched ${n} times`);
    s = all ? s.split(from).join(to) : s.replace(from, () => to);
  }
  fs.writeFileSync(path.join(OUT, out), s);
  console.log(`${out}: ${edits.length} patches`);
}

const MOTION = `@keyframes jUp{from{transform:translateY(105%)}to{transform:none}}
@keyframes jFade{from{opacity:0}to{opacity:1}}
@keyframes jPop{from{opacity:0;transform:translateY(18px) scale(.96)}to{opacity:1;transform:none}}
@keyframes jPopX{from{opacity:0;transform:translate(-50%,18px) scale(.96)}to{opacity:1;transform:translateX(-50%)}}
@keyframes jModal{from{opacity:0;transform:translateY(24px) scale(.97)}to{opacity:1;transform:none}}
@keyframes jChip{0%{transform:scale(.6);opacity:0}60%{transform:scale(1.12);opacity:1}100%{transform:none}}
.jsheet{animation:jUp .36s cubic-bezier(.2,.9,.25,1)}
.jdim{animation:jFade .28s ease-out}
.jtoast{animation:jPop .32s cubic-bezier(.2,.9,.3,1.25)}
.jtoastx{animation:jPopX .32s cubic-bezier(.2,.9,.3,1.25)}
.jmodal{animation:jModal .34s cubic-bezier(.2,.9,.25,1)}
.jchip{animation:jChip .42s cubic-bezier(.2,.9,.3,1.2)}`;
const STYLE_ANCHOR = '::-webkit-scrollbar{width:0;height:0}</style>';

patch('BIC Kafue App.dc.html', 'App.html', [
  ['motion css', STYLE_ANCHOR, `::-webkit-scrollbar{width:0;height:0}\n${MOTION}</style>`],
  ['hook', 'const s = this.state, D = this.D(), chip = c => this.chip(c);',
    'const s = this.state, D = this.D(), chip = c => this.chip(c); window.__dc = this;'],
  ['toast time', "this._t = setTimeout(() => this.setState({ toast: '' }), 2200);",
    "this._t = setTimeout(() => this.setState({ toast: '' }), 4000);"],
  ['toast class', '<div style="position:absolute;left:20px;right:20px;bottom:104px;z-index:40;',
    '<div class="jtoast" style="position:absolute;left:20px;right:20px;bottom:104px;z-index:40;', true],
  ['sheet dim', '<div onClick="{{ closeSheet }}" style="position:absolute;inset:0;background:rgba(5,10,30,.5)"></div>',
    '<div class="jdim" onClick="{{ closeSheet }}" style="position:absolute;inset:0;background:rgba(5,10,30,.5)"></div>'],
  ['sheet panel', '<div style="position:relative;background:var(--sf);border-radius:26px 26px 0 0;',
    '<div class="jsheet" style="position:relative;background:var(--sf);border-radius:26px 26px 0 0;'],
  ['visit when', "when: 'Sat 10 Oct, 10:00', where: 'Your home'", "when: s.visitWhen || 'Sat 10 Oct, 10:00', where: 'Your home'"],
  ['sign-up cells (prototype bug: cellOpts was built but never passed to the template)', 'su, su1: su.step === 1,', 'su, cellOpts, su1: su.step === 1,'],
  ['me', "const ME = 'Mwila Chanda';", "const ME = s.me || 'Mwila Chanda';"],
  ['part fields', "programme: m.programme.map(([time, part, who]) => ({ time, part, who: who === ME ? 'You' : who, me: who === ME }))",
    "programme: m.programme.map(([time, part, who]) => ({ time, part, who: who === ME ? 'You' : who, me: who === ME, " +
    "meLabel: ({ yes: 'Confirmed', tent: 'Tentative', no: 'Can\\u2019t make it' })[s.partAns] || 'Confirm', " +
    "meChip: { ...chip(({ yes: 'green', tent: 'amber', no: 'red' })[s.partAns] || 'blue'), border: 0, cursor: 'pointer', font: 'inherit', fontSize: 13, fontWeight: 600 }, " +
    "open: () => this.setState({ sheet: 'part', note: '' }) }))"],
  ['part row', '<sc-if value="{{ p.me }}" hint-placeholder-val="{{ false }}"><span style="{{ chips.blue }}">You</span></sc-if>',
    '<sc-if value="{{ p.me }}" hint-placeholder-val="{{ false }}"><button class="jchip" key="{{ p.meLabel }}" onClick="{{ p.open }}" style="{{ p.meChip }}">{{ p.meLabel }}</button></sc-if>'],
  ['part sheet', '<sc-if value="{{ sh.decline }}" hint-placeholder-val="{{ false }}">',
    `<sc-if value="{{ sh.part }}" hint-placeholder-val="{{ false }}">
<div><div style="font-family:Outfit,sans-serif;font-weight:700;font-size:22px">Your part on Thursday</div><div style="color:var(--mut)">{{ myPart.part }} · {{ myPart.time }} · Mwembeshi Road cell</div></div>
<div style="font-size:15px;color:var(--mut);text-wrap:pretty">Grace Banda asked you to lead this part. Let her know if you can.</div>
<button onClick="{{ partYes }}" style="height:52px;border-radius:26px;border:0;background:var(--pri);color:#fff;font-weight:700;cursor:pointer">Yes, I'll lead it</button>
<button onClick="{{ partTent }}" style="height:52px;border-radius:26px;border:1.5px solid var(--line);background:var(--sf);font-weight:700;cursor:pointer">Tentative</button>
<textarea value="{{ note }}" onChange="{{ onNote }}" placeholder="Add a note for Grace (optional)" rows="2" style="border-radius:14px;border:1.5px solid var(--line);background:var(--bg);outline:0;padding:12px 14px;font-size:16px;resize:none"></textarea>
<button onClick="{{ partNo }}" style="height:44px;border:0;background:transparent;color:var(--redFg);font-weight:700;cursor:pointer">Can't make it</button>
</sc-if>
<sc-if value="{{ sh.decline }}" hint-placeholder-val="{{ false }}">`],
  ['sheet flag', "requestVisit: s.sheet === 'requestVisit' }", "requestVisit: s.sheet === 'requestVisit', part: s.sheet === 'part' }"],
  ['part handlers', 'sheetOpen: !!s.sheet,',
    "partYes: () => { this.setState({ partAns: 'yes', sheet: null }); this.toast('Thank you. Grace Banda can see you\\u2019re leading it.'); }, " +
    "partTent: () => { this.setState({ partAns: 'tent', sheet: null }); this.toast('Marked tentative. Grace Banda can see it.'); }, " +
    "partNo: () => { this.setState({ partAns: 'no', sheet: null }); this.toast('Grace Banda has been told and will ask someone else.'); }, " +
    'sheetOpen: !!s.sheet,'],
]);

patch('BIC Kafue Admin.dc.html', 'Admin.html', [
  ['motion css', 'input,textarea,button,select{font:inherit;color:inherit}</style>', `input,textarea,button,select{font:inherit;color:inherit}\n${MOTION}</style>`],
  ['hook', 'const s = this.state, D = this.D(), chip = c => this.chip(c);',
    'const s = this.state, D = this.D(), chip = c => this.chip(c); window.__dc = this;'],
  ['toast time', "this._t = setTimeout(() => this.setState({ toast: '' }), 2400);",
    "this._t = setTimeout(() => this.setState({ toast: '' }), 4000);"],
  ['toast class', '<div style="position:fixed;left:50%;bottom:28px;transform:translateX(-50%);z-index:50;',
    '<div class="jtoastx" style="position:fixed;left:50%;bottom:28px;transform:translateX(-50%);z-index:50;'],
  ['modal dim', '<div onClick="{{ closeModal }}" style="position:absolute;inset:0;background:rgba(5,10,30,.45)"></div>',
    '<div class="jdim" onClick="{{ closeModal }}" style="position:absolute;inset:0;background:rgba(5,10,30,.45)"></div>'],
  ['modal box', '<div style="position:relative;width:460px;max-width:100%;background:#fff;border-radius:18px;',
    '<div class="jmodal" style="position:relative;width:460px;max-width:100%;background:#fff;border-radius:18px;'],
  ['card motion', '<div draggable="true" onDragStart="{{ it.dragStart }}"', '<div class="jmodal" draggable="true" onDragStart="{{ it.dragStart }}"'],
  ['declined chip', 'chip: chip(reasonC(v.reason)),', "chip: chip(reasonC(v.reason)), declChip: chip('red'),"],
  ['declined card', '<div style="font-size:13px;color:#586079">{{ it.detail }}</div>\n<sc-if value="{{ it.actionLabel }}"',
    '<div style="font-size:13px;color:#586079">{{ it.detail }}</div>\n' +
    '<sc-if value="{{ it.declined }}" hint-placeholder-val="{{ false }}"><div class="jchip" style="display:flex;flex-direction:column;gap:3px;padding:8px 10px;border-radius:9px;background:#FCE5E2"><span style="font-size:12.5px;font-weight:700;color:#A3241A">Declined by member</span><span style="font-size:13px;color:#5A1712;line-height:1.35">“{{ it.declined }}”</span></div></sc-if>\n' +
    '<sc-if value="{{ it.actionLabel }}"'],
  ['prog grid', 'grid-template-columns:90px minmax(0,1fr) minmax(0,1fr) 36px;gap:10px;padding:10px 20px',
    'grid-template-columns:84px minmax(0,1fr) minmax(0,1fr) 112px 36px;gap:10px;padding:10px 20px'],
  ['prog status cell', '</select><button onClick="{{ pr.remove }}"',
    '</select><div style="display:flex"><sc-if value="{{ pr.stLabel }}" hint-placeholder-val="{{ false }}"><span class="jchip" key="{{ pr.stLabel }}" style="{{ pr.stChip }}">{{ pr.stLabel }}</span></sc-if></div><button onClick="{{ pr.remove }}"'],
  ['prog status vals', 'const prog = s.prog.map((r, i) => ({ time: r[0], part: r[1], who: r[2],',
    "const PST = s.partSt || {}; const prog = s.prog.map((r, i) => ({ time: r[0], part: r[1], who: r[2], " +
    "stLabel: s.meetPublished ? (PST[r[1] + '|' + r[2]] || 'Waiting') : '', " +
    "stChip: chip(({ Confirmed: 'green', Tentative: 'amber', 'Can\\u2019t make it': 'red' })[PST[r[1] + '|' + r[2]]] || 'gray'),"],
  ['prog hint', '<span style="font-size:13px;color:#586079">Each person sees their part on their phone</span>',
    '<span style="{{ progHintStyle }}">{{ progHint }}</span>'],
  ['prog hint vals', "meetPublishLabel: s.meetPublished ? 'Update members' : 'Publish to members',",
    "meetPublishLabel: s.meetPublished ? 'Update members' : 'Publish to members', " +
    "progHint: s.meetPublished ? `${s.prog.filter(r => (s.partSt || {})[r[1] + '|' + r[2]] === 'Confirmed').length} of ${s.prog.length} parts confirmed` : 'Each person sees their part on their phone', " +
    "progHintStyle: s.meetPublished ? { fontSize: 13, fontWeight: 700, color: '#0D6438' } : { fontSize: 13, color: '#586079' },"],
  ['republish toast', "publishMeeting: () => { this.setState({ meetPublished: true }); this.toast('Published · each person is told about their part'); },",
    "publishMeeting: () => { const again = s.meetPublished; this.setState({ meetPublished: true }); this.toast(again ? 'Updated · changed parts are sent to their phones' : 'Published · each person is told about their part'); },"],
]);
