import Dependencies
import HealthCatalog
import HealthDatabase
import HealthUI
import SwiftUI

/// One sample's details: its value, times and recorded time zone, the app and device it came
/// from, and its metadata.
struct SampleDetailView: View {
  let type: HealthDataType
  let sample: HealthSample
  /// From dependencies, so snapshot catalogs fix it (`previewCalendar`).
  @Dependency(\.calendar) private var calendar
  /// Whose units values are in (851-3116).
  @Dependency(\.locale) private var locale

  var body: some View {
    // `.dateTime`'s style, in the calendar's time zone.
    let dateStyle = Date.FormatStyle(
      locale: calendar.locale ?? .current, calendar: calendar, timeZone: calendar.timeZone)
    let recordedTimeZone = RecordedTimeZone(
      sample.timeZoneName, start: Date(unixMilliseconds: sample.startDate), calendar: calendar)
    Form {
      Section {
        if let value = sample.value {
          let (number, unit) = MetricFormat.value(
            value, unit: sample.unit ?? type.unit, typeID: type.id, locale: locale)
          LabeledContent("Value", value: unit.isEmpty ? number : "\(number) \(unit)")
        }
        LabeledContent(
          "Start", value: Date(unixMilliseconds: sample.startDate), format: dateStyle)
        LabeledContent("End", value: Date(unixMilliseconds: sample.endDate), format: dateStyle)
        if let zone = recordedTimeZone {
          RecordedTimeZoneRow(zone: zone)
        }
      }
      Section("Source") {
        LabeledContent("App", value: sample.sourceName)
        LabeledContent("Bundle ID", value: sample.sourceBundleID)
        if let revision = sample.decodedSourceRevision {
          optional("Version", revision.version)
          optional("Product Type", revision.productType)
          optional("Software Version", revision.operatingSystemVersion)
        }
      }
      if let device = sample.decodedDevice {
        Section("Device") {
          optional("Name", device.name)
          optional("Manufacturer", device.manufacturer)
          optional("Model", device.model)
          optional("Hardware Version", device.hardwareVersion)
          optional("Firmware Version", device.firmwareVersion)
          optional("Software Version", device.softwareVersion)
        }
      }
      // Without `HKTimeZone` when the Time Zone row shows it (851-4169).
      let metadata = SampleFormat.metadata(
        of: sample, timeZoneShown: recordedTimeZone != nil, calendar: calendar, locale: locale)
      if !metadata.isEmpty {
        Section("Metadata") {
          ForEach(metadata, id: \.key) { row in
            LabeledContent(row.label, value: row.value)
          }
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(type.name)
  }

  @ViewBuilder private func optional(_ title: String, _ value: String?) -> some View {
    if let value { LabeledContent(title, value: value) }
  }
}
