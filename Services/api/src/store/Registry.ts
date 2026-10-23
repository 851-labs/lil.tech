import { healthEntities } from "../health/HealthEntities.ts";
import { HealthCard } from "../health/cards/HealthCards.ts";
import { HealthPin } from "../health/HealthPins.ts";
import type { Entity } from "./Entities.ts";

/**
 * Every entity the store holds. Adding one also needs a store migration that creates its table
 * (`createEntityTable`), and a test checks they match.
 */
export const entities: ReadonlyArray<Entity> = [...healthEntities, HealthPin, HealthCard];
