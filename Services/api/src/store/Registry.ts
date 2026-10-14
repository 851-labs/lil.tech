import { healthEntities } from "../health/HealthEntities.ts";
import type { Entity } from "./Entities.ts";

/**
 * Every entity the store holds. Adding one also needs a store migration that creates its table
 * (`createEntityTable`), and a test checks they match.
 */
export const entities: ReadonlyArray<Entity> = [...healthEntities];
