import { getCollection } from 'astro:content';

const escapeXml = (value: string) => value.replace(/[<>&'\"]/g, (char) => ({ '<':'&lt;', '>':'&gt;', '&':'&amp;', "'":'&apos;', '"':'&quot;' }[char] ?? char));

export async function GET() {
  const notes = (await getCollection('notes')).sort((a,b) => b.data.updated.valueOf() - a.data.updated.valueOf());
  const items = notes.map((note) => `<item><title>${escapeXml(note.data.title)}</title><link>https://notes.shandrov.ru/notes/${note.id}/</link><guid>https://notes.shandrov.ru/notes/${note.id}/</guid><pubDate>${note.data.updated.toUTCString()}</pubDate><description>${escapeXml(note.data.description)}</description></item>`).join('');
  const body = `<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>Tudor Shandrov · Technical Notes</title><link>https://notes.shandrov.ru/</link><description>Practical infrastructure engineering notes.</description>${items}</channel></rss>`;
  return new Response(body, { headers: { 'Content-Type': 'application/rss+xml; charset=utf-8' } });
}
