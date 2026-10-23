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
        == #"{"n":[10000,0.1,-3,1.5,1e-07],"s":"q\"u\\o\nte\u0001é/","e":[],"o":{},"b":true,"z":null}"#
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

  @Test
  func roundTrips() throws {
    let json: CardJSON = ["a": ["b": [1, "two", nil, false]], "c": 3.25]
    #expect(try CardJSON(parsing: Data(json.text().utf8)) == json)
    #expect(try CardJSON(parsing: try JSONEncoder().encode(json)) == json)
  }
}
