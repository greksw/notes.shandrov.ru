import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

const notes = defineCollection({
  loader: glob({ pattern: '**/*.{md,mdx}', base: './src/content/notes' }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    category: z.string(),
    tags: z.array(z.string()).default([]),
    published: z.coerce.date(),
    updated: z.coerce.date(),
    status: z.enum(['current', 'legacy', 'lab']).default('current'),
    testedOn: z.array(z.string()).default([]),
    featured: z.boolean().default(false),
    lang: z.enum(['en', 'ru']).default('en'),
    translationKey: z.string().optional(),
  }),
});

export const collections = { notes };
