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

CREATE TABLE IF NOT EXISTS sent_updates (
  id INTEGER PRIMARY KEY,
  subject TEXT NOT NULL,
  body TEXT NOT NULL,
  sent_at INTEGER NOT NULL,
  recipient_count INTEGER NOT NULL
);
