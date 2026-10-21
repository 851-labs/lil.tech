CREATE TABLE `oauth_clients` (
	`id` text PRIMARY KEY,
	`client_id` text NOT NULL UNIQUE,
	`kind` text NOT NULL,
	`name` text,
	`client_uri` text,
	`redirect_uris` text NOT NULL,
	`application_type` text NOT NULL,
	`expires_at` integer,
	`created_at` integer NOT NULL,
	`last_used_at` integer
);
