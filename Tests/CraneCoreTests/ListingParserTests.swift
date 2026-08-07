import Foundation
import Testing

@testable import CraneCore

@Suite("Directory listings")
struct ListingParserTests {
    /// Real busybox output from `container exec … ls -la /etc` on alpine 3.22.
    let busybox = """
    total 156
    drwxr-xr-x   17 root     root          4096 Aug  7 04:27 .
    drwxr-xr-x   20 root     root          4096 Aug  7 03:42 ..
    -rw-r--r--    1 root     root             7 Jun 21 18:52 alpine-release
    drwxr-xr-x    4 root     root          4096 Jun 21 18:55 apk
    lrwxrwxrwx    1 root     root            12 Jun 21 18:55 mtab -> /proc/mounts
    -rw-r--r--    1 root     root            89 Mar 25  2025 fstab
    """

    @Test("Entries are parsed with kind, size and timestamp")
    func parsesBusyboxListing() {
        let files = ListingParser.parse(busybox)
        #expect(files.map(\.name) == ["apk", "alpine-release", "fstab", "mtab"],
                "directories first, then files, each alphabetical")
        let release = try? #require(files.first { $0.name == "alpine-release" })
        #expect(release?.kind == .file)
        #expect(release?.size == 7)
        #expect(release?.modified == "Jun 21 18:52")
        #expect(release?.permissions == "-rw-r--r--")
    }

    @Test("`.` and `..` are dropped, and so is the total line")
    func dropsNoise() {
        let files = ListingParser.parse(busybox)
        #expect(!files.contains { $0.name == "." || $0.name == ".." })
        #expect(files.count == 4)
    }

    @Test("A symlink shows its own name, not the arrow")
    func handlesSymlinks() {
        let link = try? #require(ListingParser.parse(busybox).first { $0.kind == .link })
        #expect(link?.name == "mtab")
    }

    @Test("A name with spaces survives")
    func handlesSpacesInNames() {
        let files = ListingParser.parse("-rw-r--r--    1 root     root            12 Jun 21 18:52 my notes.txt")
        #expect(files.map(\.name) == ["my notes.txt"])
    }

    @Test("A year in place of a time is still a timestamp")
    func handlesOlderFiles() {
        let files = ListingParser.parse("-rw-r--r--    1 root     root            89 Mar 25  2025 fstab")
        #expect(files.first?.modified == "Mar 25 2025")
        #expect(files.first?.name == "fstab")
    }

    @Test("Garbage in, nothing out — never a bogus row")
    func ignoresNonListings() {
        #expect(ListingParser.parse("ls: /nope: No such file or directory").isEmpty)
        #expect(ListingParser.parse("").isEmpty)
    }
}
