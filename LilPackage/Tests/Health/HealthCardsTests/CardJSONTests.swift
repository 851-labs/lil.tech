import Foundation
import Testing

@testable import HealthCards

struct CardJSONTests {
  @Test
  func parsesEveryKind() throws {
    let json = try CardJSON(
      parsing: Data(
        #"{"b": [1, 2.5, -0.001], "a": {"t": true, "f": false, "n": null}, "s": "x"}"#.utf8))
    #expect(json["b"] == [1, 2.5, -0.001])
    #expect(json["a"]?["t"] == true)
    #expect(json["a"]?["f"] == false)
    #expect(json["a"]?["n"] == .null)
    #expect(json["s"] == "x")
    #expect(json["missing"] == nil)
    // Booleans and numbers stay apart.
    #expect(try CardJSON(parsing: Data("[1, true, 0, false]".utf8)) == [1, true, 0, false])
  }

  @Test
  func equalityIgnoresKeyOrderAndNumberSpelling() throws {
    let a = try CardJSON(parsing: Data(#"{"x": 1, "y": [1e-7, 10000]}"#.utf8))
    let b = try CardJSON(parsing: Data(#"{"y": [0.0000001, 1e4], "x": 1.0}"#.utf8))
    #expect(a == b)
    #expect(a.hashValue == b.hashValue)
    #expect(a != (try CardJSON(parsing: Data(#"{"x": 1, "y": [1e-7, 10000], "z": null}"#.utf8))))
    #expect(CardJSON.array([1, 2]) != [2, 1])
  }

  @Test
  func writesAsJavaScriptDoes() {
    let json: CardJSON = [
      "n": [10000, 0.1, -3, 1.5, 1e-7], "s": "q\"u\\o\nte\u{1}é/", "e": [], "o": [:], "b": true,
      "z": nil,
    ]
    #expect(
      json.text()
        == #"{"n":[10000,0.1,-3,1.5,1e-7],"s":"q\"u\\o\nte\u0001é/","e":[],"o":{},"b":true,"z":null}"#
    )
    #expect(
      (["a": [1], "b": [:]] as CardJSON).text(pretty: true) == """
        {
          "a": [
            1
          ],
          "b": {}
        }
        """)
  }

  /// `Number.prototype.toString`'s forms.
  @Test(
    arguments: [
      (0, "0"), (-0.0, "0"), (1, "1"), (-3, "-3"), (10000, "10000"), (0.1, "0.1"), (1.5, "1.5"),
      (37.25, "37.25"), (0.000001, "0.000001"), (0.00001, "0.00001"), (1e-7, "1e-7"),
      (1.5e-7, "1.5e-7"), (123e-20, "1.23e-18"), (1e19, "10000000000000000000"),
      (1e21, "1e+21"), (1.2345e22, "1.2345e+22"), (123456789.125, "123456789.125"),
      (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"),
    ] as [(Double, String)])
  func numbers(_ value: Double, _ text: String) {
    #expect(CardJSON.text(of: value) == text)
  }

  @Test
  func roundTrips() throws {
    let json: CardJSON = ["a": ["b": [1, "two", nil, false]], "c": 3.25]
    #expect(try CardJSON(parsing: Data(json.text().utf8)) == json)
    #expect(try CardJSON(parsing: try JSONEncoder().encode(json)) == json)
  }
}
