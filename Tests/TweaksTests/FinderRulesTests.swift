import Foundation
import Testing
import Tweaks

@Suite struct FinderCutPasteRulesTests {
    @Test func textFocusRolesAreLeftAlone() {
        for role in ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField", "AXWebArea"] {
            #expect(FinderRules.isTextFocus(role), "\(role) is a text field")
        }
        // Finder did not answer in time: leaving the keys alone is the safe answer.
        #expect(FinderRules.isTextFocus(nil))
    }

    @Test func fileListRolesAreNotText() {
        for role in ["AXOutline", "AXBrowser", "AXList", "AXRow", "AXCell", "AXGroup", "AXWindow"] {
            #expect(!FinderRules.isTextFocus(role))
        }
    }

    @Test func onlyPlainCommandChordsAreReplaced() {
        let command = TweakRules.commandFlag
        #expect(FinderRules.chord(keyCode: FinderRules.keyX, flags: command) == .cut)
        #expect(FinderRules.chord(keyCode: FinderRules.keyC, flags: command) == .copy)
        #expect(FinderRules.chord(keyCode: FinderRules.keyV, flags: command) == .paste)
        #expect(FinderRules.chord(keyCode: FinderRules.keyEscape, flags: 0) == .escape)

        // Modified variants keep their meaning.
        #expect(FinderRules.chord(keyCode: FinderRules.keyX, flags: command | TweakRules.shiftFlag) == nil)
        #expect(FinderRules.chord(keyCode: FinderRules.keyV, flags: command | TweakRules.alternateFlag) == nil)
        #expect(FinderRules.chord(keyCode: FinderRules.keyV, flags: command | TweakRules.controlFlag) == nil)
        // Plain letter keys are not shortcuts.
        #expect(FinderRules.chord(keyCode: FinderRules.keyX, flags: 0) == nil)
        // Escape is still escape with modifiers: it can always cancel a cut.
        #expect(FinderRules.chord(keyCode: FinderRules.keyEscape, flags: command) == .escape)
    }

    @Test func anArmedCutExpiresAfterItsLifetime() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var session = FinderCutSession()
        #expect(!session.isArmed)
        session.arm(at: start)
        #expect(session.isArmed)
        #expect(session.isArmed(at: start.addingTimeInterval(0)))
        #expect(session.isArmed(at: start.addingTimeInterval(FinderCutSession.lifetime)))
        #expect(!session.isArmed(at: start.addingTimeInterval(FinderCutSession.lifetime + 0.01)))
    }

    @Test func escapeCopyAndPasteEndTheCut() {
        let start = Date(timeIntervalSinceReferenceDate: 2_000)
        var session = FinderCutSession()
        session.arm(at: start)
        session.disarm()
        #expect(!session.isArmed(at: start.addingTimeInterval(1)))

        session.arm(at: start)
        let consumed = session.consume(now: start.addingTimeInterval(2))
        #expect(consumed)
        #expect(!session.isArmed(at: start.addingTimeInterval(3)), "a move ends the cut")

        // A second ⌘X replaces the first cut instead of stacking.
        session.arm(at: start)
        session.arm(at: start.addingTimeInterval(20))
        #expect(session.isArmed(at: start.addingTimeInterval(45)))
        #expect(!session.isArmed(at: start.addingTimeInterval(51)))
    }

    @Test func anExpiredCutIsNotConsumed() {
        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        var session = FinderCutSession()
        session.arm(at: start)
        let consumed = session.consume(now: start.addingTimeInterval(FinderCutSession.lifetime + 1))
        #expect(!consumed)
        #expect(!session.isArmed)
    }
}

@Suite struct FinderNewFileRulesTests {
    @Test func theFirstFreeNameWins() {
        #expect(FinderNewFileRules.uniqueFileName(base: "Notes", pathExtension: "txt", existing: []) == "Notes.txt")
        #expect(FinderNewFileRules.uniqueFileName(base: "Notes", pathExtension: "txt",
                                                  existing: ["Notes.txt"]) == "Notes 2.txt")
        #expect(FinderNewFileRules.uniqueFileName(base: "Notes", pathExtension: "txt",
                                                  existing: ["Notes.txt", "Notes 2.txt"]) == "Notes 3.txt")
        // The skipped number is reused: what matters is a free name, not a growing counter.
        #expect(FinderNewFileRules.uniqueFileName(base: "Notes", pathExtension: "txt",
                                                  existing: ["Notes.txt", "notes 3.TXT"]) == "Notes 2.txt")
    }

    @Test func namesCompareCaseInsensitively() {
        // The default volume is case-insensitive: "notes.txt" is the same file as "Notes.txt".
        #expect(FinderNewFileRules.uniqueFileName(base: "Notes", pathExtension: "txt",
                                                  existing: ["notes.TXT"]) == "Notes 2.txt")
    }

    @Test func aNameWithoutExtensionHasNoDot() {
        #expect(FinderNewFileRules.uniqueFileName(base: "Makefile", pathExtension: "", existing: []) == "Makefile")
        #expect(FinderNewFileRules.uniqueFileName(base: "Makefile", pathExtension: "",
                                                  existing: ["Makefile"]) == "Makefile 2")
    }

    @Test func basesThatCannotBeFileNamesFallBack() {
        #expect(FinderNewFileRules.sanitizedBaseName("   ") == "Untitled")
        #expect(FinderNewFileRules.sanitizedBaseName("a/b:c") == "a-b-c")
        #expect(FinderNewFileRules.sanitizedBaseName(".hidden") == "hidden")
        #expect(FinderNewFileRules.sanitizedBaseName("line\nbreak") == "linebreak")
        #expect(FinderNewFileRules.sanitizedBaseName(String(repeating: "x", count: 300)).count == 120)
    }

    @Test func theExtensionFollowsTheTemplate() {
        #expect(FinderNewFileRules.fileExtension(template: .text, customExtension: "md") == "txt")
        #expect(FinderNewFileRules.fileExtension(template: .markdown, customExtension: "") == "md")
        #expect(FinderNewFileRules.fileExtension(template: .rtf, customExtension: "") == "rtf")
        #expect(FinderNewFileRules.fileExtension(template: .custom, customExtension: ".swift") == "swift")
        #expect(FinderNewFileRules.fileExtension(template: .custom, customExtension: " sh ") == "sh")
        #expect(FinderNewFileRules.fileExtension(template: .custom, customExtension: "") == "")
        // A path separator typed into the option cannot move the file out of the folder.
        #expect(FinderNewFileRules.fileExtension(template: .custom, customExtension: "../evil") == "evil")
    }

    @Test func templatesStartAsTheDocumentTheyName() {
        #expect(FinderFileTemplate.text.contents.isEmpty)
        #expect(FinderFileTemplate.markdown.contents.isEmpty)
        let rtf = String(data: FinderFileTemplate.rtf.contents, encoding: .utf8) ?? ""
        #expect(rtf.hasPrefix("{\\rtf1"))
        #expect(FinderFileTemplate.allCases.map(\.rawValue) == ["text", "markdown", "rtf", "custom"])
    }
}

@Suite struct FinderMenuRequestTests {
    @Test func aRequestSurvivesTheURLAroundTrip() throws {
        let request = FinderMenuRequest(action: .openTerminal,
                                        paths: ["/Users/me/Desktop/My Folder", "/Users/me/a b.txt"],
                                        template: nil, id: "ABC-1")
        let url = try #require(FinderMenuURL.make(request))
        #expect(url.scheme == "machelper")
        #expect(url.host == "finder")
        #expect(FinderMenuURL.parse(url) == request)
    }

    @Test func theTemplateTravelsWithANewFileRequest() throws {
        let request = FinderMenuRequest(action: .newFile, paths: ["/Users/me/Desktop"], template: .markdown, id: "x")
        let url = try #require(FinderMenuURL.make(request))
        let parsed = try #require(FinderMenuURL.parse(url))
        #expect(parsed.template == .markdown)
        #expect(parsed.action == .newFile)
    }

    @Test func otherSchemesHostsAndActionsAreIgnored() throws {
        #expect(FinderMenuURL.parse(try #require(URL(string: "https://finder/copy-path?path=/tmp"))) == nil)
        #expect(FinderMenuURL.parse(try #require(URL(string: "machelper://other/copy-path?path=/tmp"))) == nil)
        #expect(FinderMenuURL.parse(try #require(URL(string: "machelper://finder/reboot?path=/tmp"))) == nil)
        #expect(FinderMenuURL.parse(try #require(URL(string: "machelper://finder/copy-path")))?.paths.isEmpty == true)
    }

    @Test func unsafePathsAreRejected() {
        #expect(FinderMenuRequestRules.isSafePath("/Users/me/Desktop/a.txt"))
        #expect(!FinderMenuRequestRules.isSafePath("relative/path"))
        #expect(!FinderMenuRequestRules.isSafePath("/Users/me/../etc/passwd"))
        #expect(!FinderMenuRequestRules.isSafePath("/Users/me/a\0b"))
        #expect(!FinderMenuRequestRules.isSafePath("~/.ssh"))
        #expect(!FinderMenuRequestRules.isSafePath("/"))
    }

    @Test func systemLocationsAreNotUserLocations() {
        #expect(FinderMenuRequestRules.isUserLocation("/Users/me/Desktop"))
        #expect(FinderMenuRequestRules.isUserLocation("/Volumes/Backup/notes"))
        #expect(!FinderMenuRequestRules.isUserLocation("/"))
        #expect(!FinderMenuRequestRules.isUserLocation("/System/Library"))
        #expect(!FinderMenuRequestRules.isUserLocation("/usr/local/bin"))
        #expect(!FinderMenuRequestRules.isUserLocation("/Library/Apple/System"))
        // A similar-looking name that is not a system folder stays allowed.
        #expect(FinderMenuRequestRules.isUserLocation("/Users/system"))
    }

    @Test func aNewFileNeedsOneWritableFolder() {
        let environment = FinderMenuRequestRules.Environment(
            exists: { _ in true },
            isDirectory: { $0 == "/Users/me/Desktop" },
            isWritableDirectory: { $0 == "/Users/me/Desktop" })
        let good = FinderMenuRequest(action: .newFile, paths: ["/Users/me/Desktop"], id: "1")
        #expect(FinderMenuRequestRules.validate(good, environment) == good)

        let readOnly = FinderMenuRequest(action: .newFile, paths: ["/Users/me/RO"], id: "2")
        #expect(FinderMenuRequestRules.validate(readOnly, environment) == nil)

        let twoFolders = FinderMenuRequest(action: .newFile, paths: ["/Users/me/Desktop", "/Users/me/Desktop"], id: "3")
        #expect(FinderMenuRequestRules.validate(twoFolders, environment) == nil)

        let fileTarget = FinderMenuRequest(action: .newFile, paths: ["/Users/me/a.txt"], id: "4")
        #expect(FinderMenuRequestRules.validate(fileTarget, environment) == nil)
    }

    @Test func missingPathsAndOversizedBatchesAreRejected() {
        let environment = FinderMenuRequestRules.Environment(
            exists: { $0 == "/Users/me/a.txt" },
            isDirectory: { _ in false },
            isWritableDirectory: { _ in false })
        #expect(FinderMenuRequestRules.validate(FinderMenuRequest(action: .copyPath, paths: [], id: "1"), environment) == nil)
        #expect(FinderMenuRequestRules.validate(FinderMenuRequest(action: .copyPath, paths: ["/Users/me/gone"], id: "2"),
                                               environment) == nil)
        let many = (0...FinderMenuRequestRules.maxPaths).map { "/Users/me/\($0)" }
        #expect(FinderMenuRequestRules.validate(FinderMenuRequest(action: .copyPath, paths: many, id: "3"),
                                               environment) == nil)
        let one = FinderMenuRequest(action: .copyPath, paths: ["/Users/me/a.txt"], id: "4")
        #expect(FinderMenuRequestRules.validate(one, environment) == one)
    }

    @Test func pathsAreStandardizedBeforeTheyAreUsed() {
        let environment = FinderMenuRequestRules.Environment(
            exists: { $0 == "/Users/me/Desktop" },
            isDirectory: { _ in true },
            isWritableDirectory: { _ in true })
        let request = FinderMenuRequest(action: .newFile, paths: ["/Users/me/Desktop/"], id: "1")
        #expect(FinderMenuRequestRules.validate(request, environment)?.paths == ["/Users/me/Desktop"])
    }

    @Test func theTerminalOpensInTheFolderHoldingTheItem() {
        #expect(FinderMenuRequestRules.terminalDirectory(for: "/Users/me/Desktop", isDirectory: true) == "/Users/me/Desktop")
        #expect(FinderMenuRequestRules.terminalDirectory(for: "/Users/me/Desktop/a.txt", isDirectory: false) == "/Users/me/Desktop")
    }
}

@Suite struct TweakShortcutTests {
    @Test func theDefaultShortcutParses() throws {
        let shortcut = try #require(TweakShortcut.parse("ctrl+option+n"))
        #expect(shortcut.keyCode == FinderRules.keyN)
        #expect(shortcut.flags == TweakRules.controlFlag | TweakRules.alternateFlag)
        #expect(shortcut.description == "⌃⌥N")
    }

    @Test func namesAndSymbolsBothWork() throws {
        let controlOption = try #require(TweakShortcut.parse("⌃⌥N"))
        #expect(controlOption == TweakShortcut.parse("control-alt-n"))
        #expect(TweakShortcut.parse("cmd+shift+k")?.description == "⇧⌘K")
        #expect(TweakShortcut.parse("cmd+opt+1")?.keyCode == 18)
    }

    @Test func aShortcutMatchesItselfAndNothingElse() throws {
        let shortcut = try #require(TweakShortcut.parse("ctrl+option+n"))
        #expect(shortcut.matches(keyCode: FinderRules.keyN, flags: TweakRules.controlFlag | TweakRules.alternateFlag))
        // Caps lock and the keypad bits are not part of a shortcut.
        #expect(shortcut.matches(keyCode: FinderRules.keyN,
                                 flags: TweakRules.controlFlag | TweakRules.alternateFlag | (1 << 16)))
        #expect(!shortcut.matches(keyCode: FinderRules.keyN, flags: TweakRules.controlFlag))
        #expect(!shortcut.matches(keyCode: FinderRules.keyN,
                                  flags: TweakRules.controlFlag | TweakRules.alternateFlag | TweakRules.commandFlag))
        #expect(!shortcut.matches(keyCode: 46, flags: TweakRules.controlFlag | TweakRules.alternateFlag))
    }

    @Test func aShortcutNeedsAModifierAndARealKey() {
        #expect(TweakShortcut.parse("n") == nil)
        #expect(TweakShortcut.parse("ctrl+n+f") == nil)
        #expect(TweakShortcut.parse("hyper+n") == nil)
        #expect(TweakShortcut.parse("ctrl+") == nil)
        #expect(TweakShortcut.parse("") == nil)
    }
}
