public import SQLiteData

/// Creates an empty, in-memory database with the same schema as the parts of `chat.db` we query.
///
/// Table names, column names, types and defaults match the real `chat.db`. Tests and previews seed
/// their own synthetic rows. Never copy real Messages data into a seed.
public func makeInMemoryChatDatabase() throws -> DatabaseQueue {
  let database = try DatabaseQueue()
  try database.write { db in
    try #sql(
      """
      CREATE TABLE chat (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        guid TEXT UNIQUE NOT NULL,
        style INTEGER,
        state INTEGER,
        account_id TEXT,
        chat_identifier TEXT,
        service_name TEXT,
        room_name TEXT,
        is_archived INTEGER DEFAULT 0,
        display_name TEXT,
        group_id TEXT,
        is_filtered INTEGER DEFAULT 0
      )
      """
    )
    .execute(db)
    try #sql(
      """
      CREATE TABLE handle (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT UNIQUE,
        id TEXT NOT NULL,
        country TEXT,
        service TEXT NOT NULL,
        uncanonicalized_id TEXT,
        person_centric_id TEXT,
        UNIQUE (id, service)
      )
      """
    )
    .execute(db)
    try #sql(
      """
      CREATE TABLE message (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        guid TEXT UNIQUE NOT NULL,
        text TEXT,
        handle_id INTEGER DEFAULT 0,
        attributedBody BLOB,
        service TEXT,
        date INTEGER,
        is_from_me INTEGER DEFAULT 0,
        is_read INTEGER DEFAULT 0,
        cache_has_attachments INTEGER DEFAULT 0,
        item_type INTEGER DEFAULT 0,
        associated_message_type INTEGER DEFAULT 0,
        associated_message_guid TEXT DEFAULT NULL,
        associated_message_emoji TEXT DEFAULT NULL,
        is_audio_message INTEGER DEFAULT 0,
        is_delivered INTEGER DEFAULT 0,
        date_read INTEGER DEFAULT 0,
        date_edited INTEGER DEFAULT 0,
        error INTEGER DEFAULT 0
      )
      """
    )
    .execute(db)
    try #sql(
      """
      CREATE TABLE chat_handle_join (
        chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
        handle_id INTEGER REFERENCES handle (ROWID) ON DELETE CASCADE,
        UNIQUE(chat_id, handle_id)
      )
      """
    )
    .execute(db)
    try #sql(
      """
      CREATE TABLE attachment (
        ROWID INTEGER PRIMARY KEY AUTOINCREMENT,
        guid TEXT UNIQUE NOT NULL,
        filename TEXT,
        uti TEXT,
        mime_type TEXT,
        transfer_name TEXT,
        is_sticker INTEGER DEFAULT 0,
        hide_attachment INTEGER DEFAULT 0
      )
      """
    )
    .execute(db)
    try #sql(
      """
      CREATE TABLE message_attachment_join (
        message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE,
        attachment_id INTEGER REFERENCES attachment (ROWID) ON DELETE CASCADE,
        UNIQUE(message_id, attachment_id)
      )
      """
    )
    .execute(db)
    try #sql(
      """
      CREATE TABLE chat_recoverable_message_join (
        chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
        message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE,
        delete_date INTEGER,
        PRIMARY KEY (chat_id, message_id),
        CHECK (delete_date != 0)
      )
      """
    )
    .execute(db)
    try #sql(
      """
      CREATE TABLE chat_message_join (
        chat_id INTEGER REFERENCES chat (ROWID) ON DELETE CASCADE,
        message_id INTEGER REFERENCES message (ROWID) ON DELETE CASCADE,
        message_date INTEGER DEFAULT 0,
        PRIMARY KEY (chat_id, message_id)
      )
      """
    )
    .execute(db)
    try #sql(
      """
      CREATE INDEX chat_message_join_idx_message_date_id_chat_id
      ON chat_message_join(chat_id, message_date, message_id)
      """
    )
    .execute(db)
  }
  return database
}
