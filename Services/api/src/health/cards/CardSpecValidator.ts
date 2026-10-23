import {
  type HealthCatalogType,
  healthCatalogType,
  healthCatalogTypes,
  healthCategoryLook,
  healthCategoryName,
  workoutActivities,
  workoutActivityName,
} from "../HealthCatalog.ts";
import { shortTypeId } from "../tools/ToolTypes.ts";
import {
  codePointCount,
  codePoints,
  isJsonObject,
  type Json,
  type JsonObject,
  jsonBytes,
  jsonText,
  member,
  quoted,
  sameJson,
} from "./CardJson.ts";
import {
  type CardAggregation,
  type CardBucket,
  type CardChartStyle,
  type CardFormulaKind,
  type CardRange,
  type CardWindowKind,
  bucketRanges,
  cardAggregations,
  cardBuckets,
  cardChartStyles,
  cardColors,
  cardDisplayUnitDimensions,
  cardFormulaKinds,
  cardRanges,
  cardSpecVersion,
  cardSymbols,
  cardWindowKinds,
  chartableTypes,
  defaultRange,
  maxCardFormulas,
  maxCardSeries,
  maxCardSpecBytes,
  maxCardSpecErrors,
  maxCardVisibleLines,
  readableCardSpecVersions,
  storeMaxCardSpecBytes,
} from "./CardSpec.ts";

// The card spec's validator and canonicalizer, a port of the Swift `CardSpecValidator`
// (`docs/decisions/cards.md`, Validation and errors). It must give what the Swift gives, the same
// codes, paths and messages in the same order, which `validation-cases.json` checks: an agent sees
// the same errors from either, and a spec an app wrote is never refused here, which would make the
// app bootstrap again. So it's written as the Swift is, rather than as an Effect Schema, whose
// errors read differently: `CardSpec` (its structure) is checked against the same JSON Schema.
//
// It runs in two passes. First each field, in the spec's order, each object's fields in the
// table's order and then its unknown fields: shapes, values, and the rules of one series or
// formula. Then the rules across fields. Then, with no errors, the size of the canonical form.

/** The rules, as the Swift `CardSpecError.Code` names them. */
export type CardSpecErrorCode =
  | "invalidJSON"
  | "invalidType"
  | "required"
  | "unknownField"
  | "unknownValue"
  | "unsupportedVersion"
  | "nameLength"
  | "invalidCharacters"
  | "unknownSymbol"
  | "unknownColor"
  | "unitDimension"
  | "seriesCount"
  | "invalidID"
  | "duplicateID"
  | "unknownType"
  | "notQuantity"
  | "unreadableType"
  | "aggregationNotAllowed"
  | "windowOnCumulative"
  | "windowMinutes"
  | "windowTime"
  | "unknownActivity"
  | "activityCount"
  | "duplicateActivity"
  | "filterOnCumulative"
  | "emptyFilter"
  | "filterList"
  | "filterValue"
  | "labelLength"
  | "formulaCount"
  | "formulaPoints"
  | "unknownReference"
  | "sameSeries"
  | "mixedUnits"
  | "nothingVisible"
  | "visibleCount"
  | "nightNeedsSleepWindow"
  | "sleepWindowBucket"
  | "rangeNotForBucket"
  | "rangesStyle"
  | "goalValue"
  | "tooLarge"
  | "notCanonical"
  | "positionLength"
  | "invalidPosition";

/**
 * One thing wrong with a spec: where, as a JSON path (`series[0].window.minutes`, empty for the
 * whole spec), which rule, and a message written for agents.
 */
export interface CardSpecError {
  readonly path: string;
  readonly code: CardSpecErrorCode;
  readonly message: string;
}

/** A spec canonicalized, or every error it has, up to 20. */
export type CardSpecResult =
  | { readonly spec: JsonObject; readonly errors?: undefined }
  | { readonly spec?: undefined; readonly errors: ReadonlyArray<CardSpecError> };

/**
 * Canonicalizes and validates an input spec, as apps and tools do before writing (Swift's
 * `CardSpec(input:)`): fields with defaults may be left out, and types and workout activities
 * named. The spec comes in the canonical form, keys in the design's order.
 */
export const canonicalCardSpec = (input: Json): CardSpecResult =>
  canonicalize(input, maxCardSpecBytes);

/**
 * The store's check of a spec it's asked to keep (Swift's `CardSpec.storedErrors`): valid, at most
 * 16 KB, and already canonical, compared as values, not text. Empty when it's fine.
 */
export const storedCardSpecErrors = (spec: Json): ReadonlyArray<CardSpecError> => {
  const result = canonicalize(spec, storeMaxCardSpecBytes);
  if (result.errors !== undefined) return result.errors;
  return sameJson(result.spec, spec)
    ? []
    : [
        {
          path: "",
          code: "notCanonical",
          message:
            "The spec isn't in canonical form (a default left out, a type or activity by name, or " +
            "a name or label not trimmed): apps and tools write it canonicalized.",
        },
      ];
};

const canonicalize = (input: Json, sizeLimit: number): CardSpecResult => {
  const validator = new Validator();
  let spec = validator.run(input);
  if (spec !== undefined && validator.errors.length === 0) {
    const bytes = jsonBytes(spec);
    if (bytes > sizeLimit) {
      const size = Math.ceil((bytes * 10) / 1024) / 10;
      validator.fail(
        "",
        "tooLarge",
        `The spec is ${size.toFixed(1)} KB; the limit is ${Math.floor(sizeLimit / 1024)} KB.`,
      );
    }
  }
  if (validator.errors.length > 0) spec = undefined;
  return spec === undefined ? { errors: validator.errors.slice(0, maxCardSpecErrors) } : { spec };
};

// MARK: - Values

/** The unit of a series' values: its type's catalog unit, or a number of readings (`count`). */
type ValueUnit = { readonly readings: true } | { readonly catalog: string };

const sameUnit = (a: ValueUnit, b: ValueUnit) =>
  "readings" in a ? "readings" in b : "catalog" in b && a.catalog === b.catalog;

/** The unit's string: `count` for readings. */
const unitText = (unit: ValueUnit) => ("readings" in unit ? "count" : unit.catalog);

interface Series {
  readonly path: string;
  id?: string | undefined;
  type?: HealthCatalogType | undefined;
  aggregation?: CardAggregation | undefined;
  window?: JsonObject | undefined;
  /** The window's kind, when it's known, even if its other fields are wrong. */
  windowKind?: CardWindowKind | undefined;
  hasWindow: boolean;
  filter?: JsonObject | undefined;
  label: string | null;
  hidden: boolean;
}

const seriesUnit = (series: Series): ValueUnit | undefined => {
  if (series.aggregation === undefined) return undefined;
  if (series.aggregation === "count") return { readings: true };
  const unit = series.type?.unit;
  return unit === null || unit === undefined ? undefined : { catalog: unit };
};

interface Formula {
  readonly path: string;
  id?: string | undefined;
  kind?: CardFormulaKind | undefined;
  of?: ReadonlyArray<string> | undefined;
  points?: number | undefined;
  label: string | null;
  hidden: boolean;
}

type Line =
  | { readonly series: Series; readonly formula?: undefined }
  | {
      readonly formula: Formula;
      readonly unit: ValueUnit | undefined;
      readonly series?: undefined;
    };

const lineUnit = (line: Line) => (line.series === undefined ? line.unit : seriesUnit(line.series));

const isSleepWindow = (kind: CardWindowKind | undefined) =>
  kind === "asleep" || kind === "beforeSleep" || kind === "afterWaking";

const isCumulative = (type: HealthCatalogType) => type.aggregation === "cumulative";

const oneOf = <T extends string>(values: ReadonlyArray<T>, value: string): T | undefined =>
  values.find((candidate) => candidate === value);

const isWhole = (value: number, minimum: number, maximum: number) =>
  Number.isInteger(value) && value >= minimum && value <= maximum;

/** "a, b or c" */
const list = (items: ReadonlyArray<string>) =>
  items.length > 1 ? `${items.slice(0, -1).join(", ")} or ${items.at(-1)}` : (items[0] ?? "");

/** A description at the start of a sentence: "A count of …". Paths stay as they are. */
const capitalized = (text: string) => (text.startsWith("a count") ? `A${text.slice(1)}` : text);

/** "Heart Rate (count/min)", or "a count of Heart Rate readings". */
const describeSeries = (series: Series) => {
  const name = series.type?.name ?? series.path;
  if (series.aggregation === "count") return `a count of ${name} readings`;
  return `${name} (${series.type?.unit ?? ""})`;
};

const describeLine = (line: Line) => {
  if (line.series !== undefined) return describeSeries(line.series);
  const unit = line.unit;
  const text =
    unit === undefined ? "" : "readings" in unit ? "a count of readings" : unitText(unit);
  return `${line.formula.path} (${text})`;
};

/** How many points a range would have in a bucket that doesn't offer it. */
const points = (bucket: CardBucket, range: CardRange) => {
  if (bucket === "hour" && range === "M") return "up to 744 points";
  if (bucket === "hour" && range === "6M") return "up to 4,416 points";
  if (bucket === "hour" && range === "Y") return "up to 8,784 points";
  return "1 point";
};

/** `a`, `b`, `c`, `d` by position. */
const seriesID = (index: number) => String.fromCharCode(97 + Math.min(index, 25));

const validID = /^[a-z][a-z0-9]{0,15}$/;

// MARK: - Text

/** Code points trimmed from names and labels: JavaScript's `String.prototype.trim()`'s. */
const isTrimmed = (code: number) =>
  (code >= 0x09 && code <= 0x0d) ||
  code === 0x20 ||
  code === 0xa0 ||
  code === 0x1680 ||
  (code >= 0x2000 && code <= 0x200a) ||
  code === 0x2028 ||
  code === 0x2029 ||
  code === 0x202f ||
  code === 0x205f ||
  code === 0x3000 ||
  code === 0xfeff;

/** Code points a name or label can't have: control characters and line and paragraph separators. */
const isForbidden = (code: number) =>
  code <= 0x1f || (code >= 0x7f && code <= 0x9f) || code === 0x2028 || code === 0x2029;

const trimmed = (text: string) => {
  const points = codePoints(text);
  const start = points.findIndex((point) => !isTrimmed(point.codePointAt(0)!));
  if (start === -1) return "";
  const end = points.findLastIndex((point) => !isTrimmed(point.codePointAt(0)!));
  return points.slice(start, end + 1).join("");
};

// MARK: - Types, symbols, activities

/** Swift's `CharacterSet.whitespaces`: spaces (Unicode's `Zs`) and tabs. */
const outerWhitespace = /^[\p{Zs}\t]+|[\p{Zs}\t]+$/gu;

/**
 * The type a person or agent names (Swift's `HealthCatalog.type(named:)`): by its HealthKit
 * identifier, by the name Health shows, or by the identifier without its prefix, in any case.
 */
const typeNamed = (name: string): HealthCatalogType | undefined => {
  const exact = healthCatalogType(name);
  if (exact !== undefined) return exact;
  const wanted = name.replace(outerWhitespace, "").toLowerCase();
  return (
    healthCatalogTypes.find((type) => type.name.toLowerCase() === wanted) ??
    healthCatalogTypes.find((type) => shortTypeId(type.id).toLowerCase() === wanted)
  );
};

/**
 * The chartable type a mistyped name most likely meant: of those `search` would find for it (each
 * of its words in the type's name, category or short identifier), the one with the shortest name,
 * ties in the catalog's order. None for fewer than 3 letters.
 */
const typeClose = (name: string): HealthCatalogType | undefined => {
  const words = name
    .toLowerCase()
    .split(/\p{White_Space}+/u)
    .filter((word) => word !== "");
  if (codePointCount(words.join("")) < 3) return undefined;
  let best: HealthCatalogType | undefined;
  for (const type of chartableTypes) {
    const category = type.category === null ? "" : healthCategoryName(type.category);
    const text = `${type.name} ${category} ${shortTypeId(type.id)}`.toLowerCase();
    if (!words.every((word) => text.includes(word))) continue;
    if (best === undefined || codePointCount(type.name) < codePointCount(best.name)) best = type;
  }
  return best;
};

/**
 * Up to three curated symbols close to a name that isn't one: those sharing the most dot-separated
 * words with it. A word scores 2 when a symbol has it, else 1 when one of the symbol's words starts
 * with it or it starts with one. Ties keep the list's order.
 */
const symbolsClose = (name: string) => {
  const words = name
    .toLowerCase()
    .split(".")
    .filter((word) => word !== "");
  return cardSymbols
    .map((symbol, offset) => {
      const symbolWords = symbol.split(".");
      const score = words.reduce((score, word) => {
        if (symbolWords.includes(word)) return score + 2;
        if (symbolWords.some((part) => part.startsWith(word) || word.startsWith(part))) {
          return score + 1;
        }
        return score;
      }, 0);
      return { symbol, score, offset };
    })
    .filter(({ score }) => score > 0)
    .sort((a, b) => b.score - a.score || a.offset - b.offset)
    .slice(0, 3)
    .map(({ symbol }) => symbol);
};

const activityNames = new Map(
  workoutActivities.map(({ activityType, name }) => [activityType, name]),
);

/** `HH:MM`, two digits each, from `00:00` to `23:59`, as minutes since midnight. */
const clockTime = (text: string): number | undefined => {
  const match = /^([0-9]{2}):([0-9]{2})$/.exec(text);
  if (match === null) return undefined;
  const hour = Number(match[1]);
  const minute = Number(match[2]);
  return hour <= 23 && minute <= 59 ? hour * 60 + minute : undefined;
};

const clockText = (minutes: number) =>
  `${String(Math.floor(minutes / 60)).padStart(2, "0")}:${String(minutes % 60).padStart(2, "0")}`;

// MARK: - The validator

class Validator {
  errors: Array<CardSpecError> = [];

  fail(path: string, code: CardSpecErrorCode, message: string) {
    this.errors.push({ path, code, message });
  }

  run(input: Json): JsonObject | undefined {
    if (!isJsonObject(input)) {
      this.fail("", "invalidType", "A card spec is a JSON object.");
      return undefined;
    }

    // Version
    const version = member(input, "version");
    if (version === undefined || version === null) {
      this.fail("version", "required", "version is required: the spec's format, 1.");
    } else if (typeof version === "number") {
      if (!(isWhole(version, 0, 1_000_000) && readableCardSpecVersions.includes(version))) {
        // Every other rule is version 1's: this is the one error.
        this.errors = [
          {
            path: "version",
            code: "unsupportedVersion",
            message:
              `version ${String(version)} isn't supported. This server reads card spec version ` +
              `${cardSpecVersion}.`,
          },
        ];
        return undefined;
      }
    } else {
      this.fail("version", "invalidType", "version must be a whole number: 1.");
    }

    // Display
    let name: string | undefined;
    let symbol: string | undefined;
    let color: string | undefined;
    let unit: string | undefined;
    const display = member(input, "display");
    if (display === undefined || display === null) {
      this.fail(
        "display",
        "required",
        "display is required: the card's name, and optionally its symbol, color and unit.",
      );
    } else if (isJsonObject(display)) {
      const displayName = member(display, "name");
      if (displayName === undefined || displayName === null) {
        this.fail(
          "display.name",
          "required",
          "display.name is required: what the card is called on Summary.",
        );
      } else if (typeof displayName === "string") {
        name = this.text(displayName, "display.name", "nameLength", false);
      } else {
        this.fail("display.name", "invalidType", "display.name must be a string.");
      }
      const displaySymbol = member(display, "symbol");
      if (typeof displaySymbol === "string") {
        if ((cardSymbols as ReadonlyArray<string>).includes(displaySymbol)) {
          symbol = displaySymbol;
        } else {
          const close = symbolsClose(displaySymbol);
          const suggestion = close.length === 0 ? "" : ` Close ones: ${close.join(", ")}.`;
          this.fail(
            "display.symbol",
            "unknownSymbol",
            `${quoted(displaySymbol)} isn't one of lil health's card symbols.${suggestion} The ` +
              "input schema lists them all.",
          );
        }
      } else if (displaySymbol !== undefined && displaySymbol !== null) {
        this.fail("display.symbol", "invalidType", "display.symbol must be a string.");
      }
      const displayColor = member(display, "color");
      if (typeof displayColor === "string") {
        color = oneOf(cardColors, displayColor);
        if (color === undefined) {
          this.fail(
            "display.color",
            "unknownColor",
            `${quoted(displayColor)} isn't a card color. Use one of: ${cardColors.join(", ")}.`,
          );
        }
      } else if (displayColor !== undefined && displayColor !== null) {
        this.fail("display.color", "invalidType", "display.color must be a string.");
      }
      const displayUnit = member(display, "unit");
      if (typeof displayUnit === "string") {
        unit = displayUnit;
      } else if (displayUnit !== undefined && displayUnit !== null) {
        this.fail("display.unit", "invalidType", "display.unit must be a string or null.");
      }
      this.unknownFields(display, "display", ["name", "symbol", "color", "unit"]);
    } else {
      this.fail("display", "invalidType", "display must be an object.");
    }

    // Series
    let series: Array<Series> = [];
    let seriesCountIsValid = false;
    const seriesItems = member(input, "series");
    if (seriesItems === undefined || seriesItems === null) {
      this.fail(
        "series",
        "required",
        'series is required: 1 to 4 series, e.g. [{"type": "HKQuantityTypeIdentifierHeartRate"}].',
      );
    } else if (Array.isArray(seriesItems)) {
      seriesCountIsValid = seriesItems.length >= 1 && seriesItems.length <= maxCardSeries;
      if (!seriesCountIsValid) {
        this.fail(
          "series",
          "seriesCount",
          `A card has 1 to 4 series (this one has ${seriesItems.length}).`,
        );
      }
      series = seriesItems.map((item: Json, index) => this.series(item, index));
    } else {
      this.fail("series", "invalidType", "series must be an array of 1 to 4 series.");
    }

    // Formulas
    let formulas: Array<Formula> = [];
    let formulaCountIsValid = true;
    const formulaItems = member(input, "formulas");
    if (Array.isArray(formulaItems)) {
      formulaCountIsValid = formulaItems.length <= maxCardFormulas;
      if (!formulaCountIsValid) {
        this.fail(
          "formulas",
          "formulaCount",
          `A card has at most 2 formulas (this one has ${formulaItems.length}).`,
        );
      }
      formulas = formulaItems.map((item: Json, index) => this.formula(item, index));
    } else if (formulaItems !== undefined && formulaItems !== null) {
      this.fail("formulas", "invalidType", "formulas must be an array of up to 2 formulas.");
    }

    // Bucket and range
    let bucket: CardBucket | undefined;
    const bucketValue = member(input, "bucket");
    if (bucketValue === undefined || bucketValue === null) {
      bucket = "auto";
    } else if (typeof bucketValue === "string") {
      bucket = oneOf(cardBuckets, bucketValue);
      if (bucket === undefined) {
        this.fail(
          "bucket",
          "unknownValue",
          `${quoted(bucketValue)} isn't a bucket. Use ${list(cardBuckets)}.`,
        );
      }
    } else {
      this.fail("bucket", "invalidType", "bucket must be a string.");
    }
    let range: CardRange | undefined;
    let rangeIsExplicit = false;
    const rangeValue = member(input, "range");
    if (rangeValue === undefined || rangeValue === null) {
      range = bucket === undefined ? undefined : defaultRange(bucket);
    } else if (typeof rangeValue === "string") {
      range = oneOf(cardRanges, rangeValue);
      rangeIsExplicit = true;
      if (range === undefined) {
        this.fail(
          "range",
          "unknownValue",
          `${quoted(rangeValue)} isn't a range. Use ${list(cardRanges)}.`,
        );
      }
    } else {
      this.fail("range", "invalidType", "range must be a string.");
    }

    // Chart
    let style: CardChartStyle | undefined;
    let styleIsExplicit = false;
    let goal: Json | undefined;
    let hasGoal = false;
    const chart = member(input, "chart");
    if (isJsonObject(chart)) {
      const styleValue = member(chart, "style");
      if (typeof styleValue === "string") {
        styleIsExplicit = true;
        style = oneOf(cardChartStyles, styleValue);
        if (style === undefined) {
          this.fail(
            "chart.style",
            "unknownValue",
            `${quoted(styleValue)} isn't a chart style. Use ${list(cardChartStyles)}.`,
          );
        }
      } else if (styleValue !== undefined && styleValue !== null) {
        this.fail("chart.style", "invalidType", "chart.style must be a string.");
      }
      const goalValue = member(chart, "goal");
      if (isJsonObject(goalValue)) {
        hasGoal = true;
        const value = member(goalValue, "value");
        if (value === undefined || value === null) {
          this.fail(
            "chart.goal.value",
            "required",
            "chart.goal.value is required: where the goal line is drawn. Or set goal to null.",
          );
        } else {
          goal = value;
        }
        this.unknownFields(goalValue, "chart.goal", ["value"]);
      } else if (goalValue !== undefined && goalValue !== null) {
        this.fail(
          "chart.goal",
          "invalidType",
          'chart.goal must be an object, e.g. {"value": 10000}, or null.',
        );
      }
      this.unknownFields(chart, "chart", ["style", "goal"]);
    } else if (chart !== undefined && chart !== null) {
      this.fail("chart", "invalidType", "chart must be an object.");
    }

    this.unknownFields(input, "", [
      "version",
      "display",
      "series",
      "formulas",
      "bucket",
      "range",
      "chart",
    ]);

    // Defaults from the first visible series' type, or the first series' when every one is
    // hidden: the line the card draws, so a default never fails a rule.
    const first = series.find((item) => !item.hidden) ?? series[0];
    const firstStyle = first?.type?.chartStyle;
    if (
      style === undefined &&
      !styleIsExplicit &&
      firstStyle !== undefined &&
      firstStyle !== null
    ) {
      // A count has no lowest and highest reading to draw.
      style = firstStyle === "ranges" && first?.aggregation === "count" ? "dots" : firstStyle;
    }
    const category = first?.type?.category;
    const look =
      category === undefined || category === null ? undefined : healthCategoryLook(category);
    // A value that was wrong has its error already, so no spec comes of the default.
    symbol ??= look?.symbol;
    color ??= look === undefined ? undefined : oneOf(cardColors, look.color);

    this.checkAcross({
      series,
      formulas,
      seriesCountIsValid,
      formulaCountIsValid,
      bucket,
      range: rangeIsExplicit ? range : undefined,
      style,
      unit,
      goal: hasGoal ? goal : undefined,
    });

    if (
      this.errors.length > 0 ||
      name === undefined ||
      symbol === undefined ||
      color === undefined ||
      bucket === undefined ||
      range === undefined ||
      style === undefined
    ) {
      return undefined;
    }
    return {
      version: cardSpecVersion,
      display: { name, symbol, color, unit: unit ?? null },
      series: series.map((item) => ({
        id: item.id!,
        type: item.type!.id,
        aggregation: item.aggregation!,
        window: item.window ?? null,
        filter: item.filter ?? null,
        label: item.label,
        hidden: item.hidden,
      })),
      formulas: formulas.map((formula) =>
        formula.kind === "movingAverage"
          ? {
              id: formula.id!,
              kind: formula.kind,
              of: formula.of![0]!,
              points: formula.points!,
              label: formula.label,
              hidden: formula.hidden,
            }
          : {
              id: formula.id!,
              kind: formula.kind!,
              of: [formula.of![0]!, formula.of![1]!],
              label: formula.label,
              hidden: formula.hidden,
            },
      ),
      bucket,
      range,
      chart: { style, goal: typeof goal === "number" ? { value: goal } : null },
    };
  }

  private series(item: Json, index: number): Series {
    const path = `series[${index}]`;
    const series: Series = { path, hasWindow: false, label: null, hidden: false };
    if (!isJsonObject(item)) {
      this.fail(
        path,
        "invalidType",
        `${path} must be an object, e.g. {"type": "HKQuantityTypeIdentifierHeartRate"}.`,
      );
      return series;
    }

    series.id = this.id(member(item, "id"), `${path}.id`, seriesID(index));

    const typeValue = member(item, "type");
    if (typeValue === undefined || typeValue === null) {
      this.fail(
        `${path}.type`,
        "required",
        `${path}.type is required: a quantity type, e.g. HKQuantityTypeIdentifierHeartRate or ` +
          '"Heart Rate".',
      );
    } else if (typeof typeValue === "string") {
      series.type = this.type(typeValue, `${path}.type`);
    } else {
      this.fail(
        `${path}.type`,
        "invalidType",
        `${path}.type must be a string: a type's identifier or name.`,
      );
    }
    const type = series.type;

    const aggregation = member(item, "aggregation");
    if (aggregation === undefined || aggregation === null) {
      if (type !== undefined && type.aggregation !== null) {
        series.aggregation = isCumulative(type) ? "sum" : "avg";
      }
    } else if (typeof aggregation === "string") {
      const known = oneOf(cardAggregations, aggregation);
      if (known === undefined) {
        this.fail(
          `${path}.aggregation`,
          "unknownValue",
          `${quoted(aggregation)} isn't an aggregation. Use ${list(cardAggregations)}.`,
        );
      } else if (
        type !== undefined &&
        type.aggregation !== null &&
        isCumulative(type) !== (known === "sum")
      ) {
        this.fail(
          `${path}.aggregation`,
          "aggregationNotAllowed",
          isCumulative(type)
            ? `${type.name} adds up, so it takes "sum" only (avg, min, max, first, latest and count ` +
                "are for types measured at points in time). For an average day over weeks or " +
                'months, use bucket "auto" at 6M or Y.'
            : `${type.name} doesn't add up: use avg, min, max, first, latest or count, not sum.`,
        );
      } else {
        series.aggregation = known;
      }
    } else {
      this.fail(`${path}.aggregation`, "invalidType", `${path}.aggregation must be a string.`);
    }

    const cumulativeName = type !== undefined && isCumulative(type) ? type.name : undefined;
    const window = member(item, "window");
    if (isJsonObject(window)) {
      series.hasWindow = true;
      if (cumulativeName !== undefined) {
        this.fail(
          `${path}.window`,
          "windowOnCumulative",
          "Windows work with types measured at points in time (heart rate, HRV), not ones that " +
            `add up (${cumulativeName}), in this version.`,
        );
      }
      [series.window, series.windowKind] = this.window(window, `${path}.window`);
    } else if (window !== undefined && window !== null) {
      this.fail(
        `${path}.window`,
        "invalidType",
        `${path}.window must be an object, e.g. {"kind": "asleep"}, or null.`,
      );
    }

    const filter = member(item, "filter");
    if (isJsonObject(filter)) {
      if (cumulativeName !== undefined) {
        this.fail(
          `${path}.filter`,
          "filterOnCumulative",
          `Filters work with types measured at points in time, not ${cumulativeName}, which uses ` +
            "Health's de-duplicated totals.",
        );
      }
      series.filter = this.filter(filter, `${path}.filter`);
    } else if (filter !== undefined && filter !== null) {
      this.fail(
        `${path}.filter`,
        "invalidType",
        `${path}.filter must be an object, e.g. {"deviceModels": ["Watch"]}, or null.`,
      );
    }

    series.label = this.label(member(item, "label"), `${path}.label`);
    series.hidden = this.hidden(member(item, "hidden"), `${path}.hidden`);
    this.unknownFields(item, path, [
      "id",
      "type",
      "aggregation",
      "window",
      "filter",
      "label",
      "hidden",
    ]);
    return series;
  }

  private type(name: string, path: string): HealthCatalogType | undefined {
    const type = typeNamed(name);
    if (type === undefined) {
      const close = typeClose(name);
      const suggestion = close === undefined ? "" : ` Did you mean ${close.name} (${close.id})?`;
      this.fail(
        path,
        "unknownType",
        `${quoted(name)} isn't a type lil health knows.${suggestion} list_types lists them.`,
      );
      return undefined;
    }
    if (type.kind !== "quantity") {
      const hint =
        type.id === "HKCategoryTypeIdentifierSleepAnalysis"
          ? ' To chart around sleep, use a window on a quantity, e.g. {"kind": "asleep"}.'
          : type.kind === "workout"
            ? ' To chart during workouts, use a window on a quantity, e.g. {"kind": "workout"}.'
            : "";
      this.fail(
        path,
        "notQuantity",
        `${type.name} isn't a quantity: cards chart quantities such as heart rate or steps.${hint}`,
      );
      return undefined;
    }
    if (type.readAuthorization !== "standard") {
      this.fail(
        path,
        "unreadableType",
        `${type.name} can't be read from Health by apps, so cards can't chart it.`,
      );
      return undefined;
    }
    return type;
  }

  private window(
    json: JsonObject,
    path: string,
  ): [JsonObject | undefined, CardWindowKind | undefined] {
    let kind: CardWindowKind | undefined;
    const kindValue = member(json, "kind");
    if (kindValue === undefined || kindValue === null) {
      this.fail(`${path}.kind`, "required", `${path}.kind is required: ${list(cardWindowKinds)}.`);
    } else if (typeof kindValue === "string") {
      kind = oneOf(cardWindowKinds, kindValue);
      if (kind === undefined) {
        this.fail(
          `${path}.kind`,
          "unknownValue",
          `${quoted(kindValue)} isn't a window. Use ${list(cardWindowKinds)}.`,
        );
      }
    } else {
      this.fail(`${path}.kind`, "invalidType", `${path}.kind must be a string.`);
    }

    let window: JsonObject | undefined;
    let allowed: ReadonlyArray<string>;
    switch (kind) {
      case "asleep":
        window = { kind };
        allowed = ["kind"];
        break;
      case "beforeSleep":
      case "afterWaking": {
        allowed = ["kind", "minutes"];
        const event = kind === "beforeSleep" ? "before falling asleep" : "after waking";
        const minutes = member(json, "minutes");
        if (minutes === undefined || minutes === null) {
          this.fail(
            `${path}.minutes`,
            "required",
            `${path}.minutes is required: how many minutes ${event}, from 1 to 240.`,
          );
        } else if (typeof minutes === "number" && isWhole(minutes, 1, 240)) {
          window = { kind, minutes };
        } else {
          this.fail(
            `${path}.minutes`,
            "windowMinutes",
            `${path}.minutes must be a whole number from 1 to 240.`,
          );
        }
        break;
      }
      case "workout": {
        allowed = ["kind", "activities"];
        const activities = member(json, "activities");
        if (activities === undefined || activities === null) {
          window = { kind, activities: null };
        } else if (Array.isArray(activities)) {
          const known = this.activities(activities, `${path}.activities`);
          if (known !== undefined) window = { kind, activities: known };
        } else {
          this.fail(
            `${path}.activities`,
            "invalidType",
            `${path}.activities must be an array of workout activities, or null for every workout.`,
          );
        }
        break;
      }
      case "timeOfDay": {
        allowed = ["kind", "from", "to"];
        const time = (key: "from" | "to", what: string) => {
          const timePath = `${path}.${key}`;
          const value = member(json, key);
          if (value === undefined || value === null) {
            this.fail(
              timePath,
              "required",
              `${timePath} is required: ${what}, on the 24-hour clock, e.g. ` +
                `"${key === "from" ? "07:30" : "12:00"}".`,
            );
            return undefined;
          }
          const minutes = typeof value === "string" ? clockTime(value) : undefined;
          if (minutes !== undefined) return minutes;
          this.fail(
            timePath,
            "windowTime",
            `${timePath} must be a time on the 24-hour clock, "HH:MM" from "00:00" to "23:59" ` +
              `(it's ${jsonText(value)}).`,
          );
          return undefined;
        };
        const from = time("from", "when the window starts");
        const to = time("to", "when it ends");
        if (from !== undefined && to !== undefined) {
          if (from === to) {
            this.fail(
              path,
              "windowTime",
              `${path} starts and ends at ${clockText(from)}: for every reading, set window to ` +
                'null. A window may cross midnight, e.g. from "22:00" to "06:00".',
            );
          } else {
            window = { kind, from: clockText(from), to: clockText(to) };
          }
        }
        break;
      }
      default:
        allowed = ["kind", "minutes", "activities", "from", "to"];
    }
    this.unknownFields(json, path, allowed);
    return [window, kind];
  }

  private activities(items: ReadonlyArray<Json>, path: string): Array<number> | undefined {
    const errorCount = this.errors.length;
    if (items.length < 1 || items.length > 10) {
      this.fail(
        path,
        "activityCount",
        `${path} must have 1 to 10 activities (it has ${items.length}), or be null for every workout.`,
      );
    }
    const activities: Array<number> = [];
    items.forEach((item, index) => {
      let activity: number | undefined;
      if (typeof item === "number") {
        if (Number.isInteger(item) && Math.abs(item) < 1e9 && activityNames.has(item)) {
          activity = item;
        }
      } else if (typeof item === "string") {
        const wanted = item.toLowerCase();
        activity = workoutActivities.find(
          ({ name }) => name.toLowerCase() === wanted,
        )?.activityType;
      }
      if (activity === undefined) {
        this.fail(
          `${path}[${index}]`,
          "unknownActivity",
          `${jsonText(item)} isn't a workout activity. Use HKWorkoutActivityType raw values or ` +
            'names, e.g. 37 or "Running".',
        );
        return;
      }
      if (activities.includes(activity)) {
        this.fail(
          `${path}[${index}]`,
          "duplicateActivity",
          `${path} has ${workoutActivityName(activity)} twice.`,
        );
      }
      activities.push(activity);
    });
    return this.errors.length === errorCount ? activities : undefined;
  }

  private filter(json: JsonObject, path: string): JsonObject | undefined {
    const errorCount = this.errors.length;
    const filterList = (key: "sources" | "deviceModels") => {
      const listPath = `${path}.${key}`;
      const items = member(json, key);
      if (items === undefined || items === null) return null;
      if (!Array.isArray(items)) {
        this.fail(listPath, "invalidType", `${listPath} must be an array of strings, or null.`);
        return null;
      }
      if (items.length < 1 || items.length > 10) {
        this.fail(
          listPath,
          "filterList",
          `${listPath} must have 1 to 10 entries (it has ${items.length}), or be null.`,
        );
      }
      return items.flatMap((item: Json, index) => {
        if (typeof item === "string") {
          const length = codePointCount(item);
          if (length >= 1 && length <= 200) return [item];
        }
        this.fail(
          `${listPath}[${index}]`,
          "filterValue",
          `${listPath}[${index}] must be a string of 1 to 200 characters.`,
        );
        return [];
      });
    };
    const sources = filterList("sources");
    const deviceModels = filterList("deviceModels");
    const absent = (key: string) => {
      const value = member(json, key);
      return value === undefined || value === null;
    };
    if (absent("sources") && absent("deviceModels")) {
      this.fail(
        path,
        "emptyFilter",
        "A filter needs sources or deviceModels. For every source, set filter to null.",
      );
    }
    this.unknownFields(json, path, ["sources", "deviceModels"]);
    return this.errors.length === errorCount ? { sources, deviceModels } : undefined;
  }

  private formula(item: Json, index: number): Formula {
    const path = `formulas[${index}]`;
    const formula: Formula = { path, label: null, hidden: false };
    if (!isJsonObject(item)) {
      this.fail(
        path,
        "invalidType",
        `${path} must be an object, e.g. {"kind": "movingAverage", "of": "a", "points": 7}.`,
      );
      return formula;
    }
    formula.id = this.id(member(item, "id"), `${path}.id`, `f${index + 1}`);

    const kind = member(item, "kind");
    if (kind === undefined || kind === null) {
      this.fail(
        `${path}.kind`,
        "required",
        `${path}.kind is required: movingAverage or difference.`,
      );
    } else if (typeof kind === "string") {
      formula.kind = oneOf(cardFormulaKinds, kind);
      if (formula.kind === undefined) {
        this.fail(
          `${path}.kind`,
          "unknownValue",
          `${quoted(kind)} isn't a formula. Use movingAverage or difference.`,
        );
      }
    } else {
      this.fail(`${path}.kind`, "invalidType", `${path}.kind must be a string.`);
    }

    let allowed: ReadonlyArray<string>;
    const of = member(item, "of");
    switch (formula.kind) {
      case "movingAverage": {
        allowed = ["id", "kind", "of", "points", "label", "hidden"];
        if (of === undefined || of === null) {
          this.fail(
            `${path}.of`,
            "required",
            `${path}.of is required: the id of the series it averages, e.g. "a".`,
          );
        } else if (typeof of === "string") {
          formula.of = [of];
        } else {
          this.fail(`${path}.of`, "invalidType", `${path}.of must be a series' id, e.g. "a".`);
        }
        const pointsValue = member(item, "points");
        if (pointsValue === undefined || pointsValue === null) {
          formula.points = 7;
        } else if (typeof pointsValue === "number" && isWhole(pointsValue, 2, 30)) {
          formula.points = pointsValue;
        } else {
          this.fail(
            `${path}.points`,
            "formulaPoints",
            `${path}.points must be a whole number from 2 to 30.`,
          );
        }
        break;
      }
      case "difference":
        allowed = ["id", "kind", "of", "label", "hidden"];
        if (of === undefined || of === null) {
          this.fail(
            `${path}.of`,
            "required",
            `${path}.of is required: the ids of the two series it subtracts, e.g. ["a", "b"].`,
          );
        } else if (
          Array.isArray(of) &&
          of.length === 2 &&
          of.every((id: Json) => typeof id === "string")
        ) {
          formula.of = of as ReadonlyArray<string>;
        } else {
          this.fail(
            `${path}.of`,
            "invalidType",
            `${path}.of must be two series' ids, e.g. ["a", "b"]: the first minus the second.`,
          );
        }
        break;
      default:
        allowed = ["id", "kind", "of", "points", "label", "hidden"];
    }

    formula.label = this.label(member(item, "label"), `${path}.label`);
    formula.hidden = this.hidden(member(item, "hidden"), `${path}.hidden`);
    this.unknownFields(item, path, allowed);
    return formula;
  }

  // MARK: - Fields

  private id(json: Json | undefined, path: string, fallback: string): string | undefined {
    if (json === undefined || json === null) return fallback;
    if (typeof json === "string") {
      if (validID.test(json)) return json;
      this.fail(
        path,
        "invalidID",
        `${path} must be a lowercase letter, then up to 15 lowercase letters or digits, e.g. ` +
          `"a" or "trend" (it's ${quoted(json)}).`,
      );
      return undefined;
    }
    this.fail(path, "invalidType", `${path} must be a string, e.g. "a".`);
    return undefined;
  }

  /** A name or label: trimmed, 1 to 40 code points, no line breaks or control characters. */
  private text(
    text: string,
    path: string,
    code: CardSpecErrorCode,
    orNull: boolean,
  ): string | undefined {
    const value = trimmed(text);
    const length = codePointCount(value);
    if (length < 1 || length > 40) {
      this.fail(
        path,
        code,
        `${path} must be 1 to 40 characters (it's ${length})${orNull ? ", or null" : ""}.`,
      );
      return undefined;
    }
    if (codePoints(value).some((point) => isForbidden(point.codePointAt(0)!))) {
      this.fail(path, "invalidCharacters", `${path} can't have line breaks or control characters.`);
      return undefined;
    }
    return value;
  }

  private label(json: Json | undefined, path: string): string | null {
    if (json === undefined || json === null) return null;
    if (typeof json === "string") return this.text(json, path, "labelLength", true) ?? null;
    this.fail(path, "invalidType", `${path} must be a string or null.`);
    return null;
  }

  private hidden(json: Json | undefined, path: string): boolean {
    if (json === undefined || json === null) return false;
    if (typeof json === "boolean") return json;
    this.fail(path, "invalidType", `${path} must be true or false.`);
    return false;
  }

  private unknownFields(json: JsonObject, path: string, allowed: ReadonlyArray<string>) {
    const unknown = Object.keys(json)
      .filter((key) => !allowed.includes(key))
      .sort();
    for (const key of unknown) {
      this.fail(
        path === "" ? key : `${path}.${key}`,
        "unknownField",
        `Unknown field ${quoted(key)} in ${path === "" ? "the spec" : path}. Allowed: ` +
          `${allowed.join(", ")}.`,
      );
    }
  }

  // MARK: - Across fields

  private checkAcross(options: {
    readonly series: ReadonlyArray<Series>;
    readonly formulas: ReadonlyArray<Formula>;
    readonly seriesCountIsValid: boolean;
    readonly formulaCountIsValid: boolean;
    readonly bucket: CardBucket | undefined;
    readonly range: CardRange | undefined;
    readonly style: CardChartStyle | undefined;
    readonly unit: string | undefined;
    readonly goal: Json | undefined;
  }) {
    const { series, formulas, bucket, range, style, unit, goal } = options;

    // IDs
    const seen = new Map<string, boolean>(); // id: whether it's a series'
    for (const [path, id, isSeries] of [
      ...series.map((item) => [`${item.path}.id`, item.id, true] as const),
      ...formulas.map((item) => [`${item.path}.id`, item.id, false] as const),
    ]) {
      if (id === undefined) continue;
      const wasSeries = seen.get(id);
      if (wasSeries === undefined) {
        seen.set(id, isSeries);
      } else {
        this.fail(
          path,
          "duplicateID",
          `${quoted(id)} is already a ${wasSeries ? "series'" : "formula's"} id. Each series and ` +
            "formula needs its own.",
        );
      }
    }

    // References
    const seriesByID = new Map<string, Series>();
    for (const item of series) {
      if (item.id !== undefined && !seriesByID.has(item.id)) seriesByID.set(item.id, item);
    }
    const formulaIDs = new Set(formulas.flatMap((formula) => formula.id ?? []));
    const formulaUnits: Array<ValueUnit | undefined> = [];
    for (const formula of formulas) {
      const of = formula.of;
      if (of === undefined) {
        formulaUnits.push(undefined);
        continue;
      }
      const resolved: Array<Series> = [];
      for (const id of of) {
        const item = seriesByID.get(id);
        if (item !== undefined) {
          resolved.push(item);
        } else {
          const note = formulaIDs.has(id) ? " Formulas take series only." : "";
          this.fail(
            `${formula.path}.of`,
            "unknownReference",
            `${formula.path} refers to ${quoted(id)}, which isn't a series of this card.${note}`,
          );
        }
      }
      const a = resolved[0] === undefined ? undefined : seriesUnit(resolved[0]);
      const b = resolved[1] === undefined ? undefined : seriesUnit(resolved[1]);
      if (formula.kind === "difference" && of.length === 2 && of[0] === of[1]) {
        this.fail(
          `${formula.path}.of`,
          "sameSeries",
          `${formula.path} subtracts ${quoted(of[0]!)} from itself: name two different series.`,
        );
      } else if (
        formula.kind === "difference" &&
        resolved.length === 2 &&
        a !== undefined &&
        b !== undefined &&
        !sameUnit(a, b)
      ) {
        this.fail(
          `${formula.path}.of`,
          "mixedUnits",
          `${formula.path} subtracts ${describeSeries(resolved[1]!)} from ` +
            `${describeSeries(resolved[0]!)}: both need the same unit.`,
        );
      }
      formulaUnits.push(resolved.length === of.length ? a : undefined);
    }

    // One axis
    const visible: Array<Line> = [
      ...series.filter((item) => !item.hidden).map((item): Line => ({ series: item })),
      ...formulas.flatMap((formula, index): Array<Line> =>
        formula.hidden ? [] : [{ formula, unit: formulaUnits[index] }],
      ),
    ];
    const lead = visible[0];
    const leadUnit = lead === undefined ? undefined : lineUnit(lead);
    if (lead !== undefined && leadUnit !== undefined) {
      for (const line of visible.slice(1)) {
        const otherUnit = lineUnit(line);
        if (otherUnit === undefined || sameUnit(otherUnit, leadUnit)) continue;
        const path =
          line.series === undefined ? `${line.formula.path}.of` : `${line.series.path}.type`;
        this.fail(
          path,
          "mixedUnits",
          `${capitalized(describeLine(line))} can't share a card with ${describeLine(lead)}: a ` +
            "card has one axis. Make it a card of its own.",
        );
      }
    }

    // Visible lines
    if (series.length > 0 && visible.length === 0) {
      this.fail(
        "series",
        "nothingVisible",
        "Every series and formula is hidden: leave at least one visible.",
      );
    }
    if (
      options.seriesCountIsValid &&
      options.formulaCountIsValid &&
      visible.length > maxCardVisibleLines
    ) {
      this.fail(
        "formulas",
        "visibleCount",
        `A card shows at most 4 lines (series and formulas); this one has ${visible.length}.`,
      );
    }

    // Buckets
    const sleepWindows = series.some((item) => isSleepWindow(item.windowKind));
    const unknownWindows = series.some((item) => item.hasWindow && item.windowKind === undefined);
    if (bucket === "night" && !sleepWindows && !unknownWindows) {
      this.fail(
        "bucket",
        "nightNeedsSleepWindow",
        'bucket "night" needs a series with a sleep window: {"kind": "asleep"}, ' +
          '"beforeSleep" or "afterWaking".',
      );
    }
    if (bucket !== undefined && sleepWindows && ["auto", "hour", "day"].includes(bucket)) {
      this.fail(
        "bucket",
        "sleepWindowBucket",
        'Sleep windows need bucket "night", "week" or "month": an hour or a calendar day ' +
          "would cut nights in two.",
      );
    }
    if (bucket !== undefined && range !== undefined && !bucketRanges[bucket].includes(range)) {
      this.fail(
        "range",
        "rangeNotForBucket",
        `range ${quoted(range)} doesn't fit bucket ${quoted(bucket)} (${points(bucket, range)}). ` +
          `Ranges for ${quoted(bucket)}: ${bucketRanges[bucket].join(", ")}.`,
      );
    }

    // Chart style
    if (style === "ranges") {
      const total = visible.find(
        (line) => line.series?.aggregation === "sum" || line.series?.aggregation === "count",
      )?.series;
      if (total !== undefined) {
        const what =
          total.aggregation === "sum"
            ? `${total.type?.name ?? "it"} is a total`
            : `${describeSeries(total)} has none`;
        this.fail(
          "chart.style",
          "rangesStyle",
          `"ranges" draws each bucket's lowest and highest reading, and ${what}. Use bars, dots ` +
            "or line.",
        );
      }
    }

    // Display unit
    if (unit !== undefined && lead !== undefined && leadUnit !== undefined) {
      const dimension =
        "catalog" in leadUnit
          ? cardDisplayUnitDimensions.find(({ catalogUnits }) =>
              catalogUnits.includes(leadUnit.catalog),
            )
          : undefined;
      if (dimension === undefined) {
        this.fail(
          "display.unit",
          "unitDimension",
          `${quoted(unit)} isn't a unit for ${describeLine(lead)}, which has no others: use null.`,
        );
      } else if (!dimension.units.includes(unit)) {
        this.fail(
          "display.unit",
          "unitDimension",
          `${quoted(unit)} isn't a unit for ${describeLine(lead)}. Use ${list(dimension.units)}, ` +
            "or null for the locale's.",
        );
      }
    }

    // Goal
    if (goal !== undefined) {
      const isValid = typeof goal === "number" && goal >= 0 && Number.isFinite(goal);
      if (!isValid) {
        let goalUnit = "";
        if (lead?.series !== undefined) {
          const valueUnit = seriesUnit(lead.series);
          if (valueUnit !== undefined) {
            goalUnit =
              "readings" in valueUnit
                ? `, in readings (${describeSeries(lead.series)})`
                : `, in ${valueUnit.catalog} (${lead.series.type?.name ?? ""}'s unit)`;
          }
        } else if (lead?.formula !== undefined && lead.unit !== undefined) {
          goalUnit = `, in ${"readings" in lead.unit ? "readings" : lead.unit.catalog} (${lead.formula.path}'s unit)`;
        }
        this.fail(
          "chart.goal.value",
          "goalValue",
          `chart.goal.value must be a number of at least 0${goalUnit}.`,
        );
      }
    }
  }
}
