import Foundation
import Testing
@testable import JunkCore

@Test func bannerIsPlaceholder() {
    #expect(JunkCore.banner.hasPrefix("junk:"))
}
