import SiphonCore
import Testing

struct MergeSignpostTests {
    private let merger = "[Merger] Merging formats into \"clip.mp4\""

    @Test(arguments: ["[Fixup] Fixing", "[download] Downloading item 2 of 3", "SIPHON_FINAL_PATH:/tmp/clip.mp4"])
    func nextPhaseLineEndsTheMerge(next: String) {
        let signpost = MergeSignpost()
        signpost.observe(merger)
        #expect(signpost.isOpen)
        signpost.observe("Deleting original file clip.f137.mp4")
        #expect(signpost.isOpen)
        signpost.observe(next)
        #expect(!signpost.isOpen)
    }

    @Test func mergerTextInsideAnotherLineDoesNotOpen() {
        let signpost = MergeSignpost()
        signpost.observe("[download] Destination: [Merger] clip.mp4")
        #expect(!signpost.isOpen)
    }

    @Test func eachPlaylistEntryOpensItsOwnMerge() {
        let signpost = MergeSignpost()
        signpost.observe(merger)
        signpost.observe("[download] Downloading item 2 of 3")
        signpost.observe(merger)
        #expect(signpost.isOpen)
        signpost.observe(merger)
        #expect(signpost.isOpen)
        signpost.finish()
        #expect(!signpost.isOpen)
    }

    @Test func finishIsIdempotentAndBlocksLateLines() {
        let signpost = MergeSignpost()
        signpost.observe(merger)
        signpost.finish()
        signpost.finish()
        signpost.observe(merger)
        #expect(!signpost.isOpen)
    }
}
