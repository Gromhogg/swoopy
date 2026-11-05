-- Each key's serial number and the Mac that used it (its Mac id, a hash that can't be traced back to the Mac).
CREATE TABLE IF NOT EXISTS used (
  serial TEXT PRIMARY KEY,
  machine TEXT NOT NULL,
  at TEXT NOT NULL
);
