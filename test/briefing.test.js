import { test } from 'node:test';
import assert from 'node:assert/strict';
import { briefingText, buildWeek, weekRange } from '../lib/briefing.js';
import { startOfDay } from '../lib/time.js';

const TZ = 'America/New_York';

test('week runs from today through Sunday', () => {
  // Wednesday 2026-09-30, 07:30 in New York
  const r = weekRange(new Date('2026-09-30T11:30:00Z'), TZ);
  assert.equal(r.today, '2026-09-30');
  assert.deepEqual(r.dates, ['2026-09-30', '2026-10-01', '2026-10-02', '2026-10-03', '2026-10-04']);
  assert.equal(r.timeMin.toISOString(), '2026-09-30T04:00:00.000Z');
  assert.equal(r.timeMax.toISOString(), '2026-10-05T04:00:00.000Z');
});

test('on Sunday the range also covers the next week', () => {
  const r = weekRange(new Date('2026-10-04T11:30:00Z'), TZ);
  assert.equal(r.dates.length, 8);
  assert.equal(r.dates.at(-1), '2026-10-11');
});

test('local midnight is correct across a DST change', () => {
  // US DST ends 2026-11-01: midnight is still EDT (UTC-4), the next day is EST (UTC-5)
  assert.equal(startOfDay('2026-11-01', TZ).toISOString(), '2026-11-01T04:00:00.000Z');
  assert.equal(startOfDay('2026-11-02', TZ).toISOString(), '2026-11-02T05:00:00.000Z');
});

test('groups, sorts, and filters events', () => {
  const range = weekRange(new Date('2026-09-30T11:30:00Z'), TZ);
  const events = [
    { summary: 'Dentist', location: 'Main St Clinic, 5 Main St', start: { dateTime: '2026-09-30T14:00:00-04:00' } },
    { summary: 'Standup', start: { dateTime: '2026-09-30T09:00:00-04:00' } },
    { summary: 'Trip', start: { date: '2026-10-02' }, end: { date: '2026-10-04' } },
    { summary: 'Cancelled', status: 'cancelled', start: { dateTime: '2026-09-30T10:00:00-04:00' } },
    { summary: 'Declined', attendees: [{ self: true, responseStatus: 'declined' }], start: { dateTime: '2026-10-01T10:00:00-04:00' } },
    { summary: 'Late night', start: { dateTime: '2026-10-01T02:30:00Z' } }, // 10:30 PM Sep 30 local
  ];
  const days = buildWeek(events, range, TZ);

  assert.deepEqual(days[0].events.map((e) => e.title), ['Standup', 'Dentist', 'Late night']);
  assert.equal(days[0].events[1].location, 'Main St Clinic');
  assert.equal(days[0].events[0].time, '9:00 AM');
  assert.equal(days[1].events.length, 0);
  assert.deepEqual(days[2].events.map((e) => e.title), ['Trip']);
  assert.deepEqual(days[3].events.map((e) => e.title), ['Trip']);
  assert.equal(days[4].events.length, 0);
});

test('briefing text reads naturally', () => {
  const range = weekRange(new Date('2026-09-30T11:30:00Z'), TZ);
  const days = buildWeek(
    [
      { summary: 'Standup', start: { dateTime: '2026-09-30T09:00:00-04:00' } },
      { summary: 'Gym', start: { dateTime: '2026-10-02T18:00:00-04:00' } },
    ],
    range,
    TZ,
  );
  assert.equal(
    briefingText(days, range.today),
    'Good morning. Today is Wednesday, September 30. You have one event today. ' +
      'At 9:00 AM: Standup. Coming up this week. Friday: 6:00 PM, Gym. Have a great day.',
  );
});

test('empty week', () => {
  const range = weekRange(new Date('2026-09-30T11:30:00Z'), TZ);
  const text = briefingText(buildWeek([], range, TZ), range.today);
  assert.match(text, /nothing on your calendar today/);
  assert.match(text, /Nothing else is scheduled/);
});
