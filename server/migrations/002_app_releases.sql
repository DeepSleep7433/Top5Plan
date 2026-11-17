CREATE TABLE IF NOT EXISTS app_releases (
  id CHAR(36) PRIMARY KEY,
  platform VARCHAR(16) NOT NULL,
  version VARCHAR(40) NOT NULL,
  download_url VARCHAR(1000) NOT NULL,
  sha256 CHAR(64) NOT NULL DEFAULT '',
  release_notes TEXT NULL,
  mandatory TINYINT(1) NOT NULL DEFAULT 0,
  active TINYINT(1) NOT NULL DEFAULT 1,
  channel VARCHAR(24) NOT NULL DEFAULT 'stable',
  published_at DATETIME(6) NOT NULL,
  created_at DATETIME(6) NOT NULL,
  updated_at DATETIME(6) NOT NULL,
  UNIQUE KEY uq_app_release (platform, version, channel),
  INDEX idx_app_release_latest (platform, channel, active, published_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
