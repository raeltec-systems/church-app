import assert from 'node:assert/strict';
import { test } from 'node:test';

import { cellsCleanupSql } from './cells-cleanup.mjs';

const run = {
  namePrefix: 'SYNTHETIC 5.x E2E',
  shikoswe: 'SYNTHETIC Shikoswe Cell (5.x E2E)',
  estates: 'SYNTHETIC Estates C5/C7 Cell (5.x E2E)',
  department: 'SYNTHETIC Ushers (5.x E2E)',
  userIds: ['82828282-8282-4282-8282-828282828282'],
  phones: ['+447700900050'],
};

test('it names the run and every Cells table through story 5.9', () => {
  const sql = cellsCleanupSql(run);
  assert.match(sql, /like 'SYNTHETIC 5\.x E2E%'/);
  assert.match(sql, /'447700900050'/);
  for (const t of ['cells_actual_leaders', 'cells_meeting_record_history', 'cells_meeting_records',
    'identity_handover_obligations', 'cells_absence_notices', 'cells_programme_parts', 'cells_meetings']) {
    assert.ok(sql.includes(`app.${t}`), t);
  }
  assert.match(sql.trim(), /select count\(\*\) from auth\.users u where u\.id in \('82828282[^)]*\) or {2}u\.phone in \('447700900050'\);$/);
});

test('it refuses anything but SYNTHETIC names, uuids and phone numbers', () => {
  assert.throws(() => cellsCleanupSql({ ...run, shikoswe: 'Shikoswe Cell' }));
  assert.throws(() => cellsCleanupSql({ ...run, department: "SYNTHETIC x'; drop table y; --" }));
  assert.throws(() => cellsCleanupSql({ ...run, userIds: ['not-a-uuid'] }));
  assert.throws(() => cellsCleanupSql({ ...run, phones: ['447700900050'] }));
});
