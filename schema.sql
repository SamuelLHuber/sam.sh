CREATE TABLE IF NOT EXISTS subscribers (
  id INTEGER PRIMARY KEY,
  email TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL DEFAULT 'pending',
  confirm_token TEXT,
  unsubscribe_token TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  confirmed_at INTEGER,
  unsubscribed_at INTEGER
);

CREATE TABLE IF NOT EXISTS verified_identities (
  id INTEGER PRIMARY KEY,
  provider TEXT NOT NULL,
  provider_user_id TEXT NOT NULL,
  handle TEXT NOT NULL,
  display_name TEXT,
  is_mutual INTEGER NOT NULL DEFAULT 0,
  session_token TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  last_verified_at INTEGER NOT NULL,
  UNIQUE(provider, provider_user_id)
);

CREATE TABLE IF NOT EXISTS sent_updates (
  id INTEGER PRIMARY KEY,
  subject TEXT NOT NULL,
  body TEXT NOT NULL,
  sent_at INTEGER NOT NULL,
  recipient_count INTEGER NOT NULL
);
