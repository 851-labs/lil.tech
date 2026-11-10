import { assert, describe, it } from "@effect/vitest";
import { Effect, type Schema } from "effect";
import {
  keptDevice,
  keptMetadata,
  metadataFields,
  withKeptMetadata,
} from "../../src/health/HealthMetadata.ts";
import { HealthSample, HealthWorkout, healthEntities } from "../../src/health/HealthEntities.ts";
import {
  metadataCleanupPending,
  metadataCleanupStep,
  metadataPolicyVersion,
} from "../../src/health/MetadataCleanup.ts";
import { startUserStore } from "../../src/store/UserStore.ts";
import { entities } from "../../src/store/Registry.ts";
import { makeTestStoreSql } from "../store/TestStoreSql.ts";
import { makeTestStore } from "../store/TestUserStores.ts";

// Synthetic data only (AGENTS.md): made-up devices, serial numbers and apps' keys.
const uuid = (n: number) => `6f1c2a40-0000-4000-8000-${String(n).padStart(12, "0")}`;
const start = 1_760_400_000_000;

/** Metadata as an iPhone from before 851-4152 uploaded it, every key included. */
const oldMetadata = {
  HKTimeZone: "Europe/Bucharest",
  HKWasUserEntered: true,
  HKDeviceSerialNumber: "SN-0000-SYNTHETIC",
  HKUDIProductionIdentifier: "(10)LOT0001(21)SERIAL0001",
  HKDigitalSignature: "c2lnbmF0dXJl",
  HKMetadataKeySyncIdentifier: "reading-1",
  HKMetadataKeySyncVersion: 1,
  HKExternalUUID: "8e9a2a52-0000-4000-8000-000000000001",
  "com.example.app.note": "after a run",
};
const oldDevice = {
  name: "Blood Pressure Monitor",
  manufacturer: "Example Medical",
  model: "BP-1",
  localIdentifier: "00:11:22:33:44:55",
  udiDeviceIdentifier: "00812345678906",
};

const sample = (n: number, metadata: Schema.Json = oldMetadata, device: Schema.Json = null) => ({
  entity: "health_sample",
  op: "upsert" as const,
  id: uuid(n),
  row: {
    type: "HKQuantityTypeIdentifierBloodGlucose",
    startDate: start + n * 60_000,
    endDate: start + n * 60_000,
    value: 5,
    unit: "mmol<180.15588000005408>/L",
    sourceName: "Example Glucose",
    sourceBundleId: "com.example.glucose",
    metadata,
    device,
  },
});

const workout = (n: number) => ({
  entity: "health_workout",
  op: "upsert" as const,
  id: uuid(n),
  row: {
    activityType: 46,
    startDate: start,
    endDate: start + 1_800_000,
    duration: 1_800,
    activities: [
      { activityType: 46, metadata: { HKLapLength: "25 m", "com.example.swim.lane": 4 } },
    ],
    events: [{ type: 3, startDate: start, endDate: start, metadata: { HKSWOLFScore: 30 } }],
    statistics: {},
    sourceName: "Example Swim",
    sourceBundleId: "com.example.swim",
    metadata: { HKIndoorWorkout: true, LilWorkoutPlan: { kind: "custom" }, Custom: 1 },
  },
});

/** Makes a store look like one written before 851-4152, whose records weren't cleaned. */
const beforeCleanup = (sql: ReturnType<typeof makeTestStore>["sql"]) =>
  sql.exec("DELETE FROM meta WHERE key IN ('metadata_policy', 'metadata_cleanup')");

describe("keeping metadata (851-4152)", () => {
  it("keeps only the kept keys and device properties", () => {
    assert.deepStrictEqual(keptMetadata(oldMetadata), {
      HKTimeZone: "Europe/Bucharest",
      HKWasUserEntered: true,
    });
    assert.isNull(keptMetadata({ HKExternalUUID: "x" }));
    // Clean metadata stays as it is, empty included, so it isn't rewritten.
    const clean = { HKTimeZone: "Europe/Bucharest" };
    assert.strictEqual(keptMetadata(clean), clean);
    assert.deepStrictEqual(keptMetadata({}), {});
    assert.isNull(keptMetadata(null));
    assert.deepStrictEqual(keptDevice(oldDevice), {
      name: "Blood Pressure Monitor",
      manufacturer: "Example Medical",
      model: "BP-1",
    });
    // A device-scoped record's device is its ID, which stays.
    assert.strictEqual(
      keptDevice("dev_000000000000000000000000a1"),
      "dev_000000000000000000000000a1",
    );
  });

  it("cleans a workout's activities and events, and keeps lil health's own keys", () => {
    const row: Readonly<Record<string, Schema.Json>> = workout(1).row;
    const kept = withKeptMetadata(HealthWorkout, row);
    assert.deepStrictEqual(kept.metadata, {
      HKIndoorWorkout: true,
      LilWorkoutPlan: { kind: "custom" },
    });
    assert.deepStrictEqual(kept.activities, [
      { activityType: 46, metadata: { HKLapLength: "25 m" } },
    ]);
    assert.deepStrictEqual(kept.events, row.events);
    // Fields the row doesn't set stay unset.
    assert.notProperty(withKeptMetadata(HealthSample, { value: 1 }), "metadata");
  });

  it("covers every health entity with metadata or a device", () => {
    const covered = healthEntities.filter((entity) => metadataFields(entity).length > 0);
    assert.sameMembers(
      covered.map(({ name }) => name),
      [
        "health_provenance",
        "health_sample",
        "health_correlation",
        "health_workout",
        "health_audiogram",
        "health_vision_prescription",
        "health_medication_dose",
        "health_state_of_mind",
        "health_scored_assessment",
        "health_electrocardiogram",
        "health_workout_route",
        "health_document",
        "health_heartbeat_series",
      ],
    );
    // Every entity with a `metadata` field is covered.
    for (const entity of healthEntities) {
      if (entity.fields.some(({ field }) => field === "metadata")) {
        assert.include(covered, entity, entity.name);
      }
    }
    // Statistics' device is the uploading device's ID, not an `HKDevice`.
    assert.notInclude(
      covered.map(({ name }) => name),
      "health_statistic",
    );
  });
});

describe("cleaning stored records (851-4152)", () => {
  it.effect(
    "rewrites the records with dropped keys through the change log, a chunk at a time",
    () =>
      Effect.gen(function* () {
        const { sql, store } = makeTestStore();
        // A new store has nothing to clean.
        assert.isFalse(metadataCleanupPending(sql));
        yield* store.applyMutations([
          sample(1),
          sample(2, { HKTimeZone: "Europe/Bucharest" }),
          sample(3, null, oldDevice),
          sample(4),
          sample(5),
          workout(6),
          {
            entity: "health_provenance",
            op: "upsert",
            id: "0123456789abcdef0123456789abcdef",
            row: { sourceRevision: null, device: oldDevice },
          },
          { entity: "health_sample", op: "delete", id: uuid(5) },
        ]);
        beforeCleanup(sql);
        assert.isTrue(metadataCleanupPending(sql));
        const head = sql.exec("SELECT max(seq) AS seq FROM changes")[0]?.["seq"] as number;

        // In the registry's order: the provenance record, which changes, then samples 1 and 2,
        // of which 1 changes (2 is clean already).
        let step = metadataCleanupStep(sql, entities, 10, 3);
        assert.deepInclude(step, { looked: 3, changed: 2, finished: false, total: 2 });
        while (!step.finished) step = metadataCleanupStep(sql, entities, 11, 3);
        // Samples 3 and 4 and the workout too. Sample 5's row, deleted, is left alone: an upsert
        // would bring it back.
        assert.strictEqual(step.total, 5);
        assert.isFalse(metadataCleanupPending(sql));
        assert.deepStrictEqual(sql.exec("SELECT value FROM meta WHERE key = 'metadata_policy'"), [
          { value: metadataPolicyVersion },
        ]);

        const metadata = (id: string) =>
          sql.exec("SELECT metadata, device FROM health_sample WHERE id = ?", id)[0];
        assert.deepStrictEqual(metadata(uuid(1)), {
          metadata: '{"HKTimeZone":"Europe/Bucharest","HKWasUserEntered":true}',
          device: null,
        });
        assert.deepStrictEqual(metadata(uuid(3)), {
          metadata: null,
          device:
            '{"manufacturer":"Example Medical","model":"BP-1","name":"Blood Pressure Monitor"}',
        });
        assert.deepStrictEqual(sql.exec("SELECT device FROM health_provenance"), [
          {
            device:
              '{"manufacturer":"Example Medical","model":"BP-1","name":"Blood Pressure Monitor"}',
          },
        ]);
        const [stored] = sql.exec("SELECT metadata, activities FROM health_workout");
        assert.strictEqual(
          stored?.["metadata"],
          '{"HKIndoorWorkout":true,"LilWorkoutPlan":{"kind":"custom"}}',
        );
        assert.strictEqual(
          stored?.["activities"],
          '[{"activityType":46,"metadata":{"HKLapLength":"25 m"}}]',
        );
        // Still deleted.
        assert.lengthOf(sql.exec("SELECT id FROM tombstones WHERE id = ?", uuid(5)), 1);

        // One change for each record cleaned, which the Macs pull, served whole and clean.
        const changes = sql.exec(
          "SELECT entity, id, op FROM changes WHERE seq > ? ORDER BY seq",
          head,
        );
        assert.deepStrictEqual(
          changes.map(({ entity, id }) => `${entity as string} ${id as string}`),
          [
            "health_provenance 0123456789abcdef0123456789abcdef",
            `health_sample ${uuid(1)}`,
            `health_sample ${uuid(3)}`,
            `health_sample ${uuid(4)}`,
            `health_workout ${uuid(6)}`,
          ],
        );
        const page = yield* store.readChanges(head, 100);
        const served = page.changes.find((change) => change.id === uuid(1));
        assert.deepStrictEqual(served?.op === "upsert" ? served.row?.["metadata"] : undefined, {
          HKTimeZone: "Europe/Bucharest",
          HKWasUserEntered: true,
        });
        assert.strictEqual(served?.op === "upsert" ? served.row?.["value"] : undefined, 5);

        // Going through again changes nothing.
        beforeCleanup(sql);
        step = metadataCleanupStep(sql, entities, 13);
        assert.deepInclude(step, { looked: 6, changed: 0, finished: true, total: 0 });
      }),
  );

  it.effect("leaves out a record a check made stricter since refuses, and carries on", () =>
    Effect.gen(function* () {
      const { sql, store } = makeTestStore();
      yield* store.applyMutations([workout(1), sample(2, {}), sample(3)]);
      // As if it had been stored before its entity's check refused it.
      sql.exec("UPDATE health_workout SET activities = '{}'");
      beforeCleanup(sql);

      const step = metadataCleanupStep(sql, entities, 10);
      assert.deepInclude(step, { finished: true, total: 1, totalSkipped: 1 });
      // Sample 3 is cleaned; sample 2's empty metadata isn't rewritten; the workout stays.
      assert.deepStrictEqual(sql.exec("SELECT id, metadata FROM health_sample ORDER BY id"), [
        { id: uuid(2), metadata: "{}" },
        { id: uuid(3), metadata: '{"HKTimeZone":"Europe/Bucharest","HKWasUserEntered":true}' },
      ]);
      assert.include(
        sql.exec("SELECT metadata FROM health_workout")[0]?.["metadata"] as string,
        "Custom",
      );
    }),
  );

  it.effect("runs from the alarm, which a store starting with records to clean sets", () =>
    Effect.gen(function* () {
      const sql = makeTestStoreSql();
      const first = yield* startUserStore(sql, entities);
      yield* first.applyMutations([sample(1)]);
      beforeCleanup(sql);
      yield* Effect.promise(() => sql.setAlarm(Number.MAX_SAFE_INTEGER));

      // As the Worker starts the store again, after a deploy.
      const store = yield* startUserStore(sql, entities);
      const alarm = yield* Effect.promise(() => sql.getAlarm());
      assert.isBelow(alarm ?? Number.MAX_SAFE_INTEGER, Number.MAX_SAFE_INTEGER);
      yield* store.alarm();
      assert.isFalse(metadataCleanupPending(sql));
      assert.strictEqual(
        sql.exec("SELECT metadata FROM health_sample")[0]?.["metadata"],
        '{"HKTimeZone":"Europe/Bucharest","HKWasUserEntered":true}',
      );
    }),
  );
});
