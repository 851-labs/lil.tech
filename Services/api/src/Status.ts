import { Schema } from "effect";

export const Environment = Schema.Literals(["prod", "staging", "preview", "local"]);
export type Environment = typeof Environment.Type;

export class Status extends Schema.Class<Status>("lil/api/Status")({
  environment: Environment,
  version: Schema.NonEmptyString,
}) {}

export const decodeStatus = Schema.decodeUnknownEffect(Status);
