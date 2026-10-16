import HealthCatalog
import HealthDatabase
import SwiftUI

/// One sample's details: its value and times, the app and device it came from, and its metadata.
struct SampleDetailView: View {
  let type: HealthDataType
  let sample: HealthSample

  var body: some View {
    Form {
      Section {
        if let value = sample.value {
          let (number, unit) = MetricFormat.value(
            value, unit: sample.unit ?? type.unit, typeID: type.id)
          LabeledContent("Value", value: unit.isEmpty ? number : "\(number) \(unit)")
        }
        LabeledContent(
          "Start", value: Date(unixMilliseconds: sample.startDate), format: .dateTime)
        LabeledContent("End", value: Date(unixMilliseconds: sample.endDate), format: .dateTime)
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
      let metadata = sample.metadataEntries
      if !metadata.isEmpty {
        Section("Metadata") {
          ForEach(metadata, id: \.key) { entry in
            LabeledContent(SampleFormat.key(entry.key), value: entry.value)
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
