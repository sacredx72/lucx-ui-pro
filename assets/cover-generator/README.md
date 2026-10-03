# Local cover generator 1.0.0

32 independent layout families, 32 ordinary technical and creative topics.
English static HTML, inline styles and scripts, no external requests or dependencies.
Requires Python 3.11 or later. Generated sites contain 1–12 pages.

Installed sources: `/usr/local/lib/lucx-ui-pro/cover-generator/`.
Website: `/var/www/html/index.html` and `/var/www/html/_lucx-cover/`.
Private generation record: `/var/lib/lucx-ui-preinstall/cover-generator.json`.

Full installation generates a new site. Telegram maintenance keeps the shared
site; full uninstall removes generator-owned files before restoring the original
website. Backup includes sources, website and generation record; restore keeps
the exact site and checks its recorded file hashes. The seed is not a secret.

CLI: `python3 generator.py generate|ensure|check|cleanup|list`.
Use `--root PATH --state PATH` for an isolated preview.
Optional `--family ID --seed TEXT` makes generation reproducible.
`ensure` preserves a valid site. `check` returns nonzero for missing or changed
files. `cleanup` preserves unrelated files and an independently replaced index.

Templates are original generated reference examples, not real businesses.
The versioned archive must be rebuilt and the installer SHA-256 updated after
source edits; editing loose GitHub sources alone does not update the installer.
