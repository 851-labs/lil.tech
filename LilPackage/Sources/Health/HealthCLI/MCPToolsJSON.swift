// Generated from Services/api/mcp-tools.json by Services/api/scripts/mcp-tools.ts. Don't edit:
// run scripts/format.

/// The Health toolkit's tools as an MCP server lists them (`Services/api/mcp-tools.json`).
let mcpToolsJSON = #"""
[
  {
    "name": "summary",
    "description": "Start here. An overview of the person's Apple Health data, as lil health's Summary shows it: for each everyday metric (steps, heart rate, active energy, walking + running distance, resting heart rate, weight), the latest sample and, for types that add up, today's and the last 7 days' totals; plus the workouts of the last 7 days (today and the 6 days before).",
    "inputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "date": {
          "type": "string",
          "description": "Today."
        },
        "pinned": {
          "type": "boolean",
          "description": "Deprecated: always false. lil health no longer has pinned metrics, so `metrics` are always the everyday ones."
        },
        "metrics": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthSummaryMetric"
          },
          "description": "The metrics, in the order Summary shows them."
        },
        "workouts": {
          "type": "object",
          "properties": {
            "count": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991
            },
            "duration": {
              "type": "number",
              "description": "Seconds of activity, excluding pauses."
            }
          },
          "required": [
            "count",
            "duration"
          ],
          "additionalProperties": true,
          "description": "Workouts that started today (by now) or in the 6 days before."
        }
      },
      "required": [
        "timeZone",
        "date",
        "pinned",
        "metrics",
        "workouts"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthSummaryMetric": {
          "type": "object",
          "properties": {
            "type": {
              "type": "string",
              "description": "A HealthKit type identifier, e.g. HKQuantityTypeIdentifierStepCount or HKCategoryTypeIdentifierSleepAnalysis. list_types and search return them."
            },
            "unit": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The HealthKit unit of the values, e.g. count, kcal or count/min. Null for category types."
            },
            "latest": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "start": {
                      "type": "string",
                      "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
                    },
                    "end": {
                      "type": "string",
                      "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
                    },
                    "value": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "A quantity's value, in `unit`. Null for category types."
                    },
                    "categoryValue": {
                      "anyOf": [
                        {
                          "type": "integer",
                          "minimum": -9007199254740991,
                          "maximum": 9007199254740991
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "A category sample's HealthKit value (HKCategoryValue…). Null for quantities."
                    }
                  },
                  "required": [
                    "start",
                    "end",
                    "value",
                    "categoryValue"
                  ],
                  "additionalProperties": true
                },
                {
                  "type": "null"
                }
              ],
              "description": "The most recent sample that has started, or null if there's none."
            },
            "today": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For types that add up (steps, energy, distance): today's total, as Health counts it. Null for other types, or with nothing recorded today."
            },
            "last7Days": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For types that add up: the total over today and the 6 days before. Null for other types, or with nothing recorded in those days."
            }
          },
          "required": [
            "type",
            "unit",
            "latest",
            "today",
            "last7Days"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Summary",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Summary"
  },
  {
    "name": "list_types",
    "description": "Lists the kinds of Health data the person has (only types with data), with each type's identifier, name, category, unit and date range. Use the identifiers with metric and samples.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "types": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthTypeInfo"
          },
          "description": "Every type with data, by category, then name."
        }
      },
      "required": [
        "timeZone",
        "types"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthTypeInfo": {
          "type": "object",
          "properties": {
            "type": {
              "type": "string",
              "description": "A HealthKit type identifier, e.g. HKQuantityTypeIdentifierStepCount or HKCategoryTypeIdentifierSleepAnalysis. list_types and search return them."
            },
            "name": {
              "type": "string",
              "description": "The name Health shows, e.g. Steps."
            },
            "category": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The Browse category, e.g. Activity or Heart. Null for characteristics."
            },
            "kind": {
              "type": "string",
              "description": "What kind of data it is: quantity, category, workout, medication, electrocardiogram…"
            },
            "unit": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "A quantity type's HealthKit unit, e.g. count/min. Null for other kinds."
            },
            "cumulative": {
              "type": "boolean",
              "description": "Whether values add up (steps, energy), so metric's default statistic is a sum rather than an average."
            },
            "first": {
              "type": "string",
              "description": "When the earliest record starts."
            },
            "last": {
              "type": "string",
              "description": "When the latest record starts."
            }
          },
          "required": [
            "type",
            "name",
            "category",
            "kind",
            "unit",
            "cumulative",
            "first",
            "last"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "List Health Data Types",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "List Health Data Types"
  },
  {
    "name": "metric",
    "description": "A quantity type's statistic over a period, overall and per hour, day, week or month, computed as Health does: totals of types that add up come from the iPhone's own statistics (so iPhone and Watch steps aren't counted twice), and averages follow the type's style (heart rate is weighted by time), with each value of a series (an Apple Watch's heart rate in a workout) counted at its own time. Prefer this to samples.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "type": {
          "type": "string",
          "description": "A HealthKit type identifier, e.g. HKQuantityTypeIdentifierStepCount or HKCategoryTypeIdentifierSleepAnalysis. list_types and search return them."
        },
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day weeks; Y the 12 calendar months ending with that day's month, in months (the last one ends with `date`)."
        },
        "statistic": {
          "type": "string",
          "enum": [
            "sum",
            "average",
            "minimum",
            "maximum"
          ],
          "description": "Defaults to sum for types that add up (steps, energy), and average for others."
        },
        "date": {
          "type": "string",
          "description": "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to today."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "type",
        "range"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "range": {
          "type": "string",
          "description": "The range asked for: D, W, M, 6M or Y."
        },
        "start": {
          "type": "string",
          "description": "When the period starts."
        },
        "end": {
          "type": "string",
          "description": "When the period ends (exclusive)."
        },
        "type": {
          "type": "string",
          "description": "A HealthKit type identifier, e.g. HKQuantityTypeIdentifierStepCount or HKCategoryTypeIdentifierSleepAnalysis. list_types and search return them."
        },
        "unit": {
          "anyOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ],
          "description": "The values' HealthKit unit."
        },
        "statistic": {
          "type": "string",
          "description": "The statistic: sum, average, minimum or maximum."
        },
        "value": {
          "anyOf": [
            {
              "type": "number"
            },
            {
              "type": "null"
            }
          ],
          "description": "The statistic over the whole period, or null without data."
        },
        "buckets": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthMetricBucket"
          },
          "description": "The period's hours, days, weeks or months, oldest first."
        }
      },
      "required": [
        "timeZone",
        "range",
        "start",
        "end",
        "type",
        "unit",
        "statistic",
        "value",
        "buckets"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthMetricBucket": {
          "type": "object",
          "properties": {
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "value": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The statistic over the bucket, in `unit`, or null without data."
            }
          },
          "required": [
            "start",
            "value"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Metric",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Metric"
  },
  {
    "name": "samples",
    "description": "Individual samples of a quantity, category or correlation type (blood pressure, food) in a period, newest first, a page at a time, each with its source app and device (listed once a page, in sources) and what its metadata says (how and where it was measured, whether it was entered by hand), fields only when HealthKit has them. A type can have many thousands of samples a day: use metric for totals and trends, and this only to look at particular readings. A series (an Apple Watch's heart rate in a workout) is one sample with its count and summary, or its values with seriesValues. Workouts, Activity rings, State of Mind, GAD-7 and PHQ-9 assessments, medications, their doses and health details have their own tools.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "type": {
          "type": "string",
          "description": "A HealthKit type identifier, e.g. HKQuantityTypeIdentifierStepCount or HKCategoryTypeIdentifierSleepAnalysis. list_types and search return them."
        },
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day weeks; Y the 12 calendar months ending with that day's month, in months (the last one ends with `date`)."
        },
        "date": {
          "type": "string",
          "description": "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to today."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        },
        "cursor": {
          "type": "string",
          "description": "The previous page's nextCursor."
        },
        "limit": {
          "type": "integer",
          "minimum": 1,
          "maximum": 500,
          "description": "Samples per page, at most 500. Defaults to 100."
        },
        "seriesValues": {
          "type": "boolean",
          "description": "List each quantity series' values, newest first, in place of the series, each counting toward the limit; a page can end inside a series. Defaults to false."
        }
      },
      "required": [
        "type",
        "range"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "range": {
          "type": "string",
          "description": "The range asked for: D, W, M, 6M or Y."
        },
        "start": {
          "type": "string",
          "description": "When the period starts."
        },
        "end": {
          "type": "string",
          "description": "When the period ends (exclusive)."
        },
        "type": {
          "type": "string",
          "description": "A HealthKit type identifier, e.g. HKQuantityTypeIdentifierStepCount or HKCategoryTypeIdentifierSleepAnalysis. list_types and search return them."
        },
        "samples": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthSampleItem"
          },
          "description": "Samples that start in the period, newest first."
        },
        "sources": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthSampleSource"
          },
          "description": "Where this page's samples came from, each app and device once, in the order they first appear: a sample's sourceIndex is its entry."
        },
        "nextCursor": {
          "anyOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ],
          "description": "Pass it as `cursor` for the next, older page; null on the last page."
        }
      },
      "required": [
        "timeZone",
        "range",
        "start",
        "end",
        "type",
        "samples",
        "sources",
        "nextCursor"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthSampleSeries": {
          "type": "object",
          "properties": {
            "count": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "How many values the series has."
            },
            "index": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "With seriesValues: which of the series' values this item is, from 0, the earliest. Left out for a series whose values weren't uploaded (more than 20,000), listed as one sample."
            },
            "minimum": {
              "type": "number",
              "description": "A discrete series' lowest value (heart rate), in `unit`."
            },
            "maximum": {
              "type": "number",
              "description": "Its highest value."
            },
            "mostRecent": {
              "type": "number",
              "description": "Its last value."
            },
            "mostRecentStart": {
              "type": "string",
              "description": "When its last value starts."
            },
            "mostRecentEnd": {
              "type": "string",
              "description": "When its last value ends."
            }
          },
          "required": [
            "count"
          ],
          "additionalProperties": true,
          "description": "Only for a quantity series, a sample of many values: its count and summary, or which of its values this item is."
        },
        "HealthCorrelatedValue": {
          "type": "object",
          "properties": {
            "type": {
              "type": "string",
              "description": "A HealthKit type identifier, e.g. HKQuantityTypeIdentifierStepCount or HKCategoryTypeIdentifierSleepAnalysis. list_types and search return them."
            },
            "value": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Its value, in `unit`."
            },
            "unit": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ]
            }
          },
          "required": [
            "type",
            "value",
            "unit"
          ],
          "additionalProperties": true
        },
        "HealthSampleItem": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "HealthKit's UUID for the sample."
            },
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "end": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "recordedTimeZone": {
              "type": "string",
              "description": "The time zone it was recorded in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo, as an IANA name. Left out when it has none, or one that isn't an IANA name. Its other times stay in the output's `timeZone`, so they compare across records."
            },
            "recordedStart": {
              "type": "string",
              "description": "When it starts, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "recordedEnd": {
              "type": "string",
              "description": "When it ends, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "value": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "A quantity's value, in `unit`: for a series, HealthKit's for all of it, its total or its time-weighted average. Null for category types and correlations."
            },
            "unit": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ]
            },
            "categoryValue": {
              "anyOf": [
                {
                  "type": "integer",
                  "minimum": -9007199254740991,
                  "maximum": 9007199254740991
                },
                {
                  "type": "null"
                }
              ],
              "description": "A category sample's HealthKit value (HKCategoryValue…). Null for quantities and correlations."
            },
            "source": {
              "type": "string",
              "description": "The app or device that recorded it, e.g. an Apple Watch's name."
            },
            "sourceIndex": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "Its entry in `sources`: the app, its version and the device, from 0."
            },
            "series": {
              "$ref": "#/$defs/HealthSampleSeries"
            },
            "userEntered": {
              "type": "boolean",
              "description": "True if someone entered it by hand, e.g. in the Health app (HKMetadataKeyWasUserEntered)."
            },
            "values": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthCorrelatedValue"
              },
              "description": "For a correlation (blood pressure, food): the samples it groups, by type, e.g. systolic and diastolic, or each nutrient of a food."
            },
            "food": {
              "type": "string",
              "description": "A food's name (HKMetadataKeyFoodType)."
            },
            "motionContext": {
              "type": "string",
              "description": "Heart rate: sedentary (still) or active (moving or working out) (HKMetadataKeyHeartRateMotionContext)."
            },
            "userMotionContext": {
              "type": "string",
              "description": "stationary or active, how the person was moving (HKMetadataKeyUserMotionContext)."
            },
            "sensorLocation": {
              "type": "string",
              "description": "Where it was measured: for heart rate chest, wrist, finger, hand, earLobe, foot or other (HKMetadataKeyHeartRateSensorLocation); for body temperature armpit, body, ear, finger, gastroIntestinal, mouth, rectum, toe, earDrum, temporalArtery, forehead or other (HKMetadataKeyBodyTemperatureSensorLocation)."
            },
            "mealTime": {
              "type": "string",
              "description": "Blood glucose: preprandial (before a meal) or postprandial (after one) (HKMetadataKeyBloodGlucoseMealTime)."
            },
            "insulinDeliveryReason": {
              "type": "string",
              "description": "Insulin: basal or bolus (HKMetadataKeyInsulinDeliveryReason)."
            },
            "vo2MaxTestType": {
              "type": "string",
              "description": "Cardio fitness: how it was measured, maxExercise, predictionSubMaxExercise, predictionNonExercise or predictionStepTest (HKMetadataKeyVO2MaxTestType). Apple Watch's estimates are predictionSubMaxExercise."
            },
            "vo2Max": {
              "type": "number",
              "description": "A low cardio fitness event's VO2 max, in mL/(kg·min) (HKMetadataKeyVO2MaxValue)."
            },
            "lowCardioFitnessThreshold": {
              "type": "number",
              "description": "The VO2 max under which cardio fitness counted as low, in mL/(kg·min) (HKMetadataKeyLowCardioFitnessEventThreshold)."
            },
            "heartRateEventThreshold": {
              "type": "number",
              "description": "A high or low heart rate event's threshold, in beats per minute (HKMetadataKeyHeartRateEventThreshold)."
            },
            "heartRateRecoveryTestType": {
              "type": "string",
              "description": "Cardio recovery: maxExercise, predictionSubMaxExercise, predictionNonExercise or stepTest (HKMetadataKeyHeartRateRecoveryTestType)."
            },
            "heartRateRecoveryActivity": {
              "type": "string",
              "description": "Cardio recovery: the workout activity before it, e.g. Running (HKMetadataKeyHeartRateRecoveryActivityType)."
            },
            "heartRateRecoveryActivityDuration": {
              "type": "number",
              "description": "Cardio recovery: seconds of that activity (HKMetadataKeyHeartRateRecoveryActivityDuration)."
            },
            "maxObservedRecoveryHeartRate": {
              "type": "number",
              "description": "Cardio recovery: the highest heart rate seen, in beats per minute (HKMetadataKeyHeartRateRecoveryMaxObservedRecoveryHeartRate)."
            },
            "audioExposureLevel": {
              "type": "number",
              "description": "A noise or headphone audio event's level, in dB(A) SPL (HKMetadataKeyAudioExposureLevel)."
            },
            "audioExposureDuration": {
              "type": "number",
              "description": "Seconds of headphone audio it covers (HKMetadataKeyAudioExposureDuration)."
            },
            "headphoneGain": {
              "type": "number",
              "description": "A headphone audio event's gain, in dB(A) SPL (HKMetadataKeyHeadphoneGain)."
            },
            "physicalEffortEstimationType": {
              "type": "string",
              "description": "Physical effort: activityLookup or deviceSensed (HKMetadataKeyPhysicalEffortEstimationType)."
            },
            "activity": {
              "type": "string",
              "description": "The workout activity it was during, e.g. Hiking (HKMetadataKeyActivityType)."
            },
            "placementSide": {
              "type": "string",
              "description": "Where the iPhone was carried while walking: left, right or central (HKMetadataKeyDevicePlacementSide)."
            },
            "deviceCalibrated": {
              "type": "boolean",
              "description": "Whether the device had enough calibration data for it (HKMetadataKeyAppleDeviceCalibrated)."
            },
            "algorithmVersion": {
              "type": "number",
              "description": "The version of the algorithm that estimated it (HKMetadataKeyAlgorithmVersion)."
            },
            "earliestDataUsedForEstimate": {
              "type": "string",
              "description": "How far back the estimate's data goes (HKMetadataKeyDateOfEarliestDataUsedForEstimate)."
            },
            "clampedToLowerBound": {
              "type": "boolean",
              "description": "True if the value was raised to the lowest the sensor reports (HKMetadataKeyQuantityClampedToLowerBound)."
            },
            "clampedToUpperBound": {
              "type": "boolean",
              "description": "True if the value was lowered to the highest the sensor reports (HKMetadataKeyQuantityClampedToUpperBound)."
            },
            "referenceRangeLowerLimit": {
              "type": "number",
              "description": "A lab result's reference range's lower limit (HKMetadataKeyReferenceRangeLowerLimit)."
            },
            "referenceRangeUpperLimit": {
              "type": "number",
              "description": "A lab result's reference range's upper limit (HKMetadataKeyReferenceRangeUpperLimit)."
            },
            "takenInLab": {
              "type": "boolean",
              "description": "Whether it was taken in a lab (HKMetadataKeyWasTakenInLab)."
            },
            "waterSalinity": {
              "type": "string",
              "description": "Underwater depth or water temperature: freshWater or saltWater (HKMetadataKeyWaterSalinity)."
            },
            "maximumLightIntensity": {
              "type": "number",
              "description": "Time in daylight: the brightest light, in lux (HKMetadataKeyMaximumLightIntensity)."
            },
            "menstrualCycleStart": {
              "type": "boolean",
              "description": "Menstrual flow: whether it started a cycle (HKMetadataKeyMenstrualCycleStart)."
            },
            "protectionUsed": {
              "type": "boolean",
              "description": "Sexual activity: whether protection was used (HKMetadataKeySexualActivityProtectionUsed)."
            }
          },
          "required": [
            "id",
            "start",
            "end",
            "value",
            "unit",
            "categoryValue",
            "source",
            "sourceIndex"
          ],
          "additionalProperties": true
        },
        "HealthSampleDevice": {
          "type": "object",
          "properties": {
            "name": {
              "type": "string",
              "description": "The device's name, e.g. Apple Watch."
            },
            "manufacturer": {
              "type": "string",
              "description": "Who made it, e.g. Apple Inc."
            },
            "model": {
              "type": "string",
              "description": "Its model, e.g. Watch."
            },
            "hardwareVersion": {
              "type": "string",
              "description": "Its hardware version, e.g. Watch7,1."
            },
            "firmwareVersion": {
              "type": "string",
              "description": "Its firmware version."
            },
            "softwareVersion": {
              "type": "string",
              "description": "Its software version, e.g. 26.1."
            }
          },
          "additionalProperties": true,
          "description": "The device that measured it (HKDevice, else the HKMetadataKeyDeviceName and …ManufacturerName metadata), with only the properties it has."
        },
        "HealthSampleSource": {
          "type": "object",
          "properties": {
            "name": {
              "type": "string",
              "description": "The app or device that saved it, as the sample's `source`."
            },
            "bundleId": {
              "type": "string",
              "description": "The bundle ID of the app that saved it, e.g. com.dexcom.G7. Left out for Apple devices' own (com.apple.health.<UUID>), whose UUID identifies the device."
            },
            "version": {
              "type": "string",
              "description": "The version of the app, or the OS, that saved it."
            },
            "productType": {
              "type": "string",
              "description": "The hardware the app that saved it ran on, e.g. iPhone17,1 or Watch7,1."
            },
            "operatingSystemVersion": {
              "type": "string",
              "description": "The OS version it ran on, e.g. 26.1.0."
            },
            "device": {
              "$ref": "#/$defs/HealthSampleDevice"
            }
          },
          "required": [
            "name"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Samples",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Samples"
  },
  {
    "name": "workouts",
    "description": "Workouts that started in a period, newest first, with their activity and name, duration, energy, distance, average heart rate and elevation, whether they were indoors and had a GPS route (to tell a treadmill run from an outdoor one), and the period's count and total time. For one workout's other statistics, laps, segments, pauses, weather and multisport legs, call workout with its id.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day weeks; Y the 12 calendar months ending with that day's month, in months (the last one ends with `date`)."
        },
        "date": {
          "type": "string",
          "description": "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to today."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "range"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "range": {
          "type": "string",
          "description": "The range asked for: D, W, M, 6M or Y."
        },
        "start": {
          "type": "string",
          "description": "When the period starts."
        },
        "end": {
          "type": "string",
          "description": "When the period ends (exclusive)."
        },
        "count": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "Workouts in the period, all of them."
        },
        "duration": {
          "type": "number",
          "description": "Their total duration, in seconds."
        },
        "workouts": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthWorkoutItem"
          },
          "description": "The workouts, newest first, at most 100."
        }
      },
      "required": [
        "timeZone",
        "range",
        "start",
        "end",
        "count",
        "duration",
        "workouts"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthWorkoutActivityItem": {
          "type": "object",
          "properties": {
            "activityType": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "HKWorkoutActivityType's raw value."
            },
            "activity": {
              "type": "string",
              "description": "The activity's name, e.g. Swimming."
            },
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "end": {
              "anyOf": [
                {
                  "type": "string",
                  "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
                },
                {
                  "type": "null"
                }
              ]
            },
            "duration": {
              "type": "number",
              "description": "Seconds of activity, excluding pauses."
            },
            "indoor": {
              "anyOf": [
                {
                  "type": "boolean"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Whether it was indoors (a treadmill run, an indoor ride, a pool swim) rather than outdoors, as the app that recorded it says (HKMetadataKeyIndoorWorkout) or, failing that, as it was set up (its workout configuration's location), or null if neither says."
            },
            "swimmingLocation": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For swims: pool or openWater (HKMetadataKeySwimmingLocationType, else its workout configuration's), or null if neither says."
            }
          },
          "required": [
            "activityType",
            "activity",
            "start",
            "end",
            "duration",
            "indoor",
            "swimmingLocation"
          ],
          "additionalProperties": true
        },
        "HealthWorkoutItem": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "HealthKit's UUID for the workout."
            },
            "activityType": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "HKWorkoutActivityType's raw value, e.g. 37 for running."
            },
            "activity": {
              "type": "string",
              "description": "The activity's name, e.g. Running."
            },
            "name": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The workout's own name, from the app that recorded it (HKMetadataKeyWorkoutBrandName), else the name of the planned workout it followed (a custom or swim-bike-run workout made in an app with WorkoutKit). Usually null: the Workout app doesn't name its own."
            },
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "end": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "recordedTimeZone": {
              "type": "string",
              "description": "The time zone it was recorded in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo, as an IANA name. Left out when it has none, or one that isn't an IANA name. Its other times stay in the output's `timeZone`, so they compare across records."
            },
            "recordedStart": {
              "type": "string",
              "description": "When it starts, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "recordedEnd": {
              "type": "string",
              "description": "When it ends, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "duration": {
              "type": "number",
              "description": "Seconds of activity, excluding pauses."
            },
            "activeEnergy": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Kilocalories."
            },
            "distance": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters."
            },
            "averageHeartRate": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Beats per minute."
            },
            "elevationAscended": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters climbed, if the app that recorded it says (HKMetadataKeyElevationAscended)."
            },
            "indoor": {
              "anyOf": [
                {
                  "type": "boolean"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Whether it was indoors (a treadmill run, an indoor ride, a pool swim) rather than outdoors, as the app that recorded it says (HKMetadataKeyIndoorWorkout), or as its activities say (their metadata, else how each was set up: its workout configuration's location), if they agree. Null if none says: then hasRoute is the best hint."
            },
            "swimmingLocation": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For swims: pool or openWater (HKMetadataKeySwimmingLocationType), as the workout or its activities say (their metadata, else their workout configurations), if they agree, or null if none says."
            },
            "hasRoute": {
              "type": "boolean",
              "description": "Whether it has a GPS route: one HealthKit linked to it or, failing that, one linked to no workout that was recorded during it. Outdoor runs, walks and rides recorded on an iPhone or Apple Watch have one; treadmill runs and other indoor workouts don't. workout_route reads it, by the workout's ID."
            },
            "source": {
              "type": "string",
              "description": "The app or device that recorded it."
            },
            "activities": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthWorkoutActivityItem"
              },
              "description": "A multisport workout's activities (e.g. swim, transition, bike, run), in order. Empty for a workout of one activity."
            }
          },
          "required": [
            "id",
            "activityType",
            "activity",
            "name",
            "start",
            "end",
            "duration",
            "activeEnergy",
            "distance",
            "averageHeartRate",
            "elevationAscended",
            "indoor",
            "swimmingLocation",
            "hasRoute",
            "source",
            "activities"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Workouts",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Workouts"
  },
  {
    "name": "workout",
    "description": "One workout in full, by the ID workouts gives: everything workouts says, plus every statistic HealthKit computed (maximum and minimum heart rate, power, cadence, stride length, swimming strokes…), descent, speeds, METs, the weather, SWOLF and pool length, its pauses, laps (with each length's stroke and SWOLF) and segments, its effort score (rated or Apple Watch's estimate), and a multisport workout's legs with their own statistics and scores. Values from the workout's metadata have 12 significant digits, or 6 if an older lil health uploaded it.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "description": "The workout's ID, from workouts."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "id"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "workout": {
          "$ref": "#/$defs/HealthWorkoutDetail"
        }
      },
      "required": [
        "timeZone",
        "workout"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthWorkoutStatistic": {
          "type": "object",
          "properties": {
            "type": {
              "type": "string",
              "description": "The quantity type, e.g. HKQuantityTypeIdentifierHeartRate."
            },
            "name": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The name Health shows for it, e.g. Heart Rate."
            },
            "unit": {
              "type": "string",
              "description": "The HealthKit unit of its values, e.g. count/min, W, m or kcal."
            },
            "sum": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For types that add up (energy, distance, steps, strokes): the total."
            },
            "average": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For other types (heart rate, power, cadence, speed): the average."
            },
            "minimum": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The lowest reading."
            },
            "maximum": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The highest reading."
            },
            "mostRecent": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The last reading."
            }
          },
          "required": [
            "type",
            "name",
            "unit",
            "sum",
            "average",
            "minimum",
            "maximum",
            "mostRecent"
          ],
          "additionalProperties": true
        },
        "HealthWorkoutLeg": {
          "type": "object",
          "properties": {
            "activityType": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "HKWorkoutActivityType's raw value."
            },
            "activity": {
              "type": "string",
              "description": "The activity's name, e.g. Swimming."
            },
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "end": {
              "anyOf": [
                {
                  "type": "string",
                  "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
                },
                {
                  "type": "null"
                }
              ]
            },
            "duration": {
              "type": "number",
              "description": "Seconds of activity, excluding pauses."
            },
            "indoor": {
              "anyOf": [
                {
                  "type": "boolean"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Whether it was indoors (a treadmill run, an indoor ride, a pool swim) rather than outdoors, as the app that recorded it says (HKMetadataKeyIndoorWorkout) or, failing that, as it was set up (its workout configuration's location), or null if neither says."
            },
            "swimmingLocation": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For swims: pool or openWater (HKMetadataKeySwimmingLocationType, else its workout configuration's), or null if neither says."
            },
            "elevationAscended": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters climbed, if the app that recorded it says (HKMetadataKeyElevationAscended). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "elevationDescended": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters descended, if the app that recorded it says (HKMetadataKeyElevationDescended). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "averageSpeed": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Average speed, in meters per second, if the app that recorded it says (HKMetadataKeyAverageSpeed). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "maximumSpeed": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Top speed, in meters per second, if the app that recorded it says (HKMetadataKeyMaximumSpeed). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "averageMETs": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Average intensity over the whole workout, in METs (kcal/hr·kg), if the app that recorded it says (HKMetadataKeyAverageMETs). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "lapLength": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For pool swims: the pool's length, in meters (25 yd is 22.86), if the app that recorded it says (HKMetadataKeyLapLength). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "swolf": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For swims: the SWOLF score (strokes plus seconds per length; lower is more efficient), if the app that recorded it says (HKMetadataKeySWOLFScore)."
            },
            "effort": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "score": {
                      "type": "number",
                      "description": "How hard it was, from 1 to 10, as Health rates it: 1 to 3 Easy, 4 to 6 Moderate, 7 and 8 Hard, 9 and 10 All Out."
                    },
                    "estimated": {
                      "type": "boolean",
                      "description": "Whether it's Apple Watch's estimate (HKQuantityTypeIdentifierEstimatedWorkoutEffortScore) rather than a score the person rated (HKQuantityTypeIdentifierWorkoutEffortScore)."
                    }
                  },
                  "required": [
                    "score",
                    "estimated"
                  ],
                  "additionalProperties": true
                },
                {
                  "type": "null"
                }
              ],
              "description": "The leg's own effort score: the one HealthKit finds most relevant among those related to it (HKWorkoutEffortRelationship), else, if that hasn't synced, the latest one the person rated, else Apple Watch's latest estimate. People often rate a workout after it ends. Null when it has none, or when linksRead is false and lil health doesn't know."
            },
            "statistics": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthWorkoutStatistic"
              },
              "description": "The leg's own statistics."
            }
          },
          "required": [
            "activityType",
            "activity",
            "start",
            "end",
            "duration",
            "indoor",
            "swimmingLocation",
            "elevationAscended",
            "elevationDescended",
            "averageSpeed",
            "maximumSpeed",
            "averageMETs",
            "lapLength",
            "swolf",
            "effort",
            "statistics"
          ],
          "additionalProperties": true
        },
        "HealthWorkoutPause": {
          "type": "object",
          "properties": {
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "end": {
              "type": "string",
              "description": "When it resumed, or the workout's end."
            },
            "duration": {
              "type": "number",
              "description": "Seconds."
            }
          },
          "required": [
            "start",
            "end",
            "duration"
          ],
          "additionalProperties": true
        },
        "HealthWorkoutInterval": {
          "type": "object",
          "properties": {
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "end": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "duration": {
              "type": "number",
              "description": "Seconds, from start to end."
            },
            "strokeStyle": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For swims: the main stroke (HKMetadataKeySwimmingStrokeStyle): mixed, freestyle, backstroke, breaststroke, butterfly or kickboard, or null if it doesn't say."
            },
            "swolf": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For swims: the SWOLF score (strokes plus seconds per length; lower is more efficient), if the app that recorded it says (HKMetadataKeySWOLFScore)."
            },
            "lapLength": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For pool swims: the pool's length, in meters (25 yd is 22.86), if the app that recorded it says (HKMetadataKeyLapLength). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "averageSpeed": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Average speed, in meters per second, if the app that recorded it says (HKMetadataKeyAverageSpeed). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "maximumSpeed": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Top speed, in meters per second, if the app that recorded it says (HKMetadataKeyMaximumSpeed). To 12 significant digits, or 6 if an older lil health uploaded it."
            }
          },
          "required": [
            "start",
            "end",
            "duration",
            "strokeStyle",
            "swolf",
            "lapLength",
            "averageSpeed",
            "maximumSpeed"
          ],
          "additionalProperties": true
        },
        "HealthWorkoutDetail": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "HealthKit's UUID for the workout."
            },
            "activityType": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "HKWorkoutActivityType's raw value, e.g. 37 for running."
            },
            "activity": {
              "type": "string",
              "description": "The activity's name, e.g. Running."
            },
            "name": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The workout's own name, from the app that recorded it (HKMetadataKeyWorkoutBrandName), else the name of the planned workout it followed (a custom or swim-bike-run workout made in an app with WorkoutKit). Usually null: the Workout app doesn't name its own."
            },
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "end": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "recordedTimeZone": {
              "type": "string",
              "description": "The time zone it was recorded in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo, as an IANA name. Left out when it has none, or one that isn't an IANA name. Its other times stay in the output's `timeZone`, so they compare across records."
            },
            "recordedStart": {
              "type": "string",
              "description": "When it starts, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "recordedEnd": {
              "type": "string",
              "description": "When it ends, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "duration": {
              "type": "number",
              "description": "Seconds of activity, excluding pauses."
            },
            "activeEnergy": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Kilocalories."
            },
            "distance": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters."
            },
            "averageHeartRate": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Beats per minute."
            },
            "elevationAscended": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters climbed, if the app that recorded it says (HKMetadataKeyElevationAscended). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "indoor": {
              "anyOf": [
                {
                  "type": "boolean"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Whether it was indoors (a treadmill run, an indoor ride, a pool swim) rather than outdoors, as the app that recorded it says (HKMetadataKeyIndoorWorkout), or as its activities say (their metadata, else how each was set up: its workout configuration's location), if they agree. Null if none says: then hasRoute is the best hint."
            },
            "swimmingLocation": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For swims: pool or openWater (HKMetadataKeySwimmingLocationType), as the workout or its activities say (their metadata, else their workout configurations), if they agree, or null if none says."
            },
            "hasRoute": {
              "type": "boolean",
              "description": "Whether it has a GPS route: one HealthKit linked to it or, failing that, one linked to no workout that was recorded during it. Outdoor runs, walks and rides recorded on an iPhone or Apple Watch have one; treadmill runs and other indoor workouts don't. workout_route reads it, by the workout's ID."
            },
            "source": {
              "type": "string",
              "description": "The app or device that recorded it."
            },
            "activities": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthWorkoutLeg"
              },
              "description": "A multisport workout's legs (e.g. swim, transition, bike, run), in order, each with its own statistics and effort score. Empty for a workout of one activity, whose statistics and score are the workout's."
            },
            "elevationDescended": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters descended, if the app that recorded it says (HKMetadataKeyElevationDescended). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "averageSpeed": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Average speed, in meters per second, if the app that recorded it says (HKMetadataKeyAverageSpeed). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "maximumSpeed": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Top speed, in meters per second, if the app that recorded it says (HKMetadataKeyMaximumSpeed). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "averageMETs": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Average intensity over the whole workout, in METs (kcal/hr·kg), if the app that recorded it says (HKMetadataKeyAverageMETs). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "lapLength": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For pool swims: the pool's length, in meters (25 yd is 22.86), if the app that recorded it says (HKMetadataKeyLapLength). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "swolf": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "For swims: the SWOLF score (strokes plus seconds per length; lower is more efficient), if the app that recorded it says (HKMetadataKeySWOLFScore)."
            },
            "weatherCondition": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The weather (HKMetadataKeyWeatherCondition), as HKWeatherCondition names it, e.g. clear, partlyCloudy, showers or snow, or null if it doesn't say."
            },
            "weatherTemperature": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The temperature, in °C, if the app that recorded it says (HKMetadataKeyWeatherTemperature). To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "weatherHumidity": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Relative humidity, in percent from 0 to 100 (HKMetadataKeyWeatherHumidity). Apple's Workout app writes it 100 times too large (72% as 7200 %), so a value over 100 is divided by 100. To 12 significant digits, or 6 if an older lil health uploaded it."
            },
            "linksRead": {
              "type": "boolean",
              "description": "Whether lil health has read what HealthKit links to the workout: its effort scores, and the samples recorded with it. False for a workout an older lil health on the iPhone uploaded, until an updated one reads its links. While it's false, a null effort means lil health doesn't know the score, not that there's none."
            },
            "effort": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "score": {
                      "type": "number",
                      "description": "How hard it was, from 1 to 10, as Health rates it: 1 to 3 Easy, 4 to 6 Moderate, 7 and 8 Hard, 9 and 10 All Out."
                    },
                    "estimated": {
                      "type": "boolean",
                      "description": "Whether it's Apple Watch's estimate (HKQuantityTypeIdentifierEstimatedWorkoutEffortScore) rather than a score the person rated (HKQuantityTypeIdentifierWorkoutEffortScore)."
                    }
                  },
                  "required": [
                    "score",
                    "estimated"
                  ],
                  "additionalProperties": true
                },
                {
                  "type": "null"
                }
              ],
              "description": "The workout's effort score: the one HealthKit finds most relevant among those related to it (HKWorkoutEffortRelationship), else, if that hasn't synced, the latest one the person rated, else Apple Watch's latest estimate. People often rate a workout after it ends. Null when it has none, or when linksRead is false and lil health doesn't know."
            },
            "statistics": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthWorkoutStatistic"
              },
              "description": "Every statistic HealthKit computed over it, one per quantity type, by type: energy, distance, heart rate (average, minimum, maximum), power, cadence, speed, stride length, ground contact time, vertical oscillation, swimming strokes, flights climbed… whatever was recorded. Null where HealthKit gives none."
            },
            "pauseCount": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "How many times it was paused."
            },
            "pauses": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthWorkoutPause"
              },
              "description": "When it was paused, by the person or automatically (auto-pause), from each pause to the resume after it, in order, at most 300. duration leaves them out."
            },
            "lapCount": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991
            },
            "laps": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthWorkoutInterval"
              },
              "description": "Its laps (HKWorkoutEventTypeLap), in order, at most 300: a pool swim's lengths, with each one's stroke and SWOLF, or laps marked in an app."
            },
            "segmentCount": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991
            },
            "segments": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthWorkoutInterval"
              },
              "description": "Its segments (HKWorkoutEventTypeSegment), in order, at most 300: splits, intervals or sets, as the app that recorded it marked them."
            }
          },
          "required": [
            "id",
            "activityType",
            "activity",
            "name",
            "start",
            "end",
            "duration",
            "activeEnergy",
            "distance",
            "averageHeartRate",
            "elevationAscended",
            "indoor",
            "swimmingLocation",
            "hasRoute",
            "source",
            "activities",
            "elevationDescended",
            "averageSpeed",
            "maximumSpeed",
            "averageMETs",
            "lapLength",
            "swolf",
            "weatherCondition",
            "weatherTemperature",
            "weatherHumidity",
            "linksRead",
            "effort",
            "statistics",
            "pauseCount",
            "pauses",
            "lapCount",
            "laps",
            "segmentCount",
            "segments"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Workout",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Workout"
  },
  {
    "name": "workout_routes",
    "description": "GPS routes that started in a period, newest first, each with the workout it belongs to: outdoor workouts' routes, and any recorded without one (by another app, or whose workout was deleted). workouts already says which workouts have one (hasRoute). For a route's distance, elevation and shape, call workout_route.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day weeks; Y the 12 calendar months ending with that day's month, in months (the last one ends with `date`)."
        },
        "date": {
          "type": "string",
          "description": "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to today."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "range"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "range": {
          "type": "string",
          "description": "The range asked for: D, W, M, 6M or Y."
        },
        "start": {
          "type": "string",
          "description": "When the period starts."
        },
        "end": {
          "type": "string",
          "description": "When the period ends (exclusive)."
        },
        "count": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "Routes that start in the period, all of them."
        },
        "routes": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthWorkoutRouteItem"
          },
          "description": "The routes, newest first, at most 100."
        }
      },
      "required": [
        "timeZone",
        "range",
        "start",
        "end",
        "count",
        "routes"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthWorkoutRouteItem": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "HealthKit's UUID for the route."
            },
            "workout": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The ID of the workout HealthKit linked it to, or null if it links none: then workout_route still finds it by the ID of a workout it was recorded during."
            },
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "end": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "recordedTimeZone": {
              "type": "string",
              "description": "The time zone it was recorded in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo, as an IANA name. Left out when it has none, or one that isn't an IANA name. Its other times stay in the output's `timeZone`, so they compare across records."
            },
            "recordedStart": {
              "type": "string",
              "description": "When it starts, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "recordedEnd": {
              "type": "string",
              "description": "When it ends, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "duration": {
              "type": "number",
              "description": "Seconds, from start to end."
            },
            "pointCount": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "How many GPS points it has."
            },
            "source": {
              "type": "string",
              "description": "The app or device that recorded it."
            }
          },
          "required": [
            "id",
            "workout",
            "start",
            "end",
            "duration",
            "pointCount",
            "source"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Workout Routes",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Workout Routes"
  },
  {
    "name": "workout_route",
    "description": "One GPS route in summary: its distance, elevation gain and loss, bounds, where it starts and ends, and its shape as a simplified line of at most 500 points, with the tolerance used. By a workout's ID (from workouts, when hasRoute is true) or a route's (from workout_routes). A workout's route is the one HealthKit linked to it or, failing that, one linked to no workout that was recorded during it. Its every point, with speed, course and accuracy, comes from workout_route_points, a page at a time: ask for them only when the shape isn't enough. Routes are precise locations.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "description": "A workout's ID, from workouts, or a route's, from workout_routes."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "id"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "route": {
          "$ref": "#/$defs/HealthWorkoutRouteDetail"
        }
      },
      "required": [
        "timeZone",
        "route"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthRouteShapePoint": {
          "type": "object",
          "properties": {
            "time": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "latitude": {
              "type": "number",
              "description": "Degrees, to 5 decimal places."
            },
            "longitude": {
              "type": "number",
              "description": "Degrees, to 5 decimal places."
            },
            "altitude": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters above sea level. Stored as a 32-bit float, so rounded to 2 decimal places, or null if the device didn't know."
            }
          },
          "required": [
            "time",
            "latitude",
            "longitude",
            "altitude"
          ],
          "additionalProperties": true
        },
        "HealthRouteShape": {
          "type": "object",
          "properties": {
            "tolerance": {
              "type": "number",
              "description": "Meters: no point of the route is further than this from the line through points. 5 m, doubled until it keeps at most 500 points."
            },
            "pointCount": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "How many points it kept."
            },
            "points": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthRouteShapePoint"
              },
              "description": "The points it kept, in order, the first and last included."
            }
          },
          "required": [
            "tolerance",
            "pointCount",
            "points"
          ],
          "additionalProperties": true,
          "description": "Its shape, simplified (Ramer-Douglas-Peucker): enough to draw it, or to tell where it went and when."
        },
        "HealthWorkoutRouteDetail": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "HealthKit's UUID for the route."
            },
            "workout": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The ID of the workout HealthKit linked it to, or null if it links none: then workout_route still finds it by the ID of a workout it was recorded during."
            },
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "end": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "recordedTimeZone": {
              "type": "string",
              "description": "The time zone it was recorded in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo, as an IANA name. Left out when it has none, or one that isn't an IANA name. Its other times stay in the output's `timeZone`, so they compare across records."
            },
            "recordedStart": {
              "type": "string",
              "description": "When it starts, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "recordedEnd": {
              "type": "string",
              "description": "When it ends, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "duration": {
              "type": "number",
              "description": "Seconds, from start to end."
            },
            "pointCount": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "How many GPS points it has."
            },
            "source": {
              "type": "string",
              "description": "The app or device that recorded it."
            },
            "distance": {
              "type": "number",
              "description": "Meters along its points, from each to the next on the Earth's surface. The workout's own distance, which the Watch also measures by motion, may differ a little."
            },
            "elevationGain": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters climbed: every rise from one point to the next, among the points with a known altitude, to 2 decimal places. From GPS, so noisier, and usually higher, than the workout's elevationAscended, which the barometer measures. Null without two such points."
            },
            "elevationLoss": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters descended, as elevationGain counts climbs."
            },
            "bounds": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "south": {
                      "type": "number",
                      "description": "The lowest latitude, in degrees."
                    },
                    "west": {
                      "type": "number",
                      "description": "The lowest longitude, in degrees."
                    },
                    "north": {
                      "type": "number",
                      "description": "The highest latitude, in degrees."
                    },
                    "east": {
                      "type": "number",
                      "description": "The highest longitude, in degrees."
                    }
                  },
                  "required": [
                    "south",
                    "west",
                    "north",
                    "east"
                  ],
                  "additionalProperties": true
                },
                {
                  "type": "null"
                }
              ],
              "description": "The box its points fit in, to 5 decimal places (about a meter)."
            },
            "startArea": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "latitude": {
                      "type": "number"
                    },
                    "longitude": {
                      "type": "number"
                    }
                  },
                  "required": [
                    "latitude",
                    "longitude"
                  ],
                  "additionalProperties": true
                },
                {
                  "type": "null"
                }
              ],
              "description": "About where it starts: its first point, to 3 decimal places (about 100 m)."
            },
            "endArea": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "latitude": {
                      "type": "number"
                    },
                    "longitude": {
                      "type": "number"
                    }
                  },
                  "required": [
                    "latitude",
                    "longitude"
                  ],
                  "additionalProperties": true
                },
                {
                  "type": "null"
                }
              ],
              "description": "About where it ends: its last point, to 3 decimal places (about 100 m)."
            },
            "simplified": {
              "$ref": "#/$defs/HealthRouteShape"
            }
          },
          "required": [
            "id",
            "workout",
            "start",
            "end",
            "duration",
            "pointCount",
            "source",
            "distance",
            "elevationGain",
            "elevationLoss",
            "bounds",
            "startArea",
            "endArea",
            "simplified"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Workout Route",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Workout Route"
  },
  {
    "name": "workout_route_points",
    "description": "A GPS route's points, in order, a page at a time: each one's time, latitude, longitude and altitude, speed, course and accuracy. By a workout's ID (from workouts, when hasRoute is true) or a route's (from workout_routes). A workout's route is the one HealthKit linked to it or, failing that, one linked to no workout that was recorded during it. A route has about a point a second, thousands an hour: call workout_route first, whose simplified shape is usually enough, and this only to look at particular stretches. Routes are precise locations.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "description": "A workout's ID, from workouts, or a route's, from workout_routes."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        },
        "cursor": {
          "type": "string",
          "description": "The previous page's nextCursor."
        },
        "limit": {
          "type": "integer",
          "minimum": 1,
          "maximum": 1000,
          "description": "Points per page, at most 1000. Defaults to 500."
        }
      },
      "required": [
        "id"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "id": {
          "type": "string",
          "description": "The route's ID."
        },
        "pointCount": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "How many points the route has, all of them."
        },
        "points": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthRoutePoint"
          },
          "description": "This page's points, in order."
        },
        "nextCursor": {
          "anyOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ],
          "description": "Pass it as `cursor` for the next page; null on the last page."
        }
      },
      "required": [
        "timeZone",
        "id",
        "pointCount",
        "points",
        "nextCursor"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthRoutePoint": {
          "type": "object",
          "properties": {
            "time": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "latitude": {
              "type": "number",
              "description": "Degrees."
            },
            "longitude": {
              "type": "number",
              "description": "Degrees."
            },
            "altitude": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters above sea level. Stored as a 32-bit float, so rounded to 2 decimal places, or null if the device didn't know."
            },
            "horizontalAccuracy": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters: the radius the true position is within. Stored as a 32-bit float, so rounded to 2 decimal places, or null if the device didn't know."
            },
            "verticalAccuracy": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters: how far the true altitude may be. Stored as a 32-bit float, so rounded to 2 decimal places, or null if the device didn't know."
            },
            "speed": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Meters per second. Stored as a 32-bit float, so rounded to 2 decimal places, or null if the device didn't know."
            },
            "course": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Degrees from true north it was heading. Stored as a 32-bit float, so rounded to 2 decimal places, or null if the device didn't know."
            }
          },
          "required": [
            "time",
            "latitude",
            "longitude",
            "altitude",
            "horizontalAccuracy",
            "verticalAccuracy",
            "speed",
            "course"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Workout Route Points",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Workout Route Points"
  },
  {
    "name": "sleep",
    "description": "Sleep per night in a period: time in bed, asleep and awake, and the sleep stages (core, deep, REM), from the person's sleep tracking. As in Apple Health, a night slept in another time zone is dated by that zone's clock, and says which zone it was (recordedTimeZone) and its times on that clock.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day weeks; Y the 12 calendar months ending with that day's month, in months (the last one ends with `date`)."
        },
        "date": {
          "type": "string",
          "description": "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to today."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "range"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "range": {
          "type": "string",
          "description": "The range asked for: D, W, M, 6M or Y."
        },
        "start": {
          "type": "string",
          "description": "When the period starts."
        },
        "end": {
          "type": "string",
          "description": "When the period ends (exclusive)."
        },
        "nights": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthSleepNight"
          },
          "description": "Each night whose date is in the period, oldest first. A night slept in another zone is dated by that zone's clock, so its start and end can fall outside the period."
        }
      },
      "required": [
        "timeZone",
        "range",
        "start",
        "end",
        "nights"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthSleepNight": {
          "type": "object",
          "properties": {
            "date": {
              "type": "string",
              "description": "The day the night ends on (sleep from 6 PM counts toward the next day), as YYYY-MM-DD, on the clock of the zone it was slept in when it has one (recordedTimeZone), as Apple Health dates it, else in the output's `timeZone`."
            },
            "start": {
              "type": "string",
              "description": "When the night's first sleep sample starts."
            },
            "end": {
              "type": "string",
              "description": "When its last sleep sample ends."
            },
            "recordedTimeZone": {
              "type": "string",
              "description": "The time zone it was slept in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo: its last-ending sample's that has one, so a night across a change of zone (a flight) is the zone it ended in. Left out when none has one. start and end stay in the output's `timeZone`."
            },
            "recordedStart": {
              "type": "string",
              "description": "When it starts, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "recordedEnd": {
              "type": "string",
              "description": "When it ends, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "inBed": {
              "type": "number",
              "description": "Seconds in bed."
            },
            "asleep": {
              "type": "number",
              "description": "Seconds asleep, in any stage."
            },
            "awake": {
              "type": "number",
              "description": "Seconds awake during the night."
            },
            "core": {
              "type": "number",
              "description": "Seconds of core sleep."
            },
            "deep": {
              "type": "number",
              "description": "Seconds of deep sleep."
            },
            "rem": {
              "type": "number",
              "description": "Seconds of REM sleep."
            },
            "unspecified": {
              "type": "number",
              "description": "Seconds asleep without a stage (sources that don't track stages)."
            }
          },
          "required": [
            "date",
            "start",
            "end",
            "inBed",
            "asleep",
            "awake",
            "core",
            "deep",
            "rem",
            "unspecified"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Sleep",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Sleep"
  },
  {
    "name": "activity_rings",
    "description": "Activity rings per day in a period, as Fitness and lil health's Activity Rings show them: Move (active kilocalories, or minutes in Move time), Exercise (minutes) and Stand (hours), each with the day's value and goal, and whether the rings were paused. Exercise and Stand are null without an Apple Watch. Days are the iPhone's own: the period's days pick them by date, not shifted to `timeZone`. Without a `date`, the period ends today in `timeZone`, so pass the person's time zone for their today.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day weeks; Y the 12 calendar months ending with that day's month, in months (the last one ends with `date`)."
        },
        "date": {
          "type": "string",
          "description": "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to today."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "range"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "range": {
          "type": "string",
          "description": "The range asked for: D, W, M, 6M or Y."
        },
        "start": {
          "type": "string",
          "description": "When the period starts."
        },
        "end": {
          "type": "string",
          "description": "When the period ends (exclusive)."
        },
        "days": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthActivityDay"
          },
          "description": "Each day of the period with rings, oldest first. Days without are left out."
        }
      },
      "required": [
        "timeZone",
        "range",
        "start",
        "end",
        "days"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthActivityDay": {
          "type": "object",
          "properties": {
            "date": {
              "type": "string",
              "description": "The day, as the iPhone recorded it: a day in the iPhone's own time zone, whatever `timeZone` is."
            },
            "move": {
              "type": "object",
              "properties": {
                "value": {
                  "type": "number",
                  "description": "How far it got, in `unit`."
                },
                "goal": {
                  "type": "number",
                  "description": "The day's goal, in `unit`."
                },
                "unit": {
                  "type": "string",
                  "description": "kcal, or min for Move time."
                }
              },
              "required": [
                "value",
                "goal",
                "unit"
              ],
              "additionalProperties": true,
              "description": "The Move ring: active energy, or minutes of movement for those who move by time (children, or anyone who chose Move time)."
            },
            "exercise": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "value": {
                      "type": "number",
                      "description": "How far it got, in `unit`."
                    },
                    "goal": {
                      "type": "number",
                      "description": "The day's goal, in `unit`."
                    },
                    "unit": {
                      "type": "string",
                      "description": "Always min."
                    }
                  },
                  "required": [
                    "value",
                    "goal",
                    "unit"
                  ],
                  "additionalProperties": true,
                  "description": "The Exercise ring, in minutes of brisk activity, or null without an Exercise goal (no Apple Watch)."
                },
                {
                  "type": "null"
                }
              ]
            },
            "stand": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "value": {
                      "type": "number",
                      "description": "How far it got, in `unit`."
                    },
                    "goal": {
                      "type": "number",
                      "description": "The day's goal, in `unit`."
                    },
                    "unit": {
                      "type": "string",
                      "description": "Always hr."
                    }
                  },
                  "required": [
                    "value",
                    "goal",
                    "unit"
                  ],
                  "additionalProperties": true,
                  "description": "The Stand ring, in hours with at least a minute of standing, or null without a Stand goal (no Apple Watch)."
                },
                {
                  "type": "null"
                }
              ]
            },
            "paused": {
              "type": "boolean",
              "description": "Whether the person paused their rings that day, so its goals didn't count."
            }
          },
          "required": [
            "date",
            "move",
            "exercise",
            "stand",
            "paused"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Activity Rings",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Activity Rings"
  },
  {
    "name": "state_of_mind",
    "description": "State of Mind logs in a period, newest first, as Health and lil health's State of Mind show them: whether each was a momentary emotion or a daily mood, how pleasant it felt (valence from -1 to 1, and its classification, e.g. Slightly Pleasant), the feelings that described it (labels) and what it was about (associations), with the period's count. People log them in the Health app, or in Mindfulness on Apple Watch.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day weeks; Y the 12 calendar months ending with that day's month, in months (the last one ends with `date`)."
        },
        "date": {
          "type": "string",
          "description": "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to today."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "range"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "range": {
          "type": "string",
          "description": "The range asked for: D, W, M, 6M or Y."
        },
        "start": {
          "type": "string",
          "description": "When the period starts."
        },
        "end": {
          "type": "string",
          "description": "When the period ends (exclusive)."
        },
        "count": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "State of Mind logs in the period, all of them."
        },
        "logs": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthStateOfMindItem"
          },
          "description": "The logs, newest first, at most 500."
        }
      },
      "required": [
        "timeZone",
        "range",
        "start",
        "end",
        "count",
        "logs"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthStateOfMindItem": {
          "type": "object",
          "properties": {
            "time": {
              "type": "string",
              "description": "When it was logged: a momentary emotion's moment, or for a daily mood, a time in the day it describes."
            },
            "recordedTimeZone": {
              "type": "string",
              "description": "The time zone it was recorded in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo, as an IANA name. Left out when it has none, or one that isn't an IANA name. Its other times stay in the output's `timeZone`, so they compare across records."
            },
            "recordedTime": {
              "type": "string",
              "description": "Its time, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "kind": {
              "type": "string",
              "description": "Momentary Emotion (how they felt right then) or Daily Mood (how they felt over the day), or Unknown for one a later iOS adds."
            },
            "valence": {
              "type": "number",
              "description": "How pleasant it felt, from -1 (very unpleasant) to 1 (very pleasant)."
            },
            "classification": {
              "type": "string",
              "description": "The valence as the person chose it: Very Unpleasant, Unpleasant, Slightly Unpleasant, Neutral, Slightly Pleasant, Pleasant or Very Pleasant (Unknown for one a later iOS adds)."
            },
            "labels": {
              "type": "array",
              "items": {
                "type": "string"
              },
              "description": "The feelings that described it, e.g. Calm, Grateful or Stressed, in the order they were logged. Empty if none."
            },
            "associations": {
              "type": "array",
              "items": {
                "type": "string"
              },
              "description": "What it was about, e.g. Work, Family or Health, in the order they were logged. Empty if none."
            },
            "source": {
              "type": "string",
              "description": "The app or device it was logged in: Health, Mindfulness, or another app."
            }
          },
          "required": [
            "time",
            "kind",
            "valence",
            "classification",
            "labels",
            "associations",
            "source"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health State of Mind",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health State of Mind"
  },
  {
    "name": "assessments",
    "description": "GAD-7 (anxiety) and PHQ-9 (depression) questionnaires taken in a period, newest first, as Health and lil health's Anxiety Risk and Depression Risk show them: each one's score out of its maximum, the risk Health gave it, and every question's answer, with the period's count. They're screening questionnaires people take in the Health app, not diagnoses.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day weeks; Y the 12 calendar months ending with that day's month, in months (the last one ends with `date`)."
        },
        "date": {
          "type": "string",
          "description": "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to today."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "range"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "range": {
          "type": "string",
          "description": "The range asked for: D, W, M, 6M or Y."
        },
        "start": {
          "type": "string",
          "description": "When the period starts."
        },
        "end": {
          "type": "string",
          "description": "When the period ends (exclusive)."
        },
        "count": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "Assessments in the period, all of them."
        },
        "assessments": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthAssessmentItem"
          },
          "description": "The assessments, newest first, at most 100."
        }
      },
      "required": [
        "timeZone",
        "range",
        "start",
        "end",
        "count",
        "assessments"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthAssessmentItem": {
          "type": "object",
          "properties": {
            "type": {
              "type": "string",
              "description": "HKScoredAssessmentTypeIdentifierGAD7 (anxiety) or HKScoredAssessmentTypeIdentifierPHQ9 (depression)."
            },
            "name": {
              "type": "string",
              "description": "Its name in Health: Anxiety Risk (GAD-7) or Depression Risk (PHQ-9)."
            },
            "time": {
              "type": "string",
              "description": "When it was taken."
            },
            "recordedTimeZone": {
              "type": "string",
              "description": "The time zone it was recorded in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo, as an IANA name. Left out when it has none, or one that isn't an IANA name. Its other times stay in the output's `timeZone`, so they compare across records."
            },
            "recordedTime": {
              "type": "string",
              "description": "Its time, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "score": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "The total of the answers' points, from 0 to maximumScore."
            },
            "maximumScore": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "The highest score: 21 for GAD-7, 27 for PHQ-9 (3 points a question)."
            },
            "risk": {
              "type": "string",
              "description": "The risk Health gave the score. GAD-7: None to Minimal (0 to 4), Mild (5 to 9), Moderate (10 to 14) or Severe (15 to 21). PHQ-9: None to Minimal (0 to 4), Mild (5 to 9), Moderate (10 to 14), Moderately Severe (15 to 19) or Severe (20 to 27). Unknown for one a later iOS adds."
            },
            "answers": {
              "type": "array",
              "items": {
                "type": "string"
              },
              "description": "Each question's answer, in the questionnaire's order (7 for GAD-7, 9 for PHQ-9), to how often over the last two weeks: Not at all (0 points), Several days (1), More than half the days (2) or Nearly every day (3). PHQ-9's 9th question, on thoughts of self-harm, can be Prefer not to answer. Unknown for an answer a later iOS adds."
            }
          },
          "required": [
            "type",
            "name",
            "time",
            "score",
            "maximumScore",
            "risk",
            "answers"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Assessments",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Assessments"
  },
  {
    "name": "electrocardiograms",
    "description": "ECG recordings (from the ECG app on Apple Watch, or another app) that started in a period, newest first, as lil health's ECG page lists them: each one's classification (e.g. Sinus Rhythm or Atrial Fibrillation), average heart rate, sampling frequency, how many voltage measurements it has and the symptoms logged with it, with the period's count. Its voltages come from electrocardiogram_voltages, a page at a time: ask for them only when the classification and heart rate aren't enough.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day weeks; Y the 12 calendar months ending with that day's month, in months (the last one ends with `date`)."
        },
        "date": {
          "type": "string",
          "description": "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to today."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "range"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "range": {
          "type": "string",
          "description": "The range asked for: D, W, M, 6M or Y."
        },
        "start": {
          "type": "string",
          "description": "When the period starts."
        },
        "end": {
          "type": "string",
          "description": "When the period ends (exclusive)."
        },
        "count": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "ECGs that start in the period, all of them."
        },
        "recordings": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthElectrocardiogramItem"
          },
          "description": "The recordings, newest first, at most 100."
        }
      },
      "required": [
        "timeZone",
        "range",
        "start",
        "end",
        "count",
        "recordings"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthElectrocardiogramSymptom": {
          "type": "object",
          "properties": {
            "type": {
              "type": "string",
              "description": "The symptom's category type, e.g. HKCategoryTypeIdentifierRapidPoundingOrFlutteringHeartbeat."
            },
            "name": {
              "type": "string",
              "description": "The name Health gives it, e.g. Rapid, Pounding, or Fluttering Heartbeat."
            }
          },
          "required": [
            "type",
            "name"
          ],
          "additionalProperties": true
        },
        "HealthElectrocardiogramItem": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "HealthKit's UUID for the recording."
            },
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "end": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "recordedTimeZone": {
              "type": "string",
              "description": "The time zone it was recorded in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo, as an IANA name. Left out when it has none, or one that isn't an IANA name. Its other times stay in the output's `timeZone`, so they compare across records."
            },
            "recordedStart": {
              "type": "string",
              "description": "When it starts, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "recordedEnd": {
              "type": "string",
              "description": "When it ends, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "duration": {
              "type": "number",
              "description": "Seconds, from start to end: 30 for Apple Watch's ECG app."
            },
            "classification": {
              "type": "string",
              "description": "What the ECG app classified the rhythm as, as Health names it: Sinus Rhythm (no signs of atrial fibrillation), Atrial Fibrillation, Low Heart Rate (under 50 BPM, too slow to check), High Heart Rate (too fast to check: over 120 BPM, or 150 BPM from algorithm version 2), Poor Recording, Inconclusive, Unrecognized, or Not Classified. A screening result from the person's watch, not a diagnosis."
            },
            "averageHeartRate": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The average heart rate during the recording, in beats per minute, or null."
            },
            "samplingFrequency": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Voltage measurements per second (Hz), as recorded: 512 for Apple Watch. Null if the recording doesn't say."
            },
            "voltageCount": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "How many voltage measurements it has: 15,360 for 30 seconds at 512 Hz. electrocardiogram_voltages reads them; 0 for a recording without any."
            },
            "symptoms": {
              "type": "string",
              "description": "Whether symptoms were logged with it, as lil health shows it: Symptoms Logged, No Symptoms, or Not Logged (they weren't asked about). loggedSymptoms says which."
            },
            "loggedSymptoms": {
              "anyOf": [
                {
                  "type": "array",
                  "items": {
                    "$ref": "#/$defs/HealthElectrocardiogramSymptom"
                  }
                },
                {
                  "type": "null"
                }
              ],
              "description": "The symptoms logged with it (HKQuery.predicateForObjectsAssociated), in the order they were logged: empty when none were. Null when lil health doesn't know which: for a recording an older lil health on the iPhone uploaded, until an updated one reads its links. Its symptoms are then symptom samples logged around its time, which samples lists by type."
            },
            "algorithmVersion": {
              "type": "number",
              "description": "The version of the ECG app's algorithm that classified it (HKMetadataKeyAppleECGAlgorithmVersion): 1, or 2, which classifies heart rates up to 150 BPM. Left out when it doesn't say."
            },
            "source": {
              "type": "string",
              "description": "The app or device that recorded it, e.g. ECG on Apple Watch."
            }
          },
          "required": [
            "id",
            "start",
            "end",
            "duration",
            "classification",
            "averageHeartRate",
            "samplingFrequency",
            "voltageCount",
            "symptoms",
            "loggedSymptoms",
            "source"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health ECGs",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health ECGs"
  },
  {
    "name": "electrocardiogram_voltages",
    "description": "One ECG recording's voltages, in microvolts, a page of seconds at a time, in order: 10 seconds a page by default, at its own rate (Apple Watch's is 512 a second, so 5,120 values). Each page says its rate, and is downsampled (each value the average of a few measurements) only if it would have more than 15,360 values. By its ID, from electrocardiograms, whose classification and heart rate usually answer what's asked: call this only to look at the trace itself.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "description": "An ECG's ID, from electrocardiograms."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        },
        "cursor": {
          "type": "string",
          "description": "The previous page's nextCursor."
        },
        "seconds": {
          "type": "integer",
          "minimum": 1,
          "maximum": 30,
          "description": "Seconds of the recording per page, at most 30 (a whole Apple Watch recording). Defaults to 10."
        }
      },
      "required": [
        "id"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "id": {
          "type": "string",
          "description": "The recording's ID."
        },
        "start": {
          "type": "string",
          "description": "When the recording starts."
        },
        "samplingFrequency": {
          "type": "number",
          "description": "The recording's measurements per second (Hz): as recorded, or if it doesn't say, its measurements over its duration (512 if that can't tell either)."
        },
        "voltageCount": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "How many measurements the recording has, all of them."
        },
        "offset": {
          "type": "number",
          "description": "Seconds from the recording's start to this page's first value."
        },
        "rate": {
          "type": "number",
          "description": "This page's values per second: samplingFrequency, or less when the page is downsampled."
        },
        "measurementsPerValue": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "How many measurements each value stands for: 1, or when the page is downsampled to stay under 15,360 values, the average of that many in a row (the last value may average fewer)."
        },
        "values": {
          "type": "array",
          "items": {
            "anyOf": [
              {
                "type": "number"
              },
              {
                "type": "null"
              }
            ]
          },
          "description": "The voltages, in microvolts (µV), in order, `rate` a second from `offset`: Apple Watch's lead I, as on ECG paper (1 mV is 1,000 µV). Stored as 32-bit floats, so rounded to 2 decimal places. Null where the recording has no value."
        },
        "nextCursor": {
          "anyOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ],
          "description": "Pass it as `cursor` for the next page; null on the last page."
        }
      },
      "required": [
        "timeZone",
        "id",
        "start",
        "samplingFrequency",
        "voltageCount",
        "offset",
        "rate",
        "measurementsPerValue",
        "values",
        "nextCursor"
      ],
      "additionalProperties": true
    },
    "annotations": {
      "title": "Health ECG Voltages",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health ECG Voltages"
  },
  {
    "name": "heartbeat_series",
    "description": "Heartbeat series (Apple Watch's beat-to-beat measurements, behind Health's Heart Rate Variability readings, about a minute and a hundred beats each, or another app's) that started in a period, newest first, as lil health's Beat-to-Beat Measurements page lists them: each one's beat count, duration, gaps, and its average heart rate, SDNN and RMSSD worked out from its intervals, with the period's count. An interval is the time from one beat to the next. A beat preceded by a gap (beats HealthKit couldn't measure came before it) starts afresh: there's no interval from the beat before it, and no difference of intervals spans the gap. An interval of 0 (two beats at the same time) is skipped as a duplicate beat. Beats aren't filtered otherwise: no ectopic or artifact correction. Each series' beats come from heartbeat_series_beats, a page at a time: ask for them only when these summaries aren't enough. For HRV over weeks or months, metric of HKQuantityTypeIdentifierHeartRateVariabilitySDNN is shorter.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day weeks; Y the 12 calendar months ending with that day's month, in months (the last one ends with `date`)."
        },
        "date": {
          "type": "string",
          "description": "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to today."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "range"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "range": {
          "type": "string",
          "description": "The range asked for: D, W, M, 6M or Y."
        },
        "start": {
          "type": "string",
          "description": "When the period starts."
        },
        "end": {
          "type": "string",
          "description": "When the period ends (exclusive)."
        },
        "count": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "Heartbeat series that start in the period, all of them."
        },
        "series": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthHeartbeatSeriesItem"
          },
          "description": "The series, newest first, at most 100."
        }
      },
      "required": [
        "timeZone",
        "range",
        "start",
        "end",
        "count",
        "series"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthHeartbeatSeriesItem": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "HealthKit's UUID for the series."
            },
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "end": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "recordedTimeZone": {
              "type": "string",
              "description": "The time zone it was recorded in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo, as an IANA name. Left out when it has none, or one that isn't an IANA name. Its other times stay in the output's `timeZone`, so they compare across records."
            },
            "recordedStart": {
              "type": "string",
              "description": "When it starts, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "recordedEnd": {
              "type": "string",
              "description": "When it ends, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "beatCount": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "How many beats it has, all of them."
            },
            "duration": {
              "type": "number",
              "description": "Seconds from its first beat to its last, to 4 decimal places (0.1 ms)."
            },
            "gapCount": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "How many of its beats are preceded by a gap (precededByGap)."
            },
            "intervalCount": {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991,
              "description": "How many intervals between beats the averages below are worked out from."
            },
            "averageHeartRate": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "60 over the mean interval in seconds, in beats per minute, to 2 decimal places; null without an interval."
            },
            "sdnn": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "SDNN, in ms, to 2 decimal places: the sample standard deviation of the intervals (dividing by their count less 1). Apple Health's Heart Rate Variability is an SDNN, which Apple works out itself, so it can differ a little. Null with fewer than 2 intervals."
            },
            "rmssd": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "RMSSD, in ms, to 2 decimal places: the root mean square of the differences between each interval and the one before it, within each run of beats without a gap. Null without two intervals in a row."
            },
            "source": {
              "type": "string",
              "description": "The app or device that measured it, e.g. Apple Watch."
            }
          },
          "required": [
            "id",
            "start",
            "end",
            "beatCount",
            "duration",
            "gapCount",
            "intervalCount",
            "averageHeartRate",
            "sdnn",
            "rmssd",
            "source"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Heartbeat Series",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Heartbeat Series"
  },
  {
    "name": "heartbeat_series_beats",
    "description": "One heartbeat series' beats, in order, a page at a time: each beat's time since the series' start, the interval since the beat before in ms, and whether a gap preceded it, to work out HRV or look at the rhythm another way. An interval is the time from one beat to the next. A beat preceded by a gap (beats HealthKit couldn't measure came before it) starts afresh: there's no interval from the beat before it, and no difference of intervals spans the gap. An interval of 0 (two beats at the same time) is skipped as a duplicate beat. Beats aren't filtered otherwise: no ectopic or artifact correction. heartbeat_series works out the average heart rate, SDNN and RMSSD by these rules. By its ID, from heartbeat_series, whose average heart rate, SDNN and RMSSD usually answer what's asked: call this only when they don't. 1,000 beats a page by default, which is a whole Apple Watch series.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "description": "A heartbeat series' ID, from heartbeat_series."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        },
        "cursor": {
          "type": "string",
          "description": "The previous page's nextCursor."
        },
        "limit": {
          "type": "integer",
          "minimum": 1,
          "maximum": 2000,
          "description": "Beats per page, at most 2,000. Defaults to 1,000."
        }
      },
      "required": [
        "id"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "id": {
          "type": "string",
          "description": "The series' ID."
        },
        "start": {
          "type": "string",
          "description": "When the series starts: its beats' time 0."
        },
        "beatCount": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "How many beats the series has, all of them."
        },
        "beats": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthHeartbeat"
          },
          "description": "This page's beats, in order."
        },
        "nextCursor": {
          "anyOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ],
          "description": "Pass it as `cursor` for the next page; null on the last page."
        }
      },
      "required": [
        "timeZone",
        "id",
        "start",
        "beatCount",
        "beats",
        "nextCursor"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthHeartbeat": {
          "type": "object",
          "properties": {
            "time": {
              "type": "number",
              "description": "Seconds from the series' start to the beat, to 4 decimal places (0.1 ms)."
            },
            "interval": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Milliseconds since the beat before, to 1 decimal place; null for the series' first beat and a beat preceded by a gap, and 0 for a duplicate beat (at the same time as the one before), which heartbeat_series' averages skip."
            },
            "precededByGap": {
              "type": "boolean",
              "description": "Whether beats HealthKit couldn't measure came before it, so the time since the beat before isn't an interval between two beats."
            }
          },
          "required": [
            "time",
            "interval",
            "precededByGap"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Heartbeat Series Beats",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Heartbeat Series Beats"
  },
  {
    "name": "audiograms",
    "description": "Audiograms (hearing test results, from the Hearing Test on AirPods Pro or another app) that started in a period, newest first, as lil health's Audiogram page shows them: each ear's hearing level (its average in dBHL) and what it means (e.g. Mild Hearing Loss), and each frequency tested with each ear's sensitivity in dBHL, how it was tested (conduction, masking) and whether the result is a bound (clamped), with the period's count. A screening result, not a diagnosis.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day weeks; Y the 12 calendar months ending with that day's month, in months (the last one ends with `date`)."
        },
        "date": {
          "type": "string",
          "description": "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to today."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "range"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "range": {
          "type": "string",
          "description": "The range asked for: D, W, M, 6M or Y."
        },
        "start": {
          "type": "string",
          "description": "When the period starts."
        },
        "end": {
          "type": "string",
          "description": "When the period ends (exclusive)."
        },
        "count": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "Audiograms that start in the period, all of them."
        },
        "audiograms": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthAudiogramItem"
          },
          "description": "The audiograms, newest first, at most 30."
        }
      },
      "required": [
        "timeZone",
        "range",
        "start",
        "end",
        "count",
        "audiograms"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthAudiogramEar": {
          "type": "object",
          "properties": {
            "hearingLevel": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The ear's hearing level, in whole dBHL, as lil health's Audiogram page shows it: the average of its charted sensitivities at 500, 1000, 2000 and 4000 Hz (the speech range), or of every frequency tested if none of those was. Null if the ear wasn't tested (Not Tested on the page)."
            },
            "hearingLoss": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "What the hearing level means, as the page says it: Little to No Hearing Loss (up to 25 dBHL), Mild Hearing Loss (up to 40), Moderate Hearing Loss (up to 60), Severe Hearing Loss (up to 80) or Profound Hearing Loss. Null if the ear wasn't tested."
            }
          },
          "required": [
            "hearingLevel",
            "hearingLoss"
          ],
          "additionalProperties": true
        },
        "HealthAudiogramTest": {
          "type": "object",
          "properties": {
            "sensitivity": {
              "type": "number",
              "description": "The quietest sound heard at this frequency, in dBHL (decibels hearing level): 0 is typical hearing, and higher means a louder sound was needed. Can be below 0."
            },
            "conduction": {
              "type": "string",
              "description": "How the sound was played: Air (through headphones or the air, as hearing tests do), or Unknown for a kind a later iOS adds."
            },
            "masked": {
              "type": "boolean",
              "description": "Whether the other ear was masked with noise during the test."
            },
            "clamped": {
              "type": "boolean",
              "description": "Whether the result is a bound rather than a threshold: the test has a clamping range (clampingLower, clampingUpper), and the threshold lies within it. A lower bound alone means no response up to the device's loudest, so the threshold is at or past sensitivity; lil health's chart marks it with a down arrow."
            },
            "clampingLower": {
              "type": "number",
              "description": "The clamping range's lower bound, in dBHL. Left out without one."
            },
            "clampingUpper": {
              "type": "number",
              "description": "The clamping range's upper bound, in dBHL. Left out without one."
            }
          },
          "required": [
            "sensitivity",
            "conduction",
            "masked",
            "clamped"
          ],
          "additionalProperties": true
        },
        "HealthAudiogramPoint": {
          "type": "object",
          "properties": {
            "frequency": {
              "type": "number",
              "description": "The tone's frequency, in Hz, e.g. 1000."
            },
            "left": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthAudiogramTest"
              },
              "description": "The left ear's tests at this frequency, the one lil health charts and averages first (air conduction, unmasked before masked), then any others as recorded. Empty if that ear wasn't tested here."
            },
            "right": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthAudiogramTest"
              },
              "description": "The right ear's tests at this frequency, the one lil health charts and averages first (air conduction, unmasked before masked), then any others as recorded. Empty if that ear wasn't tested here."
            }
          },
          "required": [
            "frequency",
            "left",
            "right"
          ],
          "additionalProperties": true
        },
        "HealthAudiogramItem": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "HealthKit's UUID for the audiogram."
            },
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "end": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "recordedTimeZone": {
              "type": "string",
              "description": "The time zone it was recorded in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo, as an IANA name. Left out when it has none, or one that isn't an IANA name. Its other times stay in the output's `timeZone`, so they compare across records."
            },
            "recordedStart": {
              "type": "string",
              "description": "When it starts, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "recordedEnd": {
              "type": "string",
              "description": "When it ends, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "leftEar": {
              "$ref": "#/$defs/HealthAudiogramEar"
            },
            "rightEar": {
              "$ref": "#/$defs/HealthAudiogramEar"
            },
            "points": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthAudiogramPoint"
              },
              "description": "Each frequency tested, as recorded (lowest first), with each ear's results. Empty if none can be read."
            },
            "source": {
              "type": "string",
              "description": "The app or device that recorded it, e.g. AirPods Pro's Hearing Test."
            }
          },
          "required": [
            "id",
            "start",
            "end",
            "leftEar",
            "rightEar",
            "points",
            "source"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Audiograms",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Audiograms"
  },
  {
    "name": "health_documents",
    "description": "Health Documents (clinical documents in HL7's CDA format, such as a visit summary a provider sent, that the person shared with Health) whose date is in a period, newest first, as lil health's Health Documents page lists them: each one's title, patient, author, custodian (the organization that keeps it), date and source, with the period's count. What a document says (diagnoses, medications, test results, the patient's details) comes from health_document, a page at a time: ask for it only when its title and names aren't enough.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day weeks; Y the 12 calendar months ending with that day's month, in months (the last one ends with `date`)."
        },
        "date": {
          "type": "string",
          "description": "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to today."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "range"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "range": {
          "type": "string",
          "description": "The range asked for: D, W, M, 6M or Y."
        },
        "start": {
          "type": "string",
          "description": "When the period starts."
        },
        "end": {
          "type": "string",
          "description": "When the period ends (exclusive)."
        },
        "count": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "Health Documents that start in the period, all of them."
        },
        "documents": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthDocumentItem"
          },
          "description": "The documents, newest first, at most 100."
        }
      },
      "required": [
        "timeZone",
        "range",
        "start",
        "end",
        "count",
        "documents"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthDocumentItem": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "HealthKit's UUID for the document."
            },
            "title": {
              "type": "string",
              "description": "The document's title, as HealthKit read it from the document (e.g. Visit Summary), or Health Document if it has none, as lil health's Health Documents page shows it."
            },
            "patient": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Who the document is about, as HealthKit read it from the document and lil health's Health Documents page shows it (its Patient row). Null if HealthKit found none."
            },
            "author": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "Who wrote it: a clinician, or the system that made it, as HealthKit read it from the document and lil health's Health Documents page shows it (its Author row). Null if HealthKit found none."
            },
            "custodian": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The organization that keeps it, e.g. a clinic, as HealthKit read it from the document and lil health's Health Documents page shows it (its Custodian row). Null if HealthKit found none."
            },
            "start": {
              "type": "string",
              "description": "The document's date (its Date on lil health's page), as the app that saved it to Health dated it: usually the visit or period it covers."
            },
            "end": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "recordedTimeZone": {
              "type": "string",
              "description": "The time zone it was recorded in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo, as an IANA name. Left out when it has none, or one that isn't an IANA name. Its other times stay in the output's `timeZone`, so they compare across records."
            },
            "recordedStart": {
              "type": "string",
              "description": "When it starts, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "recordedEnd": {
              "type": "string",
              "description": "When it ends, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "source": {
              "type": "string",
              "description": "The app that saved it to Health, e.g. a clinic's or a health records app."
            }
          },
          "required": [
            "id",
            "title",
            "patient",
            "author",
            "custodian",
            "start",
            "end",
            "source"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Documents",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Documents"
  },
  {
    "name": "health_document",
    "description": "One Health Document's content: its CDA XML, as the provider wrote it, 40,000 characters a page, in order. By its ID, from health_documents, whose titles and names usually answer what's asked: call this only to read what a document says, such as its diagnoses, medications or test results. The XML is decoded as text by its byte order mark or XML declaration (UTF-8, UTF-16, ISO-8859-1 or windows-1252; UTF-8 otherwise).",
    "inputSchema": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "description": "A document's ID, from health_documents."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        },
        "cursor": {
          "type": "string",
          "description": "The previous page's nextCursor."
        },
        "limit": {
          "type": "integer",
          "minimum": 1,
          "maximum": 40000,
          "description": "Characters per page, at most 40,000, the default. A page never splits a character outside the Basic Multilingual Plane, so it can have one more."
        }
      },
      "required": [
        "id"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "id": {
          "type": "string",
          "description": "The document's ID."
        },
        "title": {
          "type": "string",
          "description": "Its title, as health_documents gives it."
        },
        "start": {
          "type": "string",
          "description": "The document's date."
        },
        "length": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "How long the document's XML is, in characters (UTF-16 code units, as JavaScript counts a string's length: a character outside the Basic Multilingual Plane, such as an emoji, is 2)."
        },
        "offset": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "Where this page starts in the XML, in the same characters."
        },
        "xml": {
          "type": "string",
          "description": "This page of the document's CDA XML, exactly as the provider wrote it (namespace urn:hl7-org:v3), decoded as text: the header (recordTarget is the patient, with their address and birth date; author, custodian, the visit), then the structured body, each <section> a <title>, a human-readable <text> (paragraphs, lists, tables) and coded <entry>s that repeat it with codes (e.g. SNOMED CT, LOINC, RxNorm), values, units and reference ranges. A page can end inside an element: the next page goes on from there."
        },
        "nextCursor": {
          "anyOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ],
          "description": "Pass it as `cursor` for the next page; null on the last page."
        }
      },
      "required": [
        "timeZone",
        "id",
        "title",
        "start",
        "length",
        "offset",
        "xml",
        "nextCursor"
      ],
      "additionalProperties": true
    },
    "annotations": {
      "title": "Health Document",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Document"
  },
  {
    "name": "medications",
    "description": "The medications the person shares with lil health, with their form and schedule, how many scheduled doses they took over the last 7 and 30 days, when they last took each, and their clinical codes (e.g. RxNorm). medication_doses lists each dose logged.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "medications": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthMedicationItem"
          },
          "description": "Current medications, then archived ones, by name."
        }
      },
      "required": [
        "timeZone",
        "medications"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthMedicationCoding": {
          "type": "object",
          "properties": {
            "system": {
              "type": "string",
              "description": "The coding system, as HealthKit names it, e.g. http://www.nlm.nih.gov/research/umls/rxnorm."
            },
            "version": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The system's version, or null."
            },
            "code": {
              "type": "string",
              "description": "The code in that system, e.g. an RxNorm RxCUI."
            }
          },
          "required": [
            "system",
            "version",
            "code"
          ],
          "additionalProperties": true
        },
        "HealthMedicationItem": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string"
            },
            "name": {
              "type": "string",
              "description": "The name the person gave it, else Health's."
            },
            "healthName": {
              "type": "string",
              "description": "The name Health shows for it."
            },
            "form": {
              "type": "string",
              "description": "Its general form, as HealthKit names it, e.g. tablet or capsule."
            },
            "archived": {
              "type": "boolean"
            },
            "scheduled": {
              "type": "boolean",
              "description": "Whether it's taken on a schedule, rather than as needed."
            },
            "last7Days": {
              "type": "object",
              "properties": {
                "scheduled": {
                  "type": "integer",
                  "minimum": -9007199254740991,
                  "maximum": 9007199254740991,
                  "description": "Scheduled doses that were due."
                },
                "taken": {
                  "type": "integer",
                  "minimum": -9007199254740991,
                  "maximum": 9007199254740991,
                  "description": "Of those, how many were logged as taken."
                },
                "asNeeded": {
                  "type": "integer",
                  "minimum": -9007199254740991,
                  "maximum": 9007199254740991,
                  "description": "Doses taken as needed."
                }
              },
              "required": [
                "scheduled",
                "taken",
                "asNeeded"
              ],
              "additionalProperties": true,
              "description": "Adherence over today and the 6 days before."
            },
            "last30Days": {
              "type": "object",
              "properties": {
                "scheduled": {
                  "type": "integer",
                  "minimum": -9007199254740991,
                  "maximum": 9007199254740991,
                  "description": "Scheduled doses that were due."
                },
                "taken": {
                  "type": "integer",
                  "minimum": -9007199254740991,
                  "maximum": 9007199254740991,
                  "description": "Of those, how many were logged as taken."
                },
                "asNeeded": {
                  "type": "integer",
                  "minimum": -9007199254740991,
                  "maximum": 9007199254740991,
                  "description": "Doses taken as needed."
                }
              },
              "required": [
                "scheduled",
                "taken",
                "asNeeded"
              ],
              "additionalProperties": true,
              "description": "Adherence over today and the 29 days before."
            },
            "lastTaken": {
              "anyOf": [
                {
                  "type": "string",
                  "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
                },
                {
                  "type": "null"
                }
              ],
              "description": "When a dose was last logged as taken, or null."
            },
            "codings": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthMedicationCoding"
              },
              "description": "Codes for it in clinical coding systems (HKClinicalCoding), which name the drug exactly, e.g. RxNorm's, as Health has them. Empty if Health has none."
            }
          },
          "required": [
            "id",
            "name",
            "healthName",
            "form",
            "archived",
            "scheduled",
            "last7Days",
            "last30Days",
            "lastTaken",
            "codings"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Medications",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Medications"
  },
  {
    "name": "medication_doses",
    "description": "The dose log of the medications the person shares: each dose in a period, newest first, a page at a time, in the words of lil health's Medications page: which medication, whether it was taken, skipped, snoozed or not logged, scheduled or as needed, when it was logged and when it was due, and the amount, with the period's count. A dose counts on the day it was due (or was logged, if taken as needed). For adherence over the last 7 and 30 days, use medications.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period, ending on `date`: D is that day, in hours; W the 7 days ending that day, in days; M the 30 days ending that day, in days; 6M the 26 weeks ending that day, in 7-day weeks; Y the 12 calendar months ending with that day's month, in months (the last one ends with `date`)."
        },
        "date": {
          "type": "string",
          "description": "The last day of the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to today."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        },
        "medication": {
          "type": "string",
          "description": "Only this medication's doses, by the ID medications gives it."
        },
        "cursor": {
          "type": "string",
          "description": "The previous page's nextCursor."
        },
        "limit": {
          "type": "integer",
          "minimum": 1,
          "maximum": 250,
          "description": "Doses per page, at most 250. Defaults to 100."
        }
      },
      "required": [
        "range"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "range": {
          "type": "string",
          "description": "The range asked for: D, W, M, 6M or Y."
        },
        "start": {
          "type": "string",
          "description": "When the period starts."
        },
        "end": {
          "type": "string",
          "description": "When the period ends (exclusive)."
        },
        "count": {
          "type": "integer",
          "minimum": -9007199254740991,
          "maximum": 9007199254740991,
          "description": "Doses in the period, of every page: the medication's, if one was asked for."
        },
        "doses": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthMedicationDoseItem"
          },
          "description": "This page's doses, newest first by when they were due (or logged, for one taken as needed), as lil health's dose log lists them."
        },
        "nextCursor": {
          "anyOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ],
          "description": "Pass it as `cursor` for the next, older page; null on the last page."
        }
      },
      "required": [
        "timeZone",
        "range",
        "start",
        "end",
        "count",
        "doses",
        "nextCursor"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthMedicationDoseItem": {
          "type": "object",
          "properties": {
            "medicationId": {
              "type": "string",
              "description": "The medication's ID, as medications gives it."
            },
            "medication": {
              "type": "string",
              "description": "The medication's name: the one the person gave it, else Health's."
            },
            "status": {
              "type": "string",
              "description": "What happened to it, as lil health's Medications page says it: Taken, Skipped, Snoozed, Not Logged (a scheduled dose nobody logged, or a status the person undid), Reminder Not Sent, or Unknown for one a later iOS adds."
            },
            "schedule": {
              "type": "string",
              "description": "Scheduled (due at scheduledTime) or As Needed, or Unknown for one a later iOS adds."
            },
            "time": {
              "type": "string",
              "description": "When it was logged (taken, skipped or snoozed), or for a scheduled dose nobody logged, when Health marked it."
            },
            "scheduledTime": {
              "anyOf": [
                {
                  "type": "string",
                  "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
                },
                {
                  "type": "null"
                }
              ],
              "description": "When it was due, for a scheduled dose; null for one taken as needed. A dose belongs to the day it was due, however long before or after it was logged."
            },
            "recordedTimeZone": {
              "type": "string",
              "description": "The time zone it was recorded in (HKMetadataKeyTimeZone), e.g. Asia/Tokyo, as an IANA name. Left out when it has none, or one that isn't an IANA name. Its other times stay in the output's `timeZone`, so they compare across records."
            },
            "recordedTime": {
              "type": "string",
              "description": "Its time, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "recordedScheduledTime": {
              "type": "string",
              "description": "When it was due, on recordedTimeZone's clock, to the second, with that zone's UTC offset, e.g. 2026-08-10T23:00:00+09:00: the same instant as in the output's `timeZone`. Only with recordedTimeZone."
            },
            "amount": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The dose logged, in `unit`, or null: usually only a taken dose has one."
            },
            "scheduledAmount": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The dose scheduled, in `unit`, or null for one taken as needed."
            },
            "unit": {
              "type": "string",
              "description": "The amounts' unit, as HealthKit writes it, e.g. mg or mL; count is the medication's own units, its form's (tablets, capsules, puffs…)."
            },
            "source": {
              "type": "string",
              "description": "The app or device it was logged in, e.g. Health."
            }
          },
          "required": [
            "medicationId",
            "medication",
            "status",
            "schedule",
            "time",
            "scheduledTime",
            "amount",
            "scheduledAmount",
            "unit",
            "source"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Medication Doses",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Medication Doses"
  },
  {
    "name": "health_details",
    "description": "The person's health details as Health keeps them: date of birth and age, sex, blood type, skin type and wheelchair use (null when not set), and their vision prescriptions.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "dateOfBirth": {
          "anyOf": [
            {
              "type": "string",
              "description": "A day in the output's `timeZone`, as YYYY-MM-DD."
            },
            {
              "type": "null"
            }
          ]
        },
        "age": {
          "anyOf": [
            {
              "type": "integer",
              "minimum": -9007199254740991,
              "maximum": 9007199254740991
            },
            {
              "type": "null"
            }
          ],
          "description": "Years, as of today."
        },
        "sex": {
          "anyOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ],
          "description": "As Health records it: female, male or other. Null if not set."
        },
        "bloodType": {
          "anyOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ],
          "description": "E.g. A+ or O-."
        },
        "fitzpatrickSkinType": {
          "anyOf": [
            {
              "type": "string"
            },
            {
              "type": "null"
            }
          ],
          "description": "I to VI."
        },
        "wheelchairUse": {
          "anyOf": [
            {
              "type": "boolean"
            },
            {
              "type": "null"
            }
          ]
        },
        "visionPrescriptions": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthVisionPrescriptionItem"
          },
          "description": "Glasses and contacts prescriptions the person shares, newest first."
        }
      },
      "required": [
        "timeZone",
        "dateOfBirth",
        "age",
        "sex",
        "bloodType",
        "fitzpatrickSkinType",
        "wheelchairUse",
        "visionPrescriptions"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthVisionPrescriptionItem": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string"
            },
            "kind": {
              "type": "string",
              "description": "glasses or contacts."
            },
            "issued": {
              "type": "string",
              "description": "A day in the output's `timeZone`, as YYYY-MM-DD."
            },
            "expires": {
              "anyOf": [
                {
                  "type": "string",
                  "description": "A day in the output's `timeZone`, as YYYY-MM-DD."
                },
                {
                  "type": "null"
                }
              ]
            },
            "brand": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "A contacts lens brand."
            },
            "rightEye": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "sphere": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "Diopters."
                    },
                    "cylinder": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "Diopters."
                    },
                    "axis": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "Degrees."
                    },
                    "addPower": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "Diopters."
                    }
                  },
                  "required": [
                    "sphere",
                    "cylinder",
                    "axis",
                    "addPower"
                  ],
                  "additionalProperties": true
                },
                {
                  "type": "null"
                }
              ],
              "description": "The right eye (OD), or null if not covered."
            },
            "leftEye": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "sphere": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "Diopters."
                    },
                    "cylinder": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "Diopters."
                    },
                    "axis": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "Degrees."
                    },
                    "addPower": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "Diopters."
                    }
                  },
                  "required": [
                    "sphere",
                    "cylinder",
                    "axis",
                    "addPower"
                  ],
                  "additionalProperties": true
                },
                {
                  "type": "null"
                }
              ],
              "description": "The left eye (OS), or null if not covered."
            }
          },
          "required": [
            "id",
            "kind",
            "issued",
            "expires",
            "brand",
            "rightEye",
            "leftEye"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Details",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Details"
  },
  {
    "name": "search",
    "description": "Finds data types (and medications) by name, e.g. 'blood pressure', 'vo2' or 'sleep', to get the identifiers metric and samples take. Matches every type lil health knows, saying which have data.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "query": {
          "type": "string",
          "minLength": 1,
          "maxLength": 100,
          "description": "Words to look for in names, case-insensitive."
        }
      },
      "required": [
        "query"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "types": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthSearchType"
          },
          "description": "Data types whose name or category matches, those with data first."
        },
        "medications": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthSearchMedication"
          },
          "description": "Medications whose name matches."
        }
      },
      "required": [
        "types",
        "medications"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthSearchType": {
          "type": "object",
          "properties": {
            "type": {
              "type": "string",
              "description": "A HealthKit type identifier, e.g. HKQuantityTypeIdentifierStepCount or HKCategoryTypeIdentifierSleepAnalysis. list_types and search return them."
            },
            "name": {
              "type": "string"
            },
            "category": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ]
            },
            "hasData": {
              "type": "boolean",
              "description": "Whether the person has any of it."
            }
          },
          "required": [
            "type",
            "name",
            "category",
            "hasData"
          ],
          "additionalProperties": true
        },
        "HealthSearchMedication": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string"
            },
            "name": {
              "type": "string"
            }
          },
          "required": [
            "id",
            "name"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Search Health Data",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Search Health Data"
  },
  {
    "name": "sync_status",
    "description": "How fresh the data is: the newest sample, and each iPhone that uploads Health data, when it last reported and which one totals come from. Check it when data looks missing or out of date.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "latestSample": {
          "anyOf": [
            {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            {
              "type": "null"
            }
          ],
          "description": "When the most recent sample that has started starts, or null without data."
        },
        "iPhones": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthSyncIPhone"
          },
          "description": "The iPhones uploading Health data, most recently reported first."
        }
      },
      "required": [
        "timeZone",
        "latestSample",
        "iPhones"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthSyncIPhone": {
          "type": "object",
          "properties": {
            "device": {
              "type": "string",
              "description": "lil's ID for the iPhone."
            },
            "pairedWithWatch": {
              "type": "boolean"
            },
            "lastReported": {
              "type": "string",
              "description": "When its last upload of statistics was applied."
            },
            "statisticsSource": {
              "type": "boolean",
              "description": "Whether totals come from this iPhone's statistics."
            }
          },
          "required": [
            "device",
            "pairedWithWatch",
            "lastReported",
            "statisticsSource"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Health Sync Status",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Health Sync Status"
  },
  {
    "name": "list_cards",
    "description": "Lists the cards on lil health's Summary, in order: each card's id, spec (what it charts and how it looks), position and when it was made and changed. Use get_card for a card's data.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "cards": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthCardItem"
          },
          "description": "Every card, in Summary's order."
        }
      },
      "required": [
        "timeZone",
        "cards"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthCardItem": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "A card's id, e.g. card_seed_steps or card_01JZ…: list_cards lists them."
            },
            "spec": {
              "type": "object",
              "description": "The card's spec in canonical form, every default filled in (version 1): version, display, series, formulas, bucket, range and chart."
            },
            "position": {
              "type": "string",
              "description": "Its place on Summary: cards are in ascending order of position (by bytes), then id."
            },
            "seed": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The welcome card it started as (steps, heart_rate…), else null."
            },
            "createdAt": {
              "type": "string",
              "description": "When it was made."
            },
            "updatedAt": {
              "type": "string",
              "description": "When it was last changed or moved."
            }
          },
          "required": [
            "id",
            "spec",
            "position",
            "seed",
            "createdAt",
            "updatedAt"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "List Cards",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "List Cards"
  },
  {
    "name": "get_card",
    "description": "A card and its data: its spec run over a period of the person's Health data, as the card's page shows it, with each series' points, its formulas and the period's summary.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "description": "A card's id, e.g. card_seed_steps or card_01JZ…: list_cards lists them."
        },
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period to run it over: D a calendar day, W a calendar week, M a calendar month, 6M six calendar months, Y a calendar year, containing `date`. One of the card's bucket's ranges. Defaults to the card's own."
        },
        "date": {
          "type": "string",
          "description": "A day in the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to the period the card's page opens on: its latest value's, as its Summary row shows it (today's without one)."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        },
        "firstWeekday": {
          "type": "string",
          "enum": [
            "sunday",
            "monday",
            "tuesday",
            "wednesday",
            "thursday",
            "friday",
            "saturday"
          ],
          "description": "The day weeks start on. Defaults to monday."
        }
      },
      "required": [
        "id"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "card": {
          "$ref": "#/$defs/HealthCardItem"
        },
        "data": {
          "$ref": "#/$defs/HealthCardData"
        }
      },
      "required": [
        "card",
        "data"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthCardItem": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "A card's id, e.g. card_seed_steps or card_01JZ…: list_cards lists them."
            },
            "spec": {
              "type": "object",
              "description": "The card's spec in canonical form, every default filled in (version 1): version, display, series, formulas, bucket, range and chart."
            },
            "position": {
              "type": "string",
              "description": "Its place on Summary: cards are in ascending order of position (by bytes), then id."
            },
            "seed": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The welcome card it started as (steps, heart_rate…), else null."
            },
            "createdAt": {
              "type": "string",
              "description": "When it was made."
            },
            "updatedAt": {
              "type": "string",
              "description": "When it was last changed or moved."
            }
          },
          "required": [
            "id",
            "spec",
            "position",
            "seed",
            "createdAt",
            "updatedAt"
          ],
          "additionalProperties": true
        },
        "HealthCardPoint": {
          "type": "object",
          "properties": {
            "start": {
              "type": "string",
              "description": "When the bucket starts (a night's is midnight of the day it ends on)."
            },
            "value": {
              "type": "number",
              "description": "The aggregation over the bucket, in `unit`."
            },
            "minimum": {
              "type": "number",
              "description": "The bucket's lowest reading."
            },
            "maximum": {
              "type": "number",
              "description": "The bucket's highest reading."
            },
            "readings": {
              "anyOf": [
                {
                  "type": "integer",
                  "minimum": -9007199254740991,
                  "maximum": 9007199254740991
                },
                {
                  "type": "null"
                }
              ],
              "description": "How many readings it has; null for totals."
            }
          },
          "required": [
            "start",
            "value",
            "minimum",
            "maximum",
            "readings"
          ],
          "additionalProperties": true
        },
        "HealthCardSeriesData": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string"
            },
            "label": {
              "type": "string",
              "description": "Its label, or its type's name."
            },
            "type": {
              "type": "string",
              "description": "Its HealthKit type identifier."
            },
            "aggregation": {
              "type": "string"
            },
            "unit": {
              "type": "string",
              "description": "The values' HealthKit unit, e.g. count/min, or count for a count of readings."
            },
            "hidden": {
              "type": "boolean"
            },
            "points": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthCardPoint"
              },
              "description": "One per bucket with a value, oldest first."
            }
          },
          "required": [
            "id",
            "label",
            "type",
            "aggregation",
            "unit",
            "hidden",
            "points"
          ],
          "additionalProperties": true
        },
        "HealthCardFormulaPoint": {
          "type": "object",
          "properties": {
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "value": {
              "type": "number"
            }
          },
          "required": [
            "start",
            "value"
          ],
          "additionalProperties": true
        },
        "HealthCardFormulaData": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string"
            },
            "kind": {
              "type": "string",
              "description": "movingAverage or difference."
            },
            "label": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ]
            },
            "unit": {
              "type": "string"
            },
            "hidden": {
              "type": "boolean"
            },
            "points": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthCardFormulaPoint"
              }
            }
          },
          "required": [
            "id",
            "kind",
            "label",
            "unit",
            "hidden",
            "points"
          ],
          "additionalProperties": true
        },
        "HealthCardData": {
          "type": "object",
          "properties": {
            "range": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The range it was run over."
            },
            "start": {
              "type": "string",
              "description": "The period's first day."
            },
            "end": {
              "type": "string",
              "description": "The period's last day."
            },
            "timeZone": {
              "type": "string",
              "description": "The IANA time zone of the output's days and local times."
            },
            "firstWeekday": {
              "type": "string"
            },
            "bucket": {
              "type": "string",
              "description": "The spec's bucket."
            },
            "grain": {
              "type": "string",
              "description": "What each point covers, once auto is resolved: hour, day, week or month."
            },
            "series": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthCardSeriesData"
              }
            },
            "formulas": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthCardFormulaData"
              }
            },
            "summary": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "kind": {
                      "type": "string",
                      "description": "What the card's header shows: total, average, dailyAverage, range, lowest, highest, first, latest or count."
                    },
                    "value": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "Null for a range."
                    },
                    "minimum": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "A range's lowest reading."
                    },
                    "maximum": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "A range's highest reading."
                    }
                  },
                  "required": [
                    "kind",
                    "value",
                    "minimum",
                    "maximum"
                  ],
                  "additionalProperties": true
                },
                {
                  "type": "null"
                }
              ],
              "description": "The period's summary, from the lead series; null without data."
            },
            "goal": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The goal line's value, in the lead's unit, or null."
            }
          },
          "required": [
            "range",
            "start",
            "end",
            "timeZone",
            "firstWeekday",
            "bucket",
            "grain",
            "series",
            "formulas",
            "summary",
            "goal"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Get Card",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Get Card"
  },
  {
    "name": "preview_card",
    "description": "Checks a draft card spec and runs it over the person's Health data, without saving anything: start here to make a card. If the spec has errors, the call fails listing every one with its path and how to fix it; otherwise it returns the canonical spec and the data the card would show. Fix and preview again until it's right, then create_card (or update_card) with the spec.\n\nA card spec is JSON. Only version (1, or 2 for a workout window's location), display.name and each series' type are required: leave the rest out for their defaults. Outputs give the canonical form, every default filled in, at the lowest version that has what it uses.\n- display: name (1-40 characters), symbol (one of the schema's SF Symbols; default the type's), color (red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray; default the type's), unit (e.g. kg, lb, degF, km; null for the person's locale).\n- series: 1 to 4, sharing one axis, so one unit. Each is a quantity type (an identifier, or a name such as \"Heart Rate\": list_types and search find them) and an aggregation per bucket (sum, avg, min, max, first, latest, count): types that add up (steps, energy, distance) take sum only, others avg (the default), min, max, first, latest or count. Optional: id (a, b, c, d by default), label, hidden.\n- window, for types that don't add up, keeps readings that start in it: {\"kind\": \"asleep\"}, {\"kind\": \"beforeSleep\", \"minutes\": 5} or {\"kind\": \"afterWaking\", \"minutes\": 30} (1-240 minutes, around each night's main sleep), {\"kind\": \"workout\", \"activities\": [37]} (HKWorkoutActivityType values or names; null for every workout; with version 2, \"location\": \"indoor\" or \"outdoor\" keeps only workouts the workouts tool's indoor says were there, leaving out those that don't say, e.g. {\"kind\": \"workout\", \"activities\": [\"Running\"], \"location\": \"outdoor\"} for outdoor runs), {\"kind\": \"timeOfDay\", \"from\": \"00:00\", \"to\": \"12:00\"} (the local clock; may cross midnight). filter: {\"sources\": [bundle IDs], \"deviceModels\": [\"Watch\"]}.\n- bucket, what one point covers (auto, hour, day, night, week, month): auto (the default) is hours at D, days at W and M, weeks at 6M and months at Y. hour takes ranges D and W; day W, M, 6M and Y; week M, 6M and Y; month 6M and Y; night (a point per night) any, and needs a series with a sleep window. Sleep windows need night, week or month.\n- range, the period it opens on (D, W, M, 6M, Y): a calendar day, week, month, six months or year. Default W, or the bucket's first.\n- formulas, up to 2: {\"kind\": \"movingAverage\", \"of\": \"a\", \"points\": 7} (2-30 points) or {\"kind\": \"difference\", \"of\": [\"a\", \"b\"]} (a minus b). Hide a series to show only a formula.\n- chart: style (bars, ranges, dots, line; default the type's), goal ({\"value\": 10000}, in the lead series' unit).\nExamples:\n- body temperature as a line: {\"version\":1,\"display\":{\"name\":\"Body Temperature\",\"symbol\":\"thermometer.medium\",\"color\":\"red\"},\"series\":[{\"type\":\"BodyTemperature\"}],\"range\":\"M\",\"chart\":{\"style\":\"line\"}}\n- heart rate while asleep, per night: {\"version\":1,\"display\":{\"name\":\"Sleeping Heart Rate\",\"symbol\":\"moon.zzz.fill\",\"color\":\"indigo\"},\"series\":[{\"type\":\"HeartRate\",\"window\":{\"kind\":\"asleep\"}}],\"bucket\":\"night\",\"range\":\"M\",\"chart\":{\"style\":\"line\"}}\n- HRV as dots, with a 7-point moving average: {\"version\":1,\"display\":{\"name\":\"HRV\",\"symbol\":\"waveform.path.ecg\",\"color\":\"pink\"},\"series\":[{\"type\":\"HeartRateVariabilitySDNN\"}],\"formulas\":[{\"id\":\"trend\",\"kind\":\"movingAverage\",\"of\":\"a\",\"points\":7}],\"range\":\"M\",\"chart\":{\"style\":\"dots\"}}\n- heart rate in the 5 minutes before falling asleep, per night: {\"version\":1,\"display\":{\"name\":\"Heart Rate Before Sleep\",\"symbol\":\"bed.double.fill\",\"color\":\"mint\"},\"series\":[{\"type\":\"Heart Rate\",\"window\":{\"kind\":\"beforeSleep\",\"minutes\":5}}],\"bucket\":\"night\",\"range\":\"M\",\"chart\":{\"style\":\"dots\"}}\n- the first weigh-in each day before noon, with a 7-day rolling average: {\"version\":1,\"display\":{\"name\":\"Morning Weight\",\"symbol\":\"scalemass.fill\",\"color\":\"purple\"},\"series\":[{\"type\":\"BodyMass\",\"aggregation\":\"first\",\"window\":{\"kind\":\"timeOfDay\",\"from\":\"00:00\",\"to\":\"12:00\"},\"label\":\"First weigh-in before noon\"}],\"formulas\":[{\"id\":\"trend\",\"kind\":\"movingAverage\",\"of\":\"a\",\"points\":7,\"label\":\"7-day rolling average\"}],\"bucket\":\"day\",\"range\":\"M\",\"chart\":{\"style\":\"dots\"}}",
    "inputSchema": {
      "type": "object",
      "properties": {
        "spec": {
          "type": "object",
          "properties": {
            "version": {
              "type": "integer",
              "enum": [
                1,
                2
              ],
              "description": "1, or 2 for a workout window's location."
            },
            "display": {
              "type": "object",
              "properties": {
                "name": {
                  "type": "string",
                  "minLength": 1,
                  "maxLength": 40
                },
                "symbol": {
                  "anyOf": [
                    {
                      "type": "string",
                      "enum": [
                        "flame.fill",
                        "figure",
                        "circle.dotted.circle",
                        "ear",
                        "heart.fill",
                        "pills.fill",
                        "brain.head.profile",
                        "figure.walk.motion",
                        "carrot.fill",
                        "lungs.fill",
                        "bed.double.fill",
                        "list.bullet.clipboard",
                        "waveform.path.ecg",
                        "plus",
                        "heart.text.square.fill",
                        "bolt.heart.fill",
                        "waveform",
                        "drop.fill",
                        "thermometer.medium",
                        "scalemass.fill",
                        "ruler.fill",
                        "eye.fill",
                        "hand.raised.fill",
                        "brain",
                        "cross.case.fill",
                        "figure.walk",
                        "figure.run",
                        "figure.stairs",
                        "figure.pool.swim",
                        "figure.outdoor.cycle",
                        "bicycle",
                        "figure.strengthtraining.traditional",
                        "figure.mind.and.body",
                        "figure.cooldown",
                        "bolt.fill",
                        "timer",
                        "stopwatch.fill",
                        "moon.fill",
                        "moon.zzz.fill",
                        "zzz",
                        "sun.max.fill",
                        "sunrise.fill",
                        "sunset.fill",
                        "clock.fill",
                        "alarm.fill",
                        "fork.knife",
                        "cup.and.saucer.fill",
                        "waterbottle.fill",
                        "leaf.fill",
                        "chart.line.uptrend.xyaxis",
                        "chart.bar.fill",
                        "gauge.with.dots.needle.50percent",
                        "star.fill",
                        "target",
                        "flag.fill"
                      ]
                    },
                    {
                      "type": "null"
                    }
                  ]
                },
                "color": {
                  "anyOf": [
                    {
                      "type": "string",
                      "enum": [
                        "red",
                        "orange",
                        "yellow",
                        "green",
                        "mint",
                        "teal",
                        "cyan",
                        "blue",
                        "indigo",
                        "purple",
                        "pink",
                        "brown",
                        "gray"
                      ]
                    },
                    {
                      "type": "null"
                    }
                  ]
                },
                "unit": {
                  "anyOf": [
                    {
                      "type": "string",
                      "enum": [
                        "kg",
                        "lb",
                        "st",
                        "cm",
                        "m",
                        "km",
                        "in",
                        "ft",
                        "yd",
                        "mi",
                        "degC",
                        "degF",
                        "km/hr",
                        "mi/hr",
                        "m/s",
                        "mL",
                        "L",
                        "fl_oz_us",
                        "kcal",
                        "kJ"
                      ]
                    },
                    {
                      "type": "null"
                    }
                  ]
                }
              },
              "required": [
                "name"
              ],
              "additionalProperties": false
            },
            "series": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "id": {
                    "anyOf": [
                      {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 16,
                        "pattern": "^[a-z][a-z0-9]{0,15}$"
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "type": {
                    "type": "string",
                    "description": "A quantity type: its HealthKit identifier (HKQuantityTypeIdentifierHeartRate), the identifier without its prefix (HeartRate) or the name lil health shows (\"Heart Rate\"), in any case. list_types and search find them."
                  },
                  "aggregation": {
                    "anyOf": [
                      {
                        "type": "string",
                        "enum": [
                          "sum",
                          "avg",
                          "min",
                          "max",
                          "first",
                          "latest",
                          "count"
                        ]
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "window": {
                    "anyOf": [
                      {
                        "anyOf": [
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "asleep"
                                ]
                              }
                            },
                            "required": [
                              "kind"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "beforeSleep"
                                ]
                              },
                              "minutes": {
                                "type": "integer",
                                "minimum": 1,
                                "maximum": 240
                              }
                            },
                            "required": [
                              "kind",
                              "minutes"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "afterWaking"
                                ]
                              },
                              "minutes": {
                                "type": "integer",
                                "minimum": 1,
                                "maximum": 240
                              }
                            },
                            "required": [
                              "kind",
                              "minutes"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "workout"
                                ]
                              },
                              "activities": {
                                "anyOf": [
                                  {
                                    "type": "array",
                                    "items": {
                                      "anyOf": [
                                        {
                                          "type": "integer"
                                        },
                                        {
                                          "type": "string"
                                        }
                                      ]
                                    },
                                    "description": "HKWorkoutActivityType raw values or names, e.g. 37 or \"Running\"; null for every workout."
                                  },
                                  {
                                    "type": "null"
                                  }
                                ]
                              },
                              "location": {
                                "anyOf": [
                                  {
                                    "type": "string",
                                    "enum": [
                                      "indoor",
                                      "outdoor"
                                    ],
                                    "description": "Spec version 2: only workouts indoors or outdoors, as the workouts tool's indoor says (workouts that don't say are left out); null for every workout."
                                  },
                                  {
                                    "type": "null"
                                  }
                                ]
                              }
                            },
                            "required": [
                              "kind"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "timeOfDay"
                                ]
                              },
                              "from": {
                                "type": "string",
                                "minLength": 5,
                                "maxLength": 5,
                                "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$"
                              },
                              "to": {
                                "type": "string",
                                "minLength": 5,
                                "maxLength": 5,
                                "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$"
                              }
                            },
                            "required": [
                              "kind",
                              "from",
                              "to"
                            ],
                            "additionalProperties": false
                          }
                        ]
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "filter": {
                    "anyOf": [
                      {
                        "type": "object",
                        "properties": {
                          "sources": {
                            "anyOf": [
                              {
                                "type": "array",
                                "items": {
                                  "type": "string",
                                  "minLength": 1,
                                  "maxLength": 200
                                },
                                "minItems": 1,
                                "maxItems": 10
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "deviceModels": {
                            "anyOf": [
                              {
                                "type": "array",
                                "items": {
                                  "type": "string",
                                  "minLength": 1,
                                  "maxLength": 200
                                },
                                "minItems": 1,
                                "maxItems": 10
                              },
                              {
                                "type": "null"
                              }
                            ]
                          }
                        },
                        "additionalProperties": false
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "label": {
                    "anyOf": [
                      {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 40
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "hidden": {
                    "anyOf": [
                      {
                        "type": "boolean"
                      },
                      {
                        "type": "null"
                      }
                    ]
                  }
                },
                "required": [
                  "type"
                ],
                "additionalProperties": false
              },
              "minItems": 1,
              "maxItems": 4
            },
            "formulas": {
              "anyOf": [
                {
                  "type": "array",
                  "items": {
                    "anyOf": [
                      {
                        "type": "object",
                        "properties": {
                          "id": {
                            "anyOf": [
                              {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 16,
                                "pattern": "^[a-z][a-z0-9]{0,15}$"
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "kind": {
                            "type": "string",
                            "enum": [
                              "movingAverage"
                            ]
                          },
                          "of": {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 16,
                            "pattern": "^[a-z][a-z0-9]{0,15}$"
                          },
                          "points": {
                            "anyOf": [
                              {
                                "type": "integer",
                                "minimum": 2,
                                "maximum": 30
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "label": {
                            "anyOf": [
                              {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 40
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "hidden": {
                            "anyOf": [
                              {
                                "type": "boolean"
                              },
                              {
                                "type": "null"
                              }
                            ]
                          }
                        },
                        "required": [
                          "kind",
                          "of"
                        ],
                        "additionalProperties": false
                      },
                      {
                        "type": "object",
                        "properties": {
                          "id": {
                            "anyOf": [
                              {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 16,
                                "pattern": "^[a-z][a-z0-9]{0,15}$"
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "kind": {
                            "type": "string",
                            "enum": [
                              "difference"
                            ]
                          },
                          "of": {
                            "type": "array",
                            "items": {
                              "type": "string",
                              "minLength": 1,
                              "maxLength": 16,
                              "pattern": "^[a-z][a-z0-9]{0,15}$"
                            },
                            "minItems": 2,
                            "maxItems": 2
                          },
                          "label": {
                            "anyOf": [
                              {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 40
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "hidden": {
                            "anyOf": [
                              {
                                "type": "boolean"
                              },
                              {
                                "type": "null"
                              }
                            ]
                          }
                        },
                        "required": [
                          "kind",
                          "of"
                        ],
                        "additionalProperties": false
                      }
                    ]
                  },
                  "maxItems": 2
                },
                {
                  "type": "null"
                }
              ]
            },
            "bucket": {
              "anyOf": [
                {
                  "type": "string",
                  "enum": [
                    "auto",
                    "hour",
                    "day",
                    "night",
                    "week",
                    "month"
                  ]
                },
                {
                  "type": "null"
                }
              ]
            },
            "range": {
              "anyOf": [
                {
                  "type": "string",
                  "enum": [
                    "D",
                    "W",
                    "M",
                    "6M",
                    "Y"
                  ]
                },
                {
                  "type": "null"
                }
              ]
            },
            "chart": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "style": {
                      "anyOf": [
                        {
                          "type": "string",
                          "enum": [
                            "bars",
                            "ranges",
                            "dots",
                            "line"
                          ]
                        },
                        {
                          "type": "null"
                        }
                      ]
                    },
                    "goal": {
                      "anyOf": [
                        {
                          "type": "object",
                          "properties": {
                            "value": {
                              "type": "number",
                              "minimum": 0
                            }
                          },
                          "required": [
                            "value"
                          ],
                          "additionalProperties": false
                        },
                        {
                          "type": "null"
                        }
                      ]
                    }
                  },
                  "additionalProperties": false
                },
                {
                  "type": "null"
                }
              ]
            }
          },
          "required": [
            "version",
            "display",
            "series"
          ],
          "additionalProperties": false,
          "description": "The card spec: JSON as the schema describes, with defaults left out as you like (preview_card's description explains it)."
        },
        "range": {
          "type": "string",
          "enum": [
            "D",
            "W",
            "M",
            "6M",
            "Y"
          ],
          "description": "The period to run it over: D a calendar day, W a calendar week, M a calendar month, 6M six calendar months, Y a calendar year, containing `date`. One of the card's bucket's ranges. Defaults to the card's own."
        },
        "date": {
          "type": "string",
          "description": "A day in the period, as YYYY-MM-DD in `timeZone`, from 2000 to 2999. Defaults to the period the card's page opens on: its latest value's, as its Summary row shows it (today's without one)."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        },
        "firstWeekday": {
          "type": "string",
          "enum": [
            "sunday",
            "monday",
            "tuesday",
            "wednesday",
            "thursday",
            "friday",
            "saturday"
          ],
          "description": "The day weeks start on. Defaults to monday."
        }
      },
      "required": [
        "spec"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "spec": {
          "type": "object",
          "description": "The spec in canonical form, as it would be saved."
        },
        "data": {
          "$ref": "#/$defs/HealthCardData"
        }
      },
      "required": [
        "spec",
        "data"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthCardPoint": {
          "type": "object",
          "properties": {
            "start": {
              "type": "string",
              "description": "When the bucket starts (a night's is midnight of the day it ends on)."
            },
            "value": {
              "type": "number",
              "description": "The aggregation over the bucket, in `unit`."
            },
            "minimum": {
              "type": "number",
              "description": "The bucket's lowest reading."
            },
            "maximum": {
              "type": "number",
              "description": "The bucket's highest reading."
            },
            "readings": {
              "anyOf": [
                {
                  "type": "integer",
                  "minimum": -9007199254740991,
                  "maximum": 9007199254740991
                },
                {
                  "type": "null"
                }
              ],
              "description": "How many readings it has; null for totals."
            }
          },
          "required": [
            "start",
            "value",
            "minimum",
            "maximum",
            "readings"
          ],
          "additionalProperties": true
        },
        "HealthCardSeriesData": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string"
            },
            "label": {
              "type": "string",
              "description": "Its label, or its type's name."
            },
            "type": {
              "type": "string",
              "description": "Its HealthKit type identifier."
            },
            "aggregation": {
              "type": "string"
            },
            "unit": {
              "type": "string",
              "description": "The values' HealthKit unit, e.g. count/min, or count for a count of readings."
            },
            "hidden": {
              "type": "boolean"
            },
            "points": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthCardPoint"
              },
              "description": "One per bucket with a value, oldest first."
            }
          },
          "required": [
            "id",
            "label",
            "type",
            "aggregation",
            "unit",
            "hidden",
            "points"
          ],
          "additionalProperties": true
        },
        "HealthCardFormulaPoint": {
          "type": "object",
          "properties": {
            "start": {
              "type": "string",
              "description": "A time in the output's `timeZone`, to the second, with its UTC offset, e.g. 2026-10-20T08:15:00+01:00."
            },
            "value": {
              "type": "number"
            }
          },
          "required": [
            "start",
            "value"
          ],
          "additionalProperties": true
        },
        "HealthCardFormulaData": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string"
            },
            "kind": {
              "type": "string",
              "description": "movingAverage or difference."
            },
            "label": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ]
            },
            "unit": {
              "type": "string"
            },
            "hidden": {
              "type": "boolean"
            },
            "points": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthCardFormulaPoint"
              }
            }
          },
          "required": [
            "id",
            "kind",
            "label",
            "unit",
            "hidden",
            "points"
          ],
          "additionalProperties": true
        },
        "HealthCardData": {
          "type": "object",
          "properties": {
            "range": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The range it was run over."
            },
            "start": {
              "type": "string",
              "description": "The period's first day."
            },
            "end": {
              "type": "string",
              "description": "The period's last day."
            },
            "timeZone": {
              "type": "string",
              "description": "The IANA time zone of the output's days and local times."
            },
            "firstWeekday": {
              "type": "string"
            },
            "bucket": {
              "type": "string",
              "description": "The spec's bucket."
            },
            "grain": {
              "type": "string",
              "description": "What each point covers, once auto is resolved: hour, day, week or month."
            },
            "series": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthCardSeriesData"
              }
            },
            "formulas": {
              "type": "array",
              "items": {
                "$ref": "#/$defs/HealthCardFormulaData"
              }
            },
            "summary": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "kind": {
                      "type": "string",
                      "description": "What the card's header shows: total, average, dailyAverage, range, lowest, highest, first, latest or count."
                    },
                    "value": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "Null for a range."
                    },
                    "minimum": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "A range's lowest reading."
                    },
                    "maximum": {
                      "anyOf": [
                        {
                          "type": "number"
                        },
                        {
                          "type": "null"
                        }
                      ],
                      "description": "A range's highest reading."
                    }
                  },
                  "required": [
                    "kind",
                    "value",
                    "minimum",
                    "maximum"
                  ],
                  "additionalProperties": true
                },
                {
                  "type": "null"
                }
              ],
              "description": "The period's summary, from the lead series; null without data."
            },
            "goal": {
              "anyOf": [
                {
                  "type": "number"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The goal line's value, in the lead's unit, or null."
            }
          },
          "required": [
            "range",
            "start",
            "end",
            "timeZone",
            "firstWeekday",
            "bucket",
            "grain",
            "series",
            "formulas",
            "summary",
            "goal"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Preview Card",
      "readOnlyHint": true,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Preview Card"
  },
  {
    "name": "create_card",
    "description": "Adds a card to the end of lil health's Summary, from a spec (preview_card describes specs: preview it first). A person can have up to 100 cards. Fails listing every error if the spec has any. Needs the person to have allowed this agent to manage cards; it never changes Health data. The change syncs to their Mac and iPhone.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "spec": {
          "type": "object",
          "properties": {
            "version": {
              "type": "integer",
              "enum": [
                1,
                2
              ],
              "description": "1, or 2 for a workout window's location."
            },
            "display": {
              "type": "object",
              "properties": {
                "name": {
                  "type": "string",
                  "minLength": 1,
                  "maxLength": 40
                },
                "symbol": {
                  "anyOf": [
                    {
                      "type": "string",
                      "enum": [
                        "flame.fill",
                        "figure",
                        "circle.dotted.circle",
                        "ear",
                        "heart.fill",
                        "pills.fill",
                        "brain.head.profile",
                        "figure.walk.motion",
                        "carrot.fill",
                        "lungs.fill",
                        "bed.double.fill",
                        "list.bullet.clipboard",
                        "waveform.path.ecg",
                        "plus",
                        "heart.text.square.fill",
                        "bolt.heart.fill",
                        "waveform",
                        "drop.fill",
                        "thermometer.medium",
                        "scalemass.fill",
                        "ruler.fill",
                        "eye.fill",
                        "hand.raised.fill",
                        "brain",
                        "cross.case.fill",
                        "figure.walk",
                        "figure.run",
                        "figure.stairs",
                        "figure.pool.swim",
                        "figure.outdoor.cycle",
                        "bicycle",
                        "figure.strengthtraining.traditional",
                        "figure.mind.and.body",
                        "figure.cooldown",
                        "bolt.fill",
                        "timer",
                        "stopwatch.fill",
                        "moon.fill",
                        "moon.zzz.fill",
                        "zzz",
                        "sun.max.fill",
                        "sunrise.fill",
                        "sunset.fill",
                        "clock.fill",
                        "alarm.fill",
                        "fork.knife",
                        "cup.and.saucer.fill",
                        "waterbottle.fill",
                        "leaf.fill",
                        "chart.line.uptrend.xyaxis",
                        "chart.bar.fill",
                        "gauge.with.dots.needle.50percent",
                        "star.fill",
                        "target",
                        "flag.fill"
                      ]
                    },
                    {
                      "type": "null"
                    }
                  ]
                },
                "color": {
                  "anyOf": [
                    {
                      "type": "string",
                      "enum": [
                        "red",
                        "orange",
                        "yellow",
                        "green",
                        "mint",
                        "teal",
                        "cyan",
                        "blue",
                        "indigo",
                        "purple",
                        "pink",
                        "brown",
                        "gray"
                      ]
                    },
                    {
                      "type": "null"
                    }
                  ]
                },
                "unit": {
                  "anyOf": [
                    {
                      "type": "string",
                      "enum": [
                        "kg",
                        "lb",
                        "st",
                        "cm",
                        "m",
                        "km",
                        "in",
                        "ft",
                        "yd",
                        "mi",
                        "degC",
                        "degF",
                        "km/hr",
                        "mi/hr",
                        "m/s",
                        "mL",
                        "L",
                        "fl_oz_us",
                        "kcal",
                        "kJ"
                      ]
                    },
                    {
                      "type": "null"
                    }
                  ]
                }
              },
              "required": [
                "name"
              ],
              "additionalProperties": false
            },
            "series": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "id": {
                    "anyOf": [
                      {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 16,
                        "pattern": "^[a-z][a-z0-9]{0,15}$"
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "type": {
                    "type": "string",
                    "description": "A quantity type: its HealthKit identifier (HKQuantityTypeIdentifierHeartRate), the identifier without its prefix (HeartRate) or the name lil health shows (\"Heart Rate\"), in any case. list_types and search find them."
                  },
                  "aggregation": {
                    "anyOf": [
                      {
                        "type": "string",
                        "enum": [
                          "sum",
                          "avg",
                          "min",
                          "max",
                          "first",
                          "latest",
                          "count"
                        ]
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "window": {
                    "anyOf": [
                      {
                        "anyOf": [
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "asleep"
                                ]
                              }
                            },
                            "required": [
                              "kind"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "beforeSleep"
                                ]
                              },
                              "minutes": {
                                "type": "integer",
                                "minimum": 1,
                                "maximum": 240
                              }
                            },
                            "required": [
                              "kind",
                              "minutes"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "afterWaking"
                                ]
                              },
                              "minutes": {
                                "type": "integer",
                                "minimum": 1,
                                "maximum": 240
                              }
                            },
                            "required": [
                              "kind",
                              "minutes"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "workout"
                                ]
                              },
                              "activities": {
                                "anyOf": [
                                  {
                                    "type": "array",
                                    "items": {
                                      "anyOf": [
                                        {
                                          "type": "integer"
                                        },
                                        {
                                          "type": "string"
                                        }
                                      ]
                                    },
                                    "description": "HKWorkoutActivityType raw values or names, e.g. 37 or \"Running\"; null for every workout."
                                  },
                                  {
                                    "type": "null"
                                  }
                                ]
                              },
                              "location": {
                                "anyOf": [
                                  {
                                    "type": "string",
                                    "enum": [
                                      "indoor",
                                      "outdoor"
                                    ],
                                    "description": "Spec version 2: only workouts indoors or outdoors, as the workouts tool's indoor says (workouts that don't say are left out); null for every workout."
                                  },
                                  {
                                    "type": "null"
                                  }
                                ]
                              }
                            },
                            "required": [
                              "kind"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "timeOfDay"
                                ]
                              },
                              "from": {
                                "type": "string",
                                "minLength": 5,
                                "maxLength": 5,
                                "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$"
                              },
                              "to": {
                                "type": "string",
                                "minLength": 5,
                                "maxLength": 5,
                                "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$"
                              }
                            },
                            "required": [
                              "kind",
                              "from",
                              "to"
                            ],
                            "additionalProperties": false
                          }
                        ]
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "filter": {
                    "anyOf": [
                      {
                        "type": "object",
                        "properties": {
                          "sources": {
                            "anyOf": [
                              {
                                "type": "array",
                                "items": {
                                  "type": "string",
                                  "minLength": 1,
                                  "maxLength": 200
                                },
                                "minItems": 1,
                                "maxItems": 10
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "deviceModels": {
                            "anyOf": [
                              {
                                "type": "array",
                                "items": {
                                  "type": "string",
                                  "minLength": 1,
                                  "maxLength": 200
                                },
                                "minItems": 1,
                                "maxItems": 10
                              },
                              {
                                "type": "null"
                              }
                            ]
                          }
                        },
                        "additionalProperties": false
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "label": {
                    "anyOf": [
                      {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 40
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "hidden": {
                    "anyOf": [
                      {
                        "type": "boolean"
                      },
                      {
                        "type": "null"
                      }
                    ]
                  }
                },
                "required": [
                  "type"
                ],
                "additionalProperties": false
              },
              "minItems": 1,
              "maxItems": 4
            },
            "formulas": {
              "anyOf": [
                {
                  "type": "array",
                  "items": {
                    "anyOf": [
                      {
                        "type": "object",
                        "properties": {
                          "id": {
                            "anyOf": [
                              {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 16,
                                "pattern": "^[a-z][a-z0-9]{0,15}$"
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "kind": {
                            "type": "string",
                            "enum": [
                              "movingAverage"
                            ]
                          },
                          "of": {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 16,
                            "pattern": "^[a-z][a-z0-9]{0,15}$"
                          },
                          "points": {
                            "anyOf": [
                              {
                                "type": "integer",
                                "minimum": 2,
                                "maximum": 30
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "label": {
                            "anyOf": [
                              {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 40
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "hidden": {
                            "anyOf": [
                              {
                                "type": "boolean"
                              },
                              {
                                "type": "null"
                              }
                            ]
                          }
                        },
                        "required": [
                          "kind",
                          "of"
                        ],
                        "additionalProperties": false
                      },
                      {
                        "type": "object",
                        "properties": {
                          "id": {
                            "anyOf": [
                              {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 16,
                                "pattern": "^[a-z][a-z0-9]{0,15}$"
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "kind": {
                            "type": "string",
                            "enum": [
                              "difference"
                            ]
                          },
                          "of": {
                            "type": "array",
                            "items": {
                              "type": "string",
                              "minLength": 1,
                              "maxLength": 16,
                              "pattern": "^[a-z][a-z0-9]{0,15}$"
                            },
                            "minItems": 2,
                            "maxItems": 2
                          },
                          "label": {
                            "anyOf": [
                              {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 40
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "hidden": {
                            "anyOf": [
                              {
                                "type": "boolean"
                              },
                              {
                                "type": "null"
                              }
                            ]
                          }
                        },
                        "required": [
                          "kind",
                          "of"
                        ],
                        "additionalProperties": false
                      }
                    ]
                  },
                  "maxItems": 2
                },
                {
                  "type": "null"
                }
              ]
            },
            "bucket": {
              "anyOf": [
                {
                  "type": "string",
                  "enum": [
                    "auto",
                    "hour",
                    "day",
                    "night",
                    "week",
                    "month"
                  ]
                },
                {
                  "type": "null"
                }
              ]
            },
            "range": {
              "anyOf": [
                {
                  "type": "string",
                  "enum": [
                    "D",
                    "W",
                    "M",
                    "6M",
                    "Y"
                  ]
                },
                {
                  "type": "null"
                }
              ]
            },
            "chart": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "style": {
                      "anyOf": [
                        {
                          "type": "string",
                          "enum": [
                            "bars",
                            "ranges",
                            "dots",
                            "line"
                          ]
                        },
                        {
                          "type": "null"
                        }
                      ]
                    },
                    "goal": {
                      "anyOf": [
                        {
                          "type": "object",
                          "properties": {
                            "value": {
                              "type": "number",
                              "minimum": 0
                            }
                          },
                          "required": [
                            "value"
                          ],
                          "additionalProperties": false
                        },
                        {
                          "type": "null"
                        }
                      ]
                    }
                  },
                  "additionalProperties": false
                },
                {
                  "type": "null"
                }
              ]
            }
          },
          "required": [
            "version",
            "display",
            "series"
          ],
          "additionalProperties": false,
          "description": "The card spec: JSON as the schema describes, with defaults left out as you like (preview_card's description explains it)."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "spec"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "card": {
          "$ref": "#/$defs/HealthCardItem"
        }
      },
      "required": [
        "timeZone",
        "card"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthCardItem": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "A card's id, e.g. card_seed_steps or card_01JZ…: list_cards lists them."
            },
            "spec": {
              "type": "object",
              "description": "The card's spec in canonical form, every default filled in (version 1): version, display, series, formulas, bucket, range and chart."
            },
            "position": {
              "type": "string",
              "description": "Its place on Summary: cards are in ascending order of position (by bytes), then id."
            },
            "seed": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The welcome card it started as (steps, heart_rate…), else null."
            },
            "createdAt": {
              "type": "string",
              "description": "When it was made."
            },
            "updatedAt": {
              "type": "string",
              "description": "When it was last changed or moved."
            }
          },
          "required": [
            "id",
            "spec",
            "position",
            "seed",
            "createdAt",
            "updatedAt"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Create Card",
      "readOnlyHint": false,
      "destructiveHint": false,
      "idempotentHint": false,
      "openWorldHint": false
    },
    "title": "Create Card"
  },
  {
    "name": "update_card",
    "description": "Replaces a card's spec with a new one, keeping its place on Summary (preview_card describes specs: preview it first). Give the whole spec, not only what changes: get_card or list_cards has the current one. Needs the person to have allowed this agent to manage cards; it never changes Health data. The change syncs to their Mac and iPhone.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "description": "A card's id, e.g. card_seed_steps or card_01JZ…: list_cards lists them."
        },
        "spec": {
          "type": "object",
          "properties": {
            "version": {
              "type": "integer",
              "enum": [
                1,
                2
              ],
              "description": "1, or 2 for a workout window's location."
            },
            "display": {
              "type": "object",
              "properties": {
                "name": {
                  "type": "string",
                  "minLength": 1,
                  "maxLength": 40
                },
                "symbol": {
                  "anyOf": [
                    {
                      "type": "string",
                      "enum": [
                        "flame.fill",
                        "figure",
                        "circle.dotted.circle",
                        "ear",
                        "heart.fill",
                        "pills.fill",
                        "brain.head.profile",
                        "figure.walk.motion",
                        "carrot.fill",
                        "lungs.fill",
                        "bed.double.fill",
                        "list.bullet.clipboard",
                        "waveform.path.ecg",
                        "plus",
                        "heart.text.square.fill",
                        "bolt.heart.fill",
                        "waveform",
                        "drop.fill",
                        "thermometer.medium",
                        "scalemass.fill",
                        "ruler.fill",
                        "eye.fill",
                        "hand.raised.fill",
                        "brain",
                        "cross.case.fill",
                        "figure.walk",
                        "figure.run",
                        "figure.stairs",
                        "figure.pool.swim",
                        "figure.outdoor.cycle",
                        "bicycle",
                        "figure.strengthtraining.traditional",
                        "figure.mind.and.body",
                        "figure.cooldown",
                        "bolt.fill",
                        "timer",
                        "stopwatch.fill",
                        "moon.fill",
                        "moon.zzz.fill",
                        "zzz",
                        "sun.max.fill",
                        "sunrise.fill",
                        "sunset.fill",
                        "clock.fill",
                        "alarm.fill",
                        "fork.knife",
                        "cup.and.saucer.fill",
                        "waterbottle.fill",
                        "leaf.fill",
                        "chart.line.uptrend.xyaxis",
                        "chart.bar.fill",
                        "gauge.with.dots.needle.50percent",
                        "star.fill",
                        "target",
                        "flag.fill"
                      ]
                    },
                    {
                      "type": "null"
                    }
                  ]
                },
                "color": {
                  "anyOf": [
                    {
                      "type": "string",
                      "enum": [
                        "red",
                        "orange",
                        "yellow",
                        "green",
                        "mint",
                        "teal",
                        "cyan",
                        "blue",
                        "indigo",
                        "purple",
                        "pink",
                        "brown",
                        "gray"
                      ]
                    },
                    {
                      "type": "null"
                    }
                  ]
                },
                "unit": {
                  "anyOf": [
                    {
                      "type": "string",
                      "enum": [
                        "kg",
                        "lb",
                        "st",
                        "cm",
                        "m",
                        "km",
                        "in",
                        "ft",
                        "yd",
                        "mi",
                        "degC",
                        "degF",
                        "km/hr",
                        "mi/hr",
                        "m/s",
                        "mL",
                        "L",
                        "fl_oz_us",
                        "kcal",
                        "kJ"
                      ]
                    },
                    {
                      "type": "null"
                    }
                  ]
                }
              },
              "required": [
                "name"
              ],
              "additionalProperties": false
            },
            "series": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "id": {
                    "anyOf": [
                      {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 16,
                        "pattern": "^[a-z][a-z0-9]{0,15}$"
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "type": {
                    "type": "string",
                    "description": "A quantity type: its HealthKit identifier (HKQuantityTypeIdentifierHeartRate), the identifier without its prefix (HeartRate) or the name lil health shows (\"Heart Rate\"), in any case. list_types and search find them."
                  },
                  "aggregation": {
                    "anyOf": [
                      {
                        "type": "string",
                        "enum": [
                          "sum",
                          "avg",
                          "min",
                          "max",
                          "first",
                          "latest",
                          "count"
                        ]
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "window": {
                    "anyOf": [
                      {
                        "anyOf": [
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "asleep"
                                ]
                              }
                            },
                            "required": [
                              "kind"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "beforeSleep"
                                ]
                              },
                              "minutes": {
                                "type": "integer",
                                "minimum": 1,
                                "maximum": 240
                              }
                            },
                            "required": [
                              "kind",
                              "minutes"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "afterWaking"
                                ]
                              },
                              "minutes": {
                                "type": "integer",
                                "minimum": 1,
                                "maximum": 240
                              }
                            },
                            "required": [
                              "kind",
                              "minutes"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "workout"
                                ]
                              },
                              "activities": {
                                "anyOf": [
                                  {
                                    "type": "array",
                                    "items": {
                                      "anyOf": [
                                        {
                                          "type": "integer"
                                        },
                                        {
                                          "type": "string"
                                        }
                                      ]
                                    },
                                    "description": "HKWorkoutActivityType raw values or names, e.g. 37 or \"Running\"; null for every workout."
                                  },
                                  {
                                    "type": "null"
                                  }
                                ]
                              },
                              "location": {
                                "anyOf": [
                                  {
                                    "type": "string",
                                    "enum": [
                                      "indoor",
                                      "outdoor"
                                    ],
                                    "description": "Spec version 2: only workouts indoors or outdoors, as the workouts tool's indoor says (workouts that don't say are left out); null for every workout."
                                  },
                                  {
                                    "type": "null"
                                  }
                                ]
                              }
                            },
                            "required": [
                              "kind"
                            ],
                            "additionalProperties": false
                          },
                          {
                            "type": "object",
                            "properties": {
                              "kind": {
                                "type": "string",
                                "enum": [
                                  "timeOfDay"
                                ]
                              },
                              "from": {
                                "type": "string",
                                "minLength": 5,
                                "maxLength": 5,
                                "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$"
                              },
                              "to": {
                                "type": "string",
                                "minLength": 5,
                                "maxLength": 5,
                                "pattern": "^([01][0-9]|2[0-3]):[0-5][0-9]$"
                              }
                            },
                            "required": [
                              "kind",
                              "from",
                              "to"
                            ],
                            "additionalProperties": false
                          }
                        ]
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "filter": {
                    "anyOf": [
                      {
                        "type": "object",
                        "properties": {
                          "sources": {
                            "anyOf": [
                              {
                                "type": "array",
                                "items": {
                                  "type": "string",
                                  "minLength": 1,
                                  "maxLength": 200
                                },
                                "minItems": 1,
                                "maxItems": 10
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "deviceModels": {
                            "anyOf": [
                              {
                                "type": "array",
                                "items": {
                                  "type": "string",
                                  "minLength": 1,
                                  "maxLength": 200
                                },
                                "minItems": 1,
                                "maxItems": 10
                              },
                              {
                                "type": "null"
                              }
                            ]
                          }
                        },
                        "additionalProperties": false
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "label": {
                    "anyOf": [
                      {
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 40
                      },
                      {
                        "type": "null"
                      }
                    ]
                  },
                  "hidden": {
                    "anyOf": [
                      {
                        "type": "boolean"
                      },
                      {
                        "type": "null"
                      }
                    ]
                  }
                },
                "required": [
                  "type"
                ],
                "additionalProperties": false
              },
              "minItems": 1,
              "maxItems": 4
            },
            "formulas": {
              "anyOf": [
                {
                  "type": "array",
                  "items": {
                    "anyOf": [
                      {
                        "type": "object",
                        "properties": {
                          "id": {
                            "anyOf": [
                              {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 16,
                                "pattern": "^[a-z][a-z0-9]{0,15}$"
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "kind": {
                            "type": "string",
                            "enum": [
                              "movingAverage"
                            ]
                          },
                          "of": {
                            "type": "string",
                            "minLength": 1,
                            "maxLength": 16,
                            "pattern": "^[a-z][a-z0-9]{0,15}$"
                          },
                          "points": {
                            "anyOf": [
                              {
                                "type": "integer",
                                "minimum": 2,
                                "maximum": 30
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "label": {
                            "anyOf": [
                              {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 40
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "hidden": {
                            "anyOf": [
                              {
                                "type": "boolean"
                              },
                              {
                                "type": "null"
                              }
                            ]
                          }
                        },
                        "required": [
                          "kind",
                          "of"
                        ],
                        "additionalProperties": false
                      },
                      {
                        "type": "object",
                        "properties": {
                          "id": {
                            "anyOf": [
                              {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 16,
                                "pattern": "^[a-z][a-z0-9]{0,15}$"
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "kind": {
                            "type": "string",
                            "enum": [
                              "difference"
                            ]
                          },
                          "of": {
                            "type": "array",
                            "items": {
                              "type": "string",
                              "minLength": 1,
                              "maxLength": 16,
                              "pattern": "^[a-z][a-z0-9]{0,15}$"
                            },
                            "minItems": 2,
                            "maxItems": 2
                          },
                          "label": {
                            "anyOf": [
                              {
                                "type": "string",
                                "minLength": 1,
                                "maxLength": 40
                              },
                              {
                                "type": "null"
                              }
                            ]
                          },
                          "hidden": {
                            "anyOf": [
                              {
                                "type": "boolean"
                              },
                              {
                                "type": "null"
                              }
                            ]
                          }
                        },
                        "required": [
                          "kind",
                          "of"
                        ],
                        "additionalProperties": false
                      }
                    ]
                  },
                  "maxItems": 2
                },
                {
                  "type": "null"
                }
              ]
            },
            "bucket": {
              "anyOf": [
                {
                  "type": "string",
                  "enum": [
                    "auto",
                    "hour",
                    "day",
                    "night",
                    "week",
                    "month"
                  ]
                },
                {
                  "type": "null"
                }
              ]
            },
            "range": {
              "anyOf": [
                {
                  "type": "string",
                  "enum": [
                    "D",
                    "W",
                    "M",
                    "6M",
                    "Y"
                  ]
                },
                {
                  "type": "null"
                }
              ]
            },
            "chart": {
              "anyOf": [
                {
                  "type": "object",
                  "properties": {
                    "style": {
                      "anyOf": [
                        {
                          "type": "string",
                          "enum": [
                            "bars",
                            "ranges",
                            "dots",
                            "line"
                          ]
                        },
                        {
                          "type": "null"
                        }
                      ]
                    },
                    "goal": {
                      "anyOf": [
                        {
                          "type": "object",
                          "properties": {
                            "value": {
                              "type": "number",
                              "minimum": 0
                            }
                          },
                          "required": [
                            "value"
                          ],
                          "additionalProperties": false
                        },
                        {
                          "type": "null"
                        }
                      ]
                    }
                  },
                  "additionalProperties": false
                },
                {
                  "type": "null"
                }
              ]
            }
          },
          "required": [
            "version",
            "display",
            "series"
          ],
          "additionalProperties": false,
          "description": "The card spec: JSON as the schema describes, with defaults left out as you like (preview_card's description explains it)."
        },
        "timeZone": {
          "type": "string",
          "description": "An IANA time zone, e.g. Europe/London, for days and local times. Defaults to UTC on the remote server and to the Mac's time zone locally. Every output says which it used."
        }
      },
      "required": [
        "id",
        "spec"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "timeZone": {
          "type": "string",
          "description": "The IANA time zone of the output's days and local times."
        },
        "card": {
          "$ref": "#/$defs/HealthCardItem"
        }
      },
      "required": [
        "timeZone",
        "card"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthCardItem": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string",
              "description": "A card's id, e.g. card_seed_steps or card_01JZ…: list_cards lists them."
            },
            "spec": {
              "type": "object",
              "description": "The card's spec in canonical form, every default filled in (version 1): version, display, series, formulas, bucket, range and chart."
            },
            "position": {
              "type": "string",
              "description": "Its place on Summary: cards are in ascending order of position (by bytes), then id."
            },
            "seed": {
              "anyOf": [
                {
                  "type": "string"
                },
                {
                  "type": "null"
                }
              ],
              "description": "The welcome card it started as (steps, heart_rate…), else null."
            },
            "createdAt": {
              "type": "string",
              "description": "When it was made."
            },
            "updatedAt": {
              "type": "string",
              "description": "When it was last changed or moved."
            }
          },
          "required": [
            "id",
            "spec",
            "position",
            "seed",
            "createdAt",
            "updatedAt"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Update Card",
      "readOnlyHint": false,
      "destructiveHint": true,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Update Card"
  },
  {
    "name": "delete_card",
    "description": "Deletes a card from lil health's Summary, on every device. Its Health data stays. Needs the person to have allowed this agent to manage cards; it never changes Health data. The change syncs to their Mac and iPhone.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "description": "A card's id, e.g. card_seed_steps or card_01JZ…: list_cards lists them."
        }
      },
      "required": [
        "id"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "deleted": {
          "type": "string",
          "description": "The deleted card's id."
        }
      },
      "required": [
        "deleted"
      ],
      "additionalProperties": true
    },
    "annotations": {
      "title": "Delete Card",
      "readOnlyHint": false,
      "destructiveHint": true,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Delete Card"
  },
  {
    "name": "reorder_cards",
    "description": "Puts lil health's Summary cards in a new order: give every card's id once, in the order you want (list_cards lists them). Only cards whose place changes are written. Needs the person to have allowed this agent to manage cards; it never changes Health data. The change syncs to their Mac and iPhone.",
    "inputSchema": {
      "type": "object",
      "properties": {
        "ids": {
          "type": "array",
          "items": {
            "type": "string"
          },
          "maxItems": 200,
          "description": "Every card's id, each once, in the new order."
        }
      },
      "required": [
        "ids"
      ],
      "additionalProperties": true
    },
    "outputSchema": {
      "type": "object",
      "properties": {
        "cards": {
          "type": "array",
          "items": {
            "$ref": "#/$defs/HealthCardPosition"
          },
          "description": "Every card, in its new order, with its position."
        }
      },
      "required": [
        "cards"
      ],
      "additionalProperties": true,
      "$defs": {
        "HealthCardPosition": {
          "type": "object",
          "properties": {
            "id": {
              "type": "string"
            },
            "position": {
              "type": "string"
            }
          },
          "required": [
            "id",
            "position"
          ],
          "additionalProperties": true
        }
      }
    },
    "annotations": {
      "title": "Reorder Cards",
      "readOnlyHint": false,
      "destructiveHint": false,
      "idempotentHint": true,
      "openWorldHint": false
    },
    "title": "Reorder Cards"
  }
]
"""#
