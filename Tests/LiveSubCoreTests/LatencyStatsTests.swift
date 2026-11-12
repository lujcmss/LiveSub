import Testing
@testable import LiveSubCore

@Test func percentilesUseNearestRank() {
    let sorted = (1...100).map(Double.init)
    #expect(LatencyStats.percentile(sorted, 0.5) == 50)
    #expect(LatencyStats.percentile(sorted, 0.95) == 95)
    #expect(LatencyStats.percentile([7], 0.95) == 7)
}

@Test func helperPrefixesCoverSafariWebKit() {
    #expect(AudioProcessCatalog.helperPrefixes(for: "com.apple.Safari").contains("com.apple.WebKit."))
    #expect(AudioProcessCatalog.helperPrefixes(for: "com.google.Chrome") == ["com.google.Chrome."])
}
