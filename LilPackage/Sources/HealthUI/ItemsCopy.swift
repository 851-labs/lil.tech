// How lil health counts records to people, shared by the iPhone's upload and the Mac's sync
// footer (851-2946): as "items", as backup apps do ("321 items left" in Google Photos), without
// the types they come in.
import Foundation

public enum ItemsCopy {
  /// "1 item left", "1,234,567 items left".
  public static func left(_ count: Int) -> String {
    count == 1 ? "1 item left" : "\(count.formatted()) items left"
  }
}
