import Testing
@testable import PrivilegedOps

@Suite struct BackgroundTaskDumpTests {
    let dump = """
    ========================
     Records for UID 501 : 3090A613
    ========================
     #1:
                     UUID: AAAA0001
               Identifier: com.mine.agent
     Records for UID 502 : 1111
     #1:
                     UUID: CCCC0001
               Identifier: com.other-user.secret
     Records for UID -2 : FFFF
     #1:
                     UUID: BBBB0001
               Identifier: com.shared.daemon
     Records for UID 0 : 0000
     #1:
                     UUID: DDDD0001
               Identifier: com.root.daemon
     Records for UID x : broken
               Identifier: com.unparsed.header
    """

    @Test func fixedCommand() {
        #expect(BackgroundTaskDump.tool == "/usr/bin/sfltool")
        #expect(BackgroundTaskDump.arguments == ["dumpbtm"])
    }

    @Test func keepsOnlyCallerAndSharedSections() {
        let out = BackgroundTaskDump.filter(dump, uid: 501)
        #expect(out.contains("com.mine.agent"))
        #expect(out.contains("com.shared.daemon"))
        #expect(out.contains("com.root.daemon"))
        #expect(!out.contains("com.other-user.secret"), "another account's records never leave the Helper")
        #expect(!out.contains("com.unparsed.header"), "unparseable headers fail closed")
        #expect(out.hasPrefix("========================"), "preamble kept")
    }

    @Test func otherCallerGetsTheirOwnSection() {
        let out = BackgroundTaskDump.filter(dump, uid: 502)
        #expect(out.contains("com.other-user.secret"))
        #expect(!out.contains("com.mine.agent"))
    }
}
