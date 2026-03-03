# NoteMaster Database Schema (PostgreSQL)

This container runs PostgreSQL (default configured by `startup.sh` as):

- DB: `myapp`
- User: `appuser`
- Port: `5000`

The startup script now also runs `init_schema_and_seed.sh` which is **idempotent** (safe to re-run).

## Tables

### `notes`
Stores note content.

Columns:
- `id` (uuid, PK)
- `title` (text, required)
- `content_md` (text, markdown source)
- `content_text` (text, plain-text for search)
- `is_archived` (bool)
- `created_at`, `updated_at` (timestamptz)

A trigger updates `updated_at` on every update.

### `tags`
Tag dictionary.

Columns:
- `id` (uuid, PK)
- `name` (text)
- `slug` (text, unique) — stable identifier used for lookups.

### `note_tags`
Many-to-many join table.

Columns:
- `note_id` -> `notes(id)` ON DELETE CASCADE
- `tag_id` -> `tags(id)` ON DELETE CASCADE
- Composite PK `(note_id, tag_id)`

## Indexes

Search:
- Trigram GIN indexes on `notes.title` and `notes.content_text` (`pg_trgm`)
- Full-text search GIN index on:
  `to_tsvector('english', unaccent(title || ' ' || content_text))` (`unaccent`)

Filtering/sorting:
- `notes(updated_at desc)`, `notes(created_at desc)`
- `(is_archived, updated_at desc)` for archived filter + recency
- `note_tags(tag_id)` and `note_tags(note_id)` for fast tag joins

## Seed data

For development, the init script inserts:
- Common tags: `work`, `personal`, `ideas`, `todo`, `reference`
- A few sample notes and tag mappings

Seed inserts are written to be idempotent via `ON CONFLICT` / composite PK.
