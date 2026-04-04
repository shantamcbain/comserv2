-- =============================================================================
-- Job System Schema  (Migration 005)
-- =============================================================================
-- Provides job posting and application functionality.
-- Anyone can post or apply for a job.
-- Members can opt in to use the points payment system for jobs.
--
-- Tables:
--   jobs              - job postings
--   job_applications  - applications linking users (or guests) to jobs
-- =============================================================================

SET FOREIGN_KEY_CHECKS = 0;

-- -----------------------------------------------------------------------------
-- jobs
-- Any user (member or guest-registered) can post a job.
-- If posted_by_user_id is set, the poster is a registered user.
-- payment_type tracks whether the job pays in points, cash, or both.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `jobs` (
    `id`                  INT            NOT NULL AUTO_INCREMENT,
    `sitename`            VARCHAR(255)   NOT NULL DEFAULT 'CSC'
                            COMMENT 'Site that owns this job posting',
    `title`               VARCHAR(255)   NOT NULL,
    `description`         TEXT           NOT NULL,
    `requirements`        TEXT           NULL,
    `location`            VARCHAR(255)   NULL,
    `remote`              TINYINT(1)     NOT NULL DEFAULT 0,
    `posted_by_user_id`   INT            NULL
                            COMMENT 'FK to users.id; NULL if posted by guest',
    `poster_name`         VARCHAR(255)   NULL
                            COMMENT 'Display name if poster is a guest',
    `poster_email`        VARCHAR(255)   NULL,
    `status`              VARCHAR(50)    NOT NULL DEFAULT 'open'
                            COMMENT 'open | closed | filled',
    `payment_type`        VARCHAR(50)    NOT NULL DEFAULT 'cash'
                            COMMENT 'cash | points | hybrid',
    `point_rate`          DECIMAL(14,4)  NULL
                            COMMENT 'Points per hour (if payment_type includes points)',
    `cash_rate`           DECIMAL(14,4)  NULL
                            COMMENT 'Cash amount or hourly rate',
    `currency`            VARCHAR(10)    NOT NULL DEFAULT 'CAD',
    `accept_points_payment` TINYINT(1)  NOT NULL DEFAULT 0
                            COMMENT '1 = poster is willing to pay applicants via points',
    `expires_at`          DATE           NULL,
    `created_at`          TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`          TIMESTAMP      NOT NULL DEFAULT CURRENT_TIMESTAMP
                            ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_jobs_sitename`  (`sitename`),
    KEY `idx_jobs_status`    (`status`),
    KEY `idx_jobs_posted_by` (`posted_by_user_id`),
    CONSTRAINT `fk_jobs_user`
        FOREIGN KEY (`posted_by_user_id`) REFERENCES `users` (`id`)
        ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Job postings. Open to all users and guests.';

-- -----------------------------------------------------------------------------
-- job_applications
-- Links an applicant to a job. user_id is nullable so guests can apply
-- after creating a free account (they become normal users on registration).
-- use_points_payment = 1 means the applicant is willing to be paid in points.
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS `job_applications` (
    `id`                   INT           NOT NULL AUTO_INCREMENT,
    `job_id`               INT           NOT NULL,
    `user_id`              INT           NULL
                             COMMENT 'FK to users.id; set once guest creates account',
    `applicant_name`       VARCHAR(255)  NOT NULL,
    `applicant_email`      VARCHAR(255)  NOT NULL,
    `cover_letter`         TEXT          NULL,
    `resume_file`          VARCHAR(500)  NULL
                             COMMENT 'Relative path to uploaded resume file',
    `use_points_payment`   TINYINT(1)   NOT NULL DEFAULT 0
                             COMMENT '1 = applicant willing to receive points as payment',
    `status`               VARCHAR(50)  NOT NULL DEFAULT 'pending'
                             COMMENT 'pending | reviewed | interviewed | hired | rejected',
    `notes`                TEXT         NULL
                             COMMENT 'Internal recruiter/poster notes',
    `created_at`           TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
    `updated_at`           TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP
                             ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (`id`),
    KEY `idx_ja_job_id`  (`job_id`),
    KEY `idx_ja_user_id` (`user_id`),
    KEY `idx_ja_status`  (`status`),
    CONSTRAINT `fk_ja_job`
        FOREIGN KEY (`job_id`) REFERENCES `jobs` (`id`) ON DELETE CASCADE,
    CONSTRAINT `fk_ja_user`
        FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE SET NULL
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
  COMMENT='Applications submitted for a job. Guests register to become normal users.';

SET FOREIGN_KEY_CHECKS = 1;
