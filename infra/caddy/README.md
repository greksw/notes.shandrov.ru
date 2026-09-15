# Caddy candidate for notes.shandrov.ru

This directory tracks the intended production configuration for the static notes site.

Do not install it until:

1. `notes.shandrov.ru` DNS resolves to the intended host;
2. `/srv/www/notes.shandrov.ru/current` points to a valid built release;
3. Caddy can obtain a certificate for the hostname;
4. the candidate passes `caddy validate`.

The site follows the same versioned-release and atomic-symlink model as `shandrov.ru`.

The HSTS value is intentionally probationary. Do not add `includeSubDomains` or `preload` as part of initial rollout.
