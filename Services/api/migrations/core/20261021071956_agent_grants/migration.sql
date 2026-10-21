CREATE TABLE `agent_authorizations` (
	`id` text PRIMARY KEY,
	`client_id` text NOT NULL,
	`redirect_uri` text NOT NULL,
	`state` text,
	`code_challenge` text NOT NULL,
	`scopes` text NOT NULL,
	`resource` text NOT NULL,
	`browser_hash` text NOT NULL,
	`created_at` integer NOT NULL,
	`expires_at` integer NOT NULL,
	`user_id` text,
	`granted_scopes` text,
	`code_hash` text UNIQUE,
	`code_expires_at` integer,
	`used_at` integer,
	`grant_id` text,
	CONSTRAINT `fk_agent_authorizations_client_id_oauth_clients_client_id_fk` FOREIGN KEY (`client_id`) REFERENCES `oauth_clients`(`client_id`) ON DELETE CASCADE,
	CONSTRAINT `fk_agent_authorizations_user_id_users_id_fk` FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `agent_grants` (
	`id` text PRIMARY KEY,
	`user_id` text NOT NULL,
	`client_id` text NOT NULL,
	`client_name` text,
	`client_domain` text,
	`redirect_host` text NOT NULL,
	`scopes` text NOT NULL,
	`resource` text NOT NULL,
	`created_at` integer NOT NULL,
	`last_used_at` integer NOT NULL,
	CONSTRAINT `fk_agent_grants_user_id_users_id_fk` FOREIGN KEY (`user_id`) REFERENCES `users`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_agent_grants_client_id_oauth_clients_client_id_fk` FOREIGN KEY (`client_id`) REFERENCES `oauth_clients`(`client_id`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE TABLE `agent_tokens` (
	`token_hash` text PRIMARY KEY,
	`grant_id` text NOT NULL,
	`kind` text NOT NULL,
	`replaces` text,
	`refresh_token_hash` text,
	`expires_at` integer NOT NULL,
	`used_at` integer,
	CONSTRAINT `fk_agent_tokens_grant_id_agent_grants_id_fk` FOREIGN KEY (`grant_id`) REFERENCES `agent_grants`(`id`) ON DELETE CASCADE,
	CONSTRAINT `fk_agent_tokens_refresh_token_hash_agent_tokens_token_hash_fk` FOREIGN KEY (`refresh_token_hash`) REFERENCES `agent_tokens`(`token_hash`) ON DELETE CASCADE
);
--> statement-breakpoint
CREATE INDEX `agent_authorizations_expires_at` ON `agent_authorizations` (`expires_at`);--> statement-breakpoint
CREATE INDEX `agent_authorizations_client_id` ON `agent_authorizations` (`client_id`);--> statement-breakpoint
CREATE INDEX `agent_authorizations_user_id` ON `agent_authorizations` (`user_id`);--> statement-breakpoint
CREATE INDEX `agent_grants_user_id` ON `agent_grants` (`user_id`);--> statement-breakpoint
CREATE INDEX `agent_grants_client_id` ON `agent_grants` (`client_id`);--> statement-breakpoint
CREATE INDEX `agent_tokens_grant_id` ON `agent_tokens` (`grant_id`);--> statement-breakpoint
CREATE INDEX `agent_tokens_replaces` ON `agent_tokens` (`replaces`);--> statement-breakpoint
CREATE INDEX `agent_tokens_refresh_token_hash` ON `agent_tokens` (`refresh_token_hash`);--> statement-breakpoint
CREATE INDEX `agent_tokens_expires_at` ON `agent_tokens` (`expires_at`);