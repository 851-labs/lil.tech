import MessagesDatabase
import Testing

struct HandleFormattingTests {
  @Test(
    arguments: [
      ("+18669854321", "+1 (866) 985-4321"),
      ("+14152824083", "+1 (415) 282-4083"),
      ("4152824083", "+1 (415) 282-4083"),
      ("14152824083", "+1 (415) 282-4083"),
    ]
  )
  func northAmericanNumbers(input: String, expected: String) {
    #expect(formattedHandle(input) == expected)
  }

  @Test(
    arguments: [
      "+442079460958",
      "+40721234567",
      "72727",
      "262966",
      "friend@example.com",
      "chat000000000000000001",
      "",
    ]
  )
  func everythingElseIsUnchanged(input: String) {
    #expect(formattedHandle(input) == input)
  }
}
