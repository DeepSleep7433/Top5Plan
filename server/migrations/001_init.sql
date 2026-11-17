-- T5 single-user server schema. MySQL 8.4 LTS.
-- All timestamps are UTC. Business dates are stored in record JSON as YYYY-MM-DD.
CREATE TABLE IF NOT EXISTS schema_migrations (
  version INT PRIMARY KEY,
  applied_at DATETIME(6) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci;

CREATE TABLE IF NOT EXISTS accounts (
  id BIGINT PRIMARY KEY,
  timezone VARCHAR(64) NOT NULL DEFAULT 'Asia/Shanghai',
  sync_generation CHAR(36) NOT NULL,
  created_at DATETIME(6) NOT NULL,
  updated_at DATETIME(6) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS pairing_codes (
  id CHAR(36) PRIMARY KEY,
  code_hash CHAR(64) NOT NULL UNIQUE,
  expires_at DATETIME(6) NOT NULL,
  used_at DATETIME(6) NULL,
  created_at DATETIME(6) NOT NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS devices (
  id CHAR(36) PRIMARY KEY,
  name VARCHAR(120) NOT NULL,
  platform VARCHAR(24) NOT NULL,
  token_hash CHAR(64) NOT NULL UNIQUE,
  created_at DATETIME(6) NOT NULL,
  last_seen_at DATETIME(6) NULL,
  revoked_at DATETIME(6) NULL,
  INDEX idx_devices_revoked (revoked_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sync_sequence (
  account_id BIGINT PRIMARY KEY,
  next_seq BIGINT NOT NULL,
  CONSTRAINT fk_seq_account FOREIGN KEY (account_id) REFERENCES accounts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sync_entities (
  account_id BIGINT NOT NULL,
  entity_type VARCHAR(40) NOT NULL,
  entity_id CHAR(36) NOT NULL,
  version BIGINT NOT NULL,
  deleted TINYINT(1) NOT NULL DEFAULT 0,
  data JSON NULL,
  server_updated_at DATETIME(6) NOT NULL,
  PRIMARY KEY (account_id, entity_type, entity_id),
  INDEX idx_entities_type (account_id, entity_type, entity_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sync_changes (
  change_seq BIGINT PRIMARY KEY,
  account_id BIGINT NOT NULL,
  entity_type VARCHAR(40) NOT NULL,
  entity_id CHAR(36) NOT NULL,
  version BIGINT NOT NULL,
  deleted TINYINT(1) NOT NULL DEFAULT 0,
  data JSON NULL,
  committed_at DATETIME(6) NOT NULL,
  INDEX idx_changes_account_seq (account_id, change_seq)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS sync_operations (
  operation_id CHAR(36) PRIMARY KEY,
  device_id CHAR(36) NOT NULL,
  entity_type VARCHAR(40) NOT NULL,
  entity_id CHAR(36) NOT NULL,
  request_hash CHAR(64) NOT NULL,
  accepted TINYINT(1) NOT NULL,
  server_version BIGINT NOT NULL,
  conflict TINYINT(1) NOT NULL DEFAULT 0,
  result_json JSON NOT NULL,
  created_at DATETIME(6) NOT NULL,
  INDEX idx_ops_device_created (device_id, created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS account_settings (
  account_id BIGINT PRIMARY KEY,
  settings_json JSON NOT NULL,
  updated_at DATETIME(6) NOT NULL,
  CONSTRAINT fk_settings_account FOREIGN KEY (account_id) REFERENCES accounts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS focus_sessions (
  id CHAR(36) PRIMARY KEY,
  account_id BIGINT NOT NULL,
  task_id CHAR(36) NULL,
  label VARCHAR(200) NOT NULL DEFAULT '',
  target_seconds INT NOT NULL,
  state VARCHAR(16) NOT NULL,
  accumulated_ms BIGINT NOT NULL DEFAULT 0,
  running_since DATETIME(6) NULL,
  control_device_id CHAR(36) NOT NULL,
  version BIGINT NOT NULL,
  created_at DATETIME(6) NOT NULL,
  updated_at DATETIME(6) NOT NULL,
  ended_at DATETIME(6) NULL,
  active_slot TINYINT GENERATED ALWAYS AS (CASE WHEN state IN ('running','paused') THEN 1 ELSE NULL END) STORED,
  UNIQUE KEY uq_focus_one_active (account_id, active_slot),
  INDEX idx_focus_active (account_id, state, updated_at),
  CONSTRAINT fk_focus_account FOREIGN KEY (account_id) REFERENCES accounts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS ai_configs (
  id CHAR(36) PRIMARY KEY,
  account_id BIGINT NOT NULL,
  name VARCHAR(100) NOT NULL,
  base_url VARCHAR(500) NOT NULL,
  model VARCHAR(200) NOT NULL,
  api_key_ciphertext LONGBLOB NOT NULL,
  timeout_seconds INT NOT NULL DEFAULT 120,
  max_output_tokens INT NOT NULL DEFAULT 2000,
  enabled TINYINT(1) NOT NULL DEFAULT 0,
  created_at DATETIME(6) NOT NULL,
  updated_at DATETIME(6) NOT NULL,
  INDEX idx_ai_config_account (account_id),
  CONSTRAINT fk_ai_config_account FOREIGN KEY (account_id) REFERENCES accounts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS ai_jobs (
  id CHAR(36) PRIMARY KEY,
  account_id BIGINT NOT NULL,
  kind VARCHAR(24) NOT NULL,
  status VARCHAR(20) NOT NULL,
  config_id CHAR(36) NOT NULL,
  scheduled_period VARCHAR(64) NULL,
  sources_json JSON NOT NULL,
  input_scope_json JSON NOT NULL,
  prompt_text MEDIUMTEXT NULL,
  result_text MEDIUMTEXT NULL,
  model VARCHAR(200) NOT NULL DEFAULT '',
  input_tokens INT NULL,
  output_tokens INT NULL,
  error_code VARCHAR(64) NULL,
  error_message TEXT NULL,
  created_at DATETIME(6) NOT NULL,
  started_at DATETIME(6) NULL,
  finished_at DATETIME(6) NULL,
  unique_period VARCHAR(200) GENERATED ALWAYS AS (
    CASE WHEN scheduled_period IS NULL THEN NULL ELSE CONCAT(kind, ':', scheduled_period) END
  ) STORED,
  UNIQUE KEY uq_ai_job_period (account_id, unique_period),
  INDEX idx_ai_jobs_pending (account_id, status, created_at),
  CONSTRAINT fk_ai_job_account FOREIGN KEY (account_id) REFERENCES accounts(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS report_versions (
  id CHAR(36) PRIMARY KEY,
  account_id BIGINT NOT NULL,
  job_id CHAR(36) NOT NULL,
  kind VARCHAR(24) NOT NULL,
  period_start DATETIME(6) NULL,
  period_end DATETIME(6) NULL,
  data_cutoff DATETIME(6) NOT NULL,
  result_text MEDIUMTEXT NOT NULL,
  sources_json JSON NOT NULL,
  created_at DATETIME(6) NOT NULL,
  INDEX idx_report_versions (account_id, kind, created_at),
  CONSTRAINT fk_report_job FOREIGN KEY (job_id) REFERENCES ai_jobs(id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

INSERT INTO accounts (id, timezone, sync_generation, created_at, updated_at)
VALUES (1, 'Asia/Shanghai', UUID(), UTC_TIMESTAMP(6), UTC_TIMESTAMP(6))
ON DUPLICATE KEY UPDATE id = id;

INSERT INTO sync_sequence (account_id, next_seq) VALUES (1, 1)
ON DUPLICATE KEY UPDATE account_id = account_id;

INSERT INTO account_settings (account_id, settings_json, updated_at)
VALUES (1, JSON_OBJECT(
  'ai_daily_limit', 20,
  'daily_report_enabled', FALSE,
  'daily_report_time', '21:00',
  'weekly_report_enabled', FALSE,
  'weekly_report_time', '21:30',
  'excluded_lists', JSON_ARRAY(),
  'excluded_entity_ids', JSON_ARRAY()
), UTC_TIMESTAMP(6))
ON DUPLICATE KEY UPDATE account_id = account_id;
