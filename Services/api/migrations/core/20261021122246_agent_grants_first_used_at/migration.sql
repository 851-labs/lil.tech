ALTER TABLE `agent_grants` ADD `first_used_at` integer;--> statement-breakpoint
-- Hand-written: grants used before this column was added (851-2872). Their first use is unknown,
-- so a recorded later use stands in for it, and they stay shown as used.
UPDATE `agent_grants` SET `first_used_at` = `last_used_at` WHERE `last_used_at` > `created_at`;
