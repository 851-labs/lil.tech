ALTER TABLE `agent_authorizations` ADD `sign_in_provider` text;--> statement-breakpoint
ALTER TABLE `agent_authorizations` ADD `sign_in_state_hash` text;--> statement-breakpoint
ALTER TABLE `agent_authorizations` ADD `sign_in_nonce` text;--> statement-breakpoint
ALTER TABLE `agent_authorizations` ADD `sign_in_user_id` text REFERENCES users(id) ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE `agent_authorizations` ADD `sign_in_ticket_hash` text;