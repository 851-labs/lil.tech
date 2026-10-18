CREATE TABLE `apple_token_revocations` (
	`id` text PRIMARY KEY,
	`refresh_token` text NOT NULL,
	`client_id` text NOT NULL,
	`attempts` integer NOT NULL,
	`next_attempt_at` integer NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `connections` (
	`id` text PRIMARY KEY,
	`user_id` text NOT NULL,
	`kind` text NOT NULL,
	`account_ref` text NOT NULL,
	`display_name` text,
	`scopes` text DEFAULT '[]' NOT NULL,
	`credentials` text,
	`status` text DEFAULT 'active' NOT NULL,
	`created_at` integer NOT NULL,
	`updated_at` integer NOT NULL,
	CONSTRAINT `fk_connections_user_id_users_id_fk` FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON DELETE CASCADE,
	CONSTRAINT `connections_user_kind_account` UNIQUE(`user_id`,`kind`,`account_ref`)
);
--> statement-breakpoint
CREATE TABLE `consents` (
	`id` integer PRIMARY KEY AUTOINCREMENT,
	`user_id` text NOT NULL,
	`type` text NOT NULL,
	`policy_version` text NOT NULL,
	`granted_at` integer NOT NULL,
	`withdrawn_at` integer,
	CONSTRAINT `fk_consents_user_id_users_id_fk` FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `devices` (
	`id` text PRIMARY KEY,
	`user_id` text NOT NULL,
	`app` text NOT NULL,
	`platform` text NOT NULL,
	`name` text,
	`push_token` text,
	`created_at` integer NOT NULL,
	`last_seen_at` integer NOT NULL,
	CONSTRAINT `fk_devices_user_id_users_id_fk` FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON DELETE CASCADE,
	CONSTRAINT `devices_id_user_id` UNIQUE(`id`,`user_id`)
);
--> statement-breakpoint
CREATE TABLE `identities` (
	`id` text PRIMARY KEY,
	`user_id` text NOT NULL,
	`provider` text NOT NULL,
	`subject` text NOT NULL,
	`email` text,
	`email_verified` integer DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	`apple_refresh_token` text,
	`apple_client_id` text,
	CONSTRAINT `fk_identities_user_id_users_id_fk` FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON DELETE CASCADE,
	CONSTRAINT `identities_provider_subject` UNIQUE(`provider`,`subject`)
);
--> statement-breakpoint
CREATE TABLE `identity_token_uses` (
	`token_hash` text PRIMARY KEY,
	`expires_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `sessions` (
	`id` text PRIMARY KEY,
	`user_id` text NOT NULL,
	`device_id` text NOT NULL,
	`family_id` text NOT NULL,
	`refresh_token_hash` text NOT NULL UNIQUE,
	`created_at` integer NOT NULL,
	`expires_at` integer NOT NULL,
	`revoked_at` integer,
	CONSTRAINT `fk_sessions_user_id_users_id_fk` FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_sessions_device_id_user_id_devices_id_user_id_fk` FOREIGN KEY (`device_id`,`user_id`) REFERENCES `devices`(`id`,`user_id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `users` (
	`id` text PRIMARY KEY,
	`display_name` text,
	`created_at` integer NOT NULL,
	`storage_bytes` integer,
	`storage_measured_at` integer
);
--> statement-breakpoint
CREATE INDEX `apple_token_revocations_next` ON `apple_token_revocations` (`next_attempt_at`);--> statement-breakpoint
CREATE INDEX `consents_user_type` ON `consents` (`user_id`,`type`,`granted_at`);--> statement-breakpoint
CREATE INDEX `devices_user_id` ON `devices` (`user_id`);--> statement-breakpoint
CREATE INDEX `devices_last_seen_at` ON `devices` (`last_seen_at`);--> statement-breakpoint
CREATE INDEX `identities_user_id` ON `identities` (`user_id`);--> statement-breakpoint
CREATE INDEX `identity_token_uses_expires_at` ON `identity_token_uses` (`expires_at`);--> statement-breakpoint
CREATE INDEX `sessions_user_id` ON `sessions` (`user_id`);--> statement-breakpoint
CREATE INDEX `sessions_device_id` ON `sessions` (`device_id`,`user_id`);--> statement-breakpoint
CREATE INDEX `sessions_family_id` ON `sessions` (`family_id`);--> statement-breakpoint
-- Hand-written: Drizzle can't express triggers. Every deleted Sign in with Apple identity's token
-- is queued for revoking (851-2612), in the same statement as the deletion (including the cascade
-- from deleting its user), so none is lost between the two. Times are milliseconds.
CREATE TRIGGER `identities_queue_apple_token_revocation`
BEFORE DELETE ON `identities`
WHEN OLD.`apple_refresh_token` IS NOT NULL AND OLD.`apple_client_id` IS NOT NULL
BEGIN
  INSERT INTO `apple_token_revocations`
    (`id`, `refresh_token`, `client_id`, `attempts`, `next_attempt_at`, `created_at`)
  VALUES (
    OLD.`id`, OLD.`apple_refresh_token`, OLD.`apple_client_id`, 0,
    CAST(strftime('%s', 'now') AS INTEGER) * 1000, CAST(strftime('%s', 'now') AS INTEGER) * 1000
  )
  ON CONFLICT (`id`) DO UPDATE SET
    `refresh_token` = excluded.`refresh_token`, `client_id` = excluded.`client_id`, `attempts` = 0;
END;
