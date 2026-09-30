import { addDays, clockTime, dayName, localDate, longDate, startOfDay, weekday } from './time.js';

// Today through Sunday. On Sunday, also cover the coming week.
export function weekRange(now, timeZone) {
  const today = localDate(now, timeZone);
  const dow = weekday(today);
  const remaining = dow === 0 ? 7 : 7 - dow;
  const dates = Array.from({ length: remaining + 1 }, (_, i) => addDays(today, i));
  return {
    today,
    dates,
    timeMin: startOfDay(today, timeZone),
    timeMax: startOfDay(addDays(dates.at(-1), 1), timeZone),
  };
}

function isDeclined(event) {
  return (event.attendees || []).some((a) => a.self && a.responseStatus === 'declined');
}

function shortLocation(location) {
  if (!location) return null;
  return location.split(',')[0].trim() || null;
}

// Group raw Google Calendar events into the days of the range.
export function buildWeek(events, range, timeZone) {
  const days = new Map(range.dates.map((d) => [d, []]));
  const first = range.dates[0];

  for (const ev of events) {
    if (ev.status === 'cancelled' || isDeclined(ev)) continue;
    const base = {
      title: (ev.summary || 'Untitled event').trim(),
      location: shortLocation(ev.location),
    };

    if (ev.start?.date) {
      // All-day: end.date is exclusive; show on every covered day.
      const end = ev.end?.date || addDays(ev.start.date, 1);
      for (let d = ev.start.date; d < end; d = addDays(d, 1)) {
        days.get(d)?.push({ ...base, allDay: true, time: 'All day', sort: -1 });
      }
      continue;
    }

    if (!ev.start?.dateTime) continue;
    const start = new Date(ev.start.dateTime);
    let day = localDate(start, timeZone);
    if (day < first) day = first; // started before today, still running
    days.get(day)?.push({
      ...base,
      allDay: false,
      time: clockTime(start, timeZone),
      sort: start.getTime(),
    });
  }

  return range.dates.map((date) => ({
    date,
    label: date === range.today ? 'Today' : dayName(date),
    isToday: date === range.today,
    events: days
      .get(date)
      .sort((a, b) => a.sort - b.sort)
      .map(({ sort, ...e }) => e),
  }));
}

function spokenEvent(e) {
  const where = e.location ? `, at ${e.location}` : '';
  return e.allDay ? `All day: ${e.title}${where}.` : `At ${e.time}: ${e.title}${where}.`;
}

function countPhrase(n) {
  return n === 1 ? 'one event' : `${n} events`;
}

// Plain-language briefing meant to be read aloud.
export function briefingText(days, today) {
  const lines = [`Good morning. Today is ${longDate(today)}.`];
  const [todayDay, ...rest] = days;

  if (todayDay.events.length === 0) {
    lines.push('You have nothing on your calendar today.');
  } else {
    lines.push(`You have ${countPhrase(todayDay.events.length)} today.`);
    lines.push(...todayDay.events.map(spokenEvent));
  }

  const busy = rest.filter((d) => d.events.length > 0);
  if (busy.length === 0) {
    if (rest.length > 0) lines.push('Nothing else is scheduled for the rest of the week.');
  } else {
    lines.push('Coming up this week.');
    for (const d of busy) {
      const items = d.events.map((e) => (e.allDay ? e.title : `${e.time}, ${e.title}`));
      lines.push(`${dayName(d.date)}: ${items.join('; ')}.`);
    }
  }

  lines.push('Have a great day.');
  return lines.join(' ');
}
