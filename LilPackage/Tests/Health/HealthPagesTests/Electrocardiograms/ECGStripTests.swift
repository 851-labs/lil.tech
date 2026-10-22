import Testing

@testable import HealthPages

struct ECGStripTests {
  @Test
  func thePaperGrowsToFitTallWaves() {
    #expect(ECGStrip.range([0, 1_000, -300]) == -1.25...1.75)
    #expect(ECGStrip.range([0, 2_400, -1_600, .nan]) == -2...2.5)
    #expect(ECGStrip.range([]) == -1.25...1.75)
  }
}
