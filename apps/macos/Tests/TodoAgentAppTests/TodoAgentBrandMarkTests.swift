import Testing
@testable import TodoAgentApp

@Suite("TodoAgent brand mark")
@MainActor
struct TodoAgentBrandMarkTests {
    @Test("monochrome Agent mark is bundled as a vector PDF")
    func bundledMarkLoads() throws {
        let image = try #require(TodoAgentBrandMark.image())

        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
        #expect(image.isTemplate == false)
    }
}
