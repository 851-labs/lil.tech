public import ComposableArchitecture
import HealthKitAccess
public import SwiftUI

public struct HealthAccessView: View {
  let store: StoreOf<HealthAccessFeature>
  /// Whether Health's sheet ends by asking how much history to share (iOS 27 and later).
  let asksAboutHistory: Bool

  public init(store: StoreOf<HealthAccessFeature>) {
    self.init(store: store, asksAboutHistory: Self.healthAsksAboutHistory)
  }

  init(store: StoreOf<HealthAccessFeature>, asksAboutHistory: Bool) {
    self.store = store
    self.asksAboutHistory = asksAboutHistory
  }

  static var healthAsksAboutHistory: Bool {
    #if os(iOS)
      if #available(iOS 27, *) { return true }
    #endif
    return false
  }

  public var body: some View {
    VStack(spacing: 20) {
      Spacer()
      Image(systemName: "heart.text.square.fill")
        .font(.system(size: 64))
        .foregroundStyle(.pink)
        .accessibilityHidden(true)
      switch store.step {
      case .explain, .requesting:
        explain
      case .perObject:
        perObject
      }
      if let failure = store.failure {
        Text(failure)
          .font(.callout)
          .foregroundStyle(.red)
          .multilineTextAlignment(.center)
      }
      Spacer()
    }
    .padding(32)
  }

  private var explain: some View {
    VStack(spacing: 20) {
      Text("Read Your Health Data")
        .font(.title.bold())
      explanation
        .multilineTextAlignment(.center)
        .foregroundStyle(.secondary)
      Spacer().frame(height: 12)
      Button {
        store.send(.continueButtonTapped)
      } label: {
        Group {
          if store.step == .requesting {
            ProgressView()
          } else {
            Text("Continue")
          }
        }
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
      .disabled(store.step == .requesting)
      Button("Not Now") { store.send(.notNowButtonTapped) }
        .disabled(store.step == .requesting)
    }
  }

  /// What the screen asks for. Since iOS 27, Health's sheet ends by asking how much history to
  /// share; the last 30 days would leave the Mac with only a month.
  private var explanation: Text {
    if asksAboutHistory {
      Text(
        """
        lil health copies everything in Apple Health to your lil health account, so you can see \
        it on your Mac. Health asks about each type next: allow all of them, then choose All \
        Recorded Data and Future Data to see your whole history.
        """)
    } else {
      Text(
        """
        lil health copies everything in Apple Health to your lil health account, so you can see \
        it on your Mac. Health asks about each type next: allow all of them to see everything.
        """)
    }
  }

  private var perObject: some View {
    VStack(spacing: 20) {
      Text("Medications and Prescriptions")
        .font(.title.bold())
        .multilineTextAlignment(.center)
      Text(
        """
        Health asks about these separately: you pick which medications and prescriptions to share.
        """
      )
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      VStack(spacing: 12) {
        ForEach(PerObjectHealthType.allCases, id: \.self) { type in
          Button(type.chooseTitle) { store.send(.perObjectButtonTapped(type)) }
        }
      }
      .buttonStyle(.bordered)
      .controlSize(.large)
      .disabled(store.isChoosing)
      Text(
        """
        Health doesn't tell apps what you turned off. If something stays empty, or only recent \
        history shows, check Settings › Health › Data Access & Devices › lil health.
        """
      )
      .font(.footnote)
      .multilineTextAlignment(.center)
      .foregroundStyle(.secondary)
      Button {
        store.send(.doneButtonTapped)
      } label: {
        Text("Done").frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
  }
}

#Preview("Explain") {
  HealthAccessView(store: Store(initialState: HealthAccessFeature.State()) { EmptyReducer() })
}

#Preview("Explain, before iOS 27") {
  HealthAccessView(
    store: Store(initialState: HealthAccessFeature.State()) { EmptyReducer() },
    asksAboutHistory: false)
}

#Preview("Explain, iOS 27") {
  HealthAccessView(
    store: Store(initialState: HealthAccessFeature.State()) { EmptyReducer() },
    asksAboutHistory: true)
}

#Preview("Requesting") {
  HealthAccessView(
    store: Store(initialState: HealthAccessFeature.State(step: .requesting)) { EmptyReducer() })
}

#Preview("Medications and prescriptions") {
  HealthAccessView(
    store: Store(initialState: HealthAccessFeature.State(step: .perObject)) { EmptyReducer() })
}

#Preview("Failed") {
  HealthAccessView(
    store: Store(
      initialState: HealthAccessFeature.State(
        failure: "Health isn't available on this device.")
    ) { EmptyReducer() })
}

#Preview("Medications and prescriptions, failed") {
  HealthAccessView(
    store: Store(
      initialState: HealthAccessFeature.State(
        step: .perObject, failure: "Health couldn't show your medications.")
    ) { EmptyReducer() })
}
