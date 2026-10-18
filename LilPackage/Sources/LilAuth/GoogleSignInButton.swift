import CoreText
import SwiftUI

/// "Sign in with Google" as Google's branding guidelines draw it
/// (developers.google.com/identity/branding-guidelines): the standard-color G at 20 points, Google
/// Sans Medium 14/20, and the light or dark theme to match the screen. The G comes from Google's
/// download bundle (its iOS PNGs at 1x, 2x and 3x, cropped to the G, one set per theme), since the
/// bundle's SVG uses filters and HTML gradients asset catalogs can't draw. The font is Google Sans
/// (SIL Open Font License, `Resources/GoogleSans-OFL.txt`), one weight with Latin letters only.
struct GoogleSignInButton: View {
  let action: () -> Void
  @Environment(\.colorScheme) private var colorScheme

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
          .lineLimit(1)
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
    }
    .buttonStyle(.plain)
  }

  /// Google Sans Medium at 14 points; the label is one line, so its 20-point line height is moot.
  private static let font: Font = {
    registerFont
    return .custom("GoogleSans-Medium", fixedSize: 14)
  }()

  /// Registers the bundled font with the process, once.
  private static let registerFont: Void = {
    guard let url = Bundle.module.url(forResource: "GoogleSans-Medium", withExtension: "ttf")
    else { return }
    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
  }()
}

/// The sign-in buttons' shared size, so Apple's and Google's match.
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
