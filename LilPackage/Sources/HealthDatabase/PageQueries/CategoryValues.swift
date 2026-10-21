extension HealthDatabase {
  /// How Health names a category sample's value (HealthKit's raw `HKCategoryValue…`), for a day's
  /// log: "Egg White" for cervical mucus, "Positive (LH Surge)" for an ovulation test. Nil for
  /// types whose samples have no value to name (sexual activity, pregnancy), and for values Health
  /// doesn't name (an unspecified contraceptive or bleeding level), or doesn't have yet. Flow is
  /// named as a period day is ("Period" when unspecified, `MenstrualFlow.name`).
  public static func categoryValueName(_ value: Int?, typeID: String) -> String? {
    guard let value else { return nil }
    switch typeID {
    case "HKCategoryTypeIdentifierCervicalMucusQuality":
      // HKCategoryValueCervicalMucusQuality.
      return [1: "Dry", 2: "Sticky", 3: "Creamy", 4: "Watery", 5: "Egg White"][value]
    case ovulationTestType:
      // HKCategoryValueOvulationTestResult.
      return [1: "Negative", 2: "Positive (LH Surge)", 3: "Indeterminate", 4: "Estrogen Surge"][
        value]
    case "HKCategoryTypeIdentifierPregnancyTestResult",
      "HKCategoryTypeIdentifierProgesteroneTestResult":
      // HKCategoryValuePregnancyTestResult and HKCategoryValueProgesteroneTestResult.
      return [1: "Negative", 2: "Positive", 3: "Indeterminate"][value]
    case menstrualFlowType:
      return MenstrualFlow(rawValue: value)?.name
    case _ where bleedingTypes.contains(typeID):
      // HKCategoryValueVaginalBleeding, without a level when it's unspecified.
      return [2: "Light", 3: "Medium", 4: "Heavy", 5: "None"][value]
    case standHourType:
      // HKCategoryValueAppleStandHour.
      return [0: "Stood", 1: "Idle"][value]
    case contraceptiveType:
      // HKCategoryValueContraceptive; 1 is unspecified.
      return [
        2: "Implant", 3: "Injection", 4: "Intrauterine Device", 5: "Intravaginal Ring", 6: "Oral",
        7: "Patch",
      ][value]
    case HealthNotificationKind.walkingSteadiness.rawValue:
      // HKCategoryValueAppleWalkingSteadinessEvent: the first notification of a low or very low
      // level (1, 2), or a repeat one (3, 4).
      return [1: "Low", 2: "Very Low", 3: "Still Low", 4: "Still Very Low"][value]
    default:
      return nil
    }
  }
}
