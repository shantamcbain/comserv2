CREATE TABLE IF NOT EXISTS voice_transcripts (
  id                INT(11)      NOT NULL AUTO_INCREMENT,
  username          VARCHAR(50)  NOT NULL,
  original_filename VARCHAR(255) NULL,
  audio_path        VARCHAR(500) NULL,
  file_size         INT(11)      NULL,
  transcript        TEXT         NOT NULL,
  model_used        VARCHAR(50)  NULL,
  inspection_id     INT(11)      NULL,
  created_at        TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  KEY idx_username (username),
  KEY idx_inspection_id (inspection_id),
  KEY idx_created_at (created_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
