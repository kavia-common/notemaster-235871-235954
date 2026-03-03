#!/bin/bash
set -euo pipefail

# Initializes schema + seed data for the notes/tags app.
# This script is idempotent: it can be run multiple times safely.

DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

echo "Initializing schema + seed data for ${DB_NAME} on port ${DB_PORT}..."

# Find PostgreSQL version and set paths (matches startup.sh convention)
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

PSQL_BASE=( "${PG_BIN}/psql" -h localhost -p "${DB_PORT}" -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 )

export PGPASSWORD="${DB_PASSWORD}"

# --- Schema / extensions ---
"${PSQL_BASE[@]}" -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
"${PSQL_BASE[@]}" -c "CREATE EXTENSION IF NOT EXISTS unaccent;"

# Notes table
"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS notes (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title         TEXT NOT NULL,
  content_md    TEXT NOT NULL DEFAULT '',
  content_text  TEXT NOT NULL DEFAULT '',
  is_archived   BOOLEAN NOT NULL DEFAULT FALSE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
"

# Tags table
"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS tags (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  name       TEXT NOT NULL,
  slug       TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT tags_slug_unique UNIQUE (slug),
  CONSTRAINT tags_name_nonempty CHECK (length(btrim(name)) > 0),
  CONSTRAINT tags_slug_nonempty CHECK (length(btrim(slug)) > 0)
);
"

# Join table
"${PSQL_BASE[@]}" -c "
CREATE TABLE IF NOT EXISTS note_tags (
  note_id UUID NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
  tag_id  UUID NOT NULL REFERENCES tags(id) ON DELETE CASCADE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (note_id, tag_id)
);
"

# --- updated_at trigger ---
"${PSQL_BASE[@]}" -c "
CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;
"

"${PSQL_BASE[@]}" -c "
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'notes_set_updated_at'
  ) THEN
    CREATE TRIGGER notes_set_updated_at
    BEFORE UPDATE ON notes
    FOR EACH ROW
    EXECUTE FUNCTION set_updated_at();
  END IF;
END $$;
"

# --- Indexes (search + tag filtering) ---
# Fast tag filtering via join
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_note_tags_tag_id ON note_tags(tag_id);"
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_note_tags_note_id ON note_tags(note_id);"

# Sorting/filtering by recency
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_notes_updated_at ON notes(updated_at DESC);"
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_notes_created_at ON notes(created_at DESC);"
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_notes_archived_updated_at ON notes(is_archived, updated_at DESC);"

# Trigram index for partial search on title/content_text
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_notes_title_trgm ON notes USING gin (title gin_trgm_ops);"
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_notes_content_text_trgm ON notes USING gin (content_text gin_trgm_ops);"

# Unaccented tsvector index for full-text search
"${PSQL_BASE[@]}" -c "
CREATE INDEX IF NOT EXISTS idx_notes_fts
ON notes
USING gin (
  to_tsvector('english', unaccent(coalesce(title,'') || ' ' || coalesce(content_text,'')))
);
"

# Helpful index for tags lookups
"${PSQL_BASE[@]}" -c "CREATE INDEX IF NOT EXISTS idx_tags_slug ON tags(slug);"

# --- Seed data (development) ---
# Seed tags (idempotent by slug)
"${PSQL_BASE[@]}" -c "
INSERT INTO tags (name, slug)
VALUES
  ('Work', 'work'),
  ('Personal', 'personal'),
  ('Ideas', 'ideas'),
  ('Todo', 'todo'),
  ('Reference', 'reference')
ON CONFLICT (slug) DO UPDATE
SET name = EXCLUDED.name;
"

# Seed notes (idempotent by title; good enough for dev seed)
"${PSQL_BASE[@]}" -c "
INSERT INTO notes (title, content_md, content_text)
VALUES
  (
    'Welcome to NoteMaster',
    '# Welcome\n\nThis is a seeded note. Try editing, tagging, and searching.\n\n- Markdown supported\n- Tags supported\n- Search supported\n',
    'Welcome This is a seeded note. Try editing, tagging, and searching. Markdown supported Tags supported Search supported'
  ),
  (
    'Quick Todo',
    '## Todo\n\n- [ ] Build something cool\n- [ ] Tag notes\n- [ ] Search notes\n',
    'Todo Build something cool Tag notes Search notes'
  ),
  (
    'Project Ideas',
    'Ideas:\n\n1. Retro-themed notes app\n2. Offline-first sync (future)\n3. Daily journal template\n',
    'Ideas 1. Retro-themed notes app 2. Offline-first sync (future) 3. Daily journal template'
  )
ON CONFLICT (title) DO NOTHING;
"

# Attach tags to notes (idempotent due to PK(note_id, tag_id))
# Welcome -> reference, ideas
"${PSQL_BASE[@]}" -c "
INSERT INTO note_tags (note_id, tag_id)
SELECT n.id, t.id
FROM notes n
JOIN tags t ON t.slug IN ('reference','ideas')
WHERE n.title = 'Welcome to NoteMaster'
ON CONFLICT DO NOTHING;
"

# Todo -> todo, personal
"${PSQL_BASE[@]}" -c "
INSERT INTO note_tags (note_id, tag_id)
SELECT n.id, t.id
FROM notes n
JOIN tags t ON t.slug IN ('todo','personal')
WHERE n.title = 'Quick Todo'
ON CONFLICT DO NOTHING;
"

# Ideas -> ideas, work
"${PSQL_BASE[@]}" -c "
INSERT INTO note_tags (note_id, tag_id)
SELECT n.id, t.id
FROM notes n
JOIN tags t ON t.slug IN ('ideas','work')
WHERE n.title = 'Project Ideas'
ON CONFLICT DO NOTHING;
"

echo "✓ Schema initialized and seed data applied."
