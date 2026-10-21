ALTER TABLE `agent_authorizations` ADD `sign_in_user_id` text REFERENCES users(id) ON DELETE CASCADE;--> statement-breakpoint
ALTER TABLE `agent_authorizations` ADD `sign_in_ticket_hash` text;