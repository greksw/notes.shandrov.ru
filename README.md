# notes.shandrov.ru

Technical notes by Tudor Shandrov.

`notes.shandrov.ru` is a static engineering knowledge base for practical infrastructure work: Linux, Proxmox, storage, networking, observability, security and operations.

## Stack

- Astro 7
- Markdown content collections
- static HTML
- Caddy
- GitHub Actions

## Local development

Requires Node.js 24.

```bash
npm install
npm run dev
```

Production build:

```bash
npm run build
```

## Content model

Notes live under `src/content/notes/` and include explicit metadata such as category, tags, publication/update dates, status and tested environments.

The intended article structure is operational rather than blog-oriented: context, prerequisites, procedure or decision process, validation, caveats and references.

## Deployment

Production is planned for `notes.shandrov.ru` on the same static-hosting pattern as `shandrov.ru`: versioned releases under `/srv/www/notes.shandrov.ru/releases/` and an atomic `current` symlink.

The deployment workflow is intentionally manual (`workflow_dispatch`) until DNS, Caddy and repository secrets are configured and validated.

## License

No license has been selected yet.
