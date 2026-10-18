import CoreText
import IssueReporting
import SwiftUI

/// "Sign in with Google" as Google's branding guidelines draw it
/// (developers.google.com/identity/branding-guidelines): the standard-color G at 20 points, Google
/// Sans Medium 14/20, and the light or dark theme to match the screen. The G is Google's SVG from
/// its download bundle, drawn at 1x, 2x and 3x on a transparent background (asset catalogs can't
/// draw its filters and HTML gradient). The font is Google Sans (SIL Open Font License,
/// `Resources/GoogleSans-OFL.txt`), one weight with Latin letters only: a translation into
/// another script would need its letters added.
struct GoogleSignInButton: View {
  let action: () -> Void
  @Environment(\.colorScheme) private var colorScheme
  @Environment(\.isEnabled) private var isEnabled

  /// Google's colors for the light and dark themes.
  private var fill: Color { colorScheme == .dark ? Color(hex: 0x131314) : .white }
  private var stroke: Color { colorScheme == .dark ? Color(hex: 0x8E918F) : Color(hex: 0x747775) }
  private var text: Color { colorScheme == .dark ? Color(hex: 0xE3E3E3) : Color(hex: 0x1F1F1F) }

  var body: some View {
    Button(action: action) {
      // Google's iOS padding: 16 before the G, 12 between it and the label, 16 after.
      HStack(spacing: 12) {
        Image("GoogleG", bundle: .module)
          .resizable()
          .frame(width: 20, height: 20)
          .accessibilityHidden(true)
        Text("Sign in with Google")
          .font(Self.font)
          .foregroundStyle(text)
      }
      .padding(.horizontal, 16)
      .frame(maxWidth: .infinity, minHeight: SignInButtonMetrics.height)
      .background(fill, in: .rect(cornerRadius: SignInButtonMetrics.cornerRadius))
      .overlay {
        // 1 point, inside the edge.
        RoundedRectangle(cornerRadius: SignInButtonMetrics.cornerRadius)
          .strokeBorder(stroke, lineWidth: 1)
      }
      .contentShape(.rect(cornerRadius: SignInButtonMetrics.cornerRadius))
      // The plain style doesn't dim a disabled button.
      .opacity(isEnabled ? 1 : 0.5)
    }
    .buttonStyle(.plain)
  }

  /// Google Sans Medium at 14 points, growing with Dynamic Type. The label is one line at the
  /// default size, so its 20-point line height is moot.
  private static let font: Font = {
    registerFont
    return .custom("GoogleSans-Medium", size: 14, relativeTo: .body)
  }()

  /// Registers the bundled font with the process, once. Without it, the label would quietly be
  /// in the system font.
  private static let registerFont: Void = {
    guard let url = Bundle.module.url(forResource: "GoogleSans-Medium", withExtension: "ttf")
    else {
      reportIssue("GoogleSans-Medium.ttf isn't in LilAuth's bundle")
      return
    }
    var error: Unmanaged<CFError>?
    if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error),
      let error = error?.takeRetainedValue(),
      CFErrorGetCode(error) != CTFontManagerError.alreadyRegistered.rawValue
    {
      reportIssue(error)
    }
  }()
}

/// The sign-in buttons' shared frame: their labels follow each brand's own type.
enum SignInButtonMetrics {
  static let height: CGFloat = 44
  static let cornerRadius: CGFloat = 8
}

extension Color {
  /// An sRGB color from `0xRRGGBB`.
  fileprivate init(hex: UInt32) {
    self.init(
      .sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255)
  }
}
