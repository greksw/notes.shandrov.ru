import { getCollection } from 'astro:content';

const escapeXml = (value: string) => value.replace(/[<>&'\"]/g, (char) => ({ '<':'&lt;', '>':'&gt;', '&':'&amp;', "'":'&apos;', '"':'&quot;' }[char] ?? char));

export async function GET() {
  const notes = (await getCollection('notes', ({ data }) => data.lang === 'ru')).sort((a,b) => b.data.updated.valueOf() - a.data.updated.valueOf());
  const items = notes.map((note) => {
    const id = note.id.replace(/^ru\//, '');
    const url = `https://notes.shandrov.ru/ru/notes/${id}/`;
    return `<item><title>${escapeXml(note.data.title)}</title><link>${url}</link><guid>${url}</guid><pubDate>${note.data.updated.toUTCString()}</pubDate><description>${escapeXml(note.data.description)}</description></item>`;
  }).join('');
  const body = `<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>Tudor Shandrov · Технические заметки</title><link>https://notes.shandrov.ru/ru/</link><description>Практические заметки по инфраструктурной инженерии.</description>${items}</channel></rss>`;
  return new Response(body, { headers: { 'Content-Type': 'application/rss+xml; charset=utf-8' } });
}
