import Foundation
import Testing
@testable import CleanEngine

@Suite struct BackgroundItemsTests {
    static let sample = """
    ========================
     Records for UID 501 : 3090A613-6443-47F8-B692-B4DF84DAC5CA
    ========================

     ServiceManagement migrated: true

     Items:

     #1:
                     UUID: 5ACA140A
                     Name: (null)
           Developer Name: (null)
                     Type: developer (0x20)
                    Flags: [  ] (0)
              Disposition: [disabled, allowed, not notified] (0x2)
               Identifier: Unknown Developer
                      URL: (null)
      Embedded Item Identifiers:
        #1: 8.com.smile.ollama

     #2:
                     UUID: 7093A4B8
                     Name: ollama
                     Type: legacy agent (0x10008)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 8.com.smile.ollama
                      URL: /Users/501/Library/LaunchAgents/com.smile.ollama.plist
          Executable Path: /opt/homebrew/opt/ollama/bin/ollama
        Parent Identifier: Unknown Developer

     #3:
                     UUID: AAAA0001
                     Name: Spotify
           Developer Name: Spotify
                     Type: app (0x2)
              Disposition: [disabled, allowed, notified] (0x3)
               Identifier: 2.com.spotify.client

     #4:
                     UUID: AAAA0002
                     Name: StartUpHelper
                     Type: login item (0x4)
              Disposition: [disabled, disallowed, notified] (0x8)
               Identifier: 4.com.spotify.client.startuphelper
        Parent Identifier: 2.com.spotify.client

     #5:
                     UUID: AAAA0003
                     Name: sh
                     Type: legacy agent (0x10008)
              Disposition: [enabled, disallowed, notified] (0x9)
               Identifier: 8.com.example.wrapper
        Parent Identifier: Unknown Developer
    ========================
     Records for UID -2 : FFFF
    ========================
     #1:
                     UUID: BBBB0001
                     Name: ollama
                     Type: legacy agent (0x10008)
              Disposition: [enabled, allowed, notified] (0xb)
               Identifier: 8.com.smile.ollama
                      URL: /Users/501/Library/LaunchAgents/com.smile.ollama.plist
          Executable Path: /opt/homebrew/opt/ollama/bin/ollama
    """

    @Test func parsesItemsAndFlags() {
        let items = BackgroundItems.parse(Self.sample)
        #expect(items.count == 6)
        let ollama = items[1]
        #expect(ollama.uid == 501 && ollama.kind == .legacyAgent && ollama.isActive)
        #expect(ollama.executablePath == "/opt/homebrew/opt/ollama/bin/ollama")
        #expect(items[0].name == nil, "(null) becomes nil")
        #expect(items[3].kind == .loginItem && !items[3].enabled && !items[3].allowed, "disabled/disallowed are not enabled/allowed")
        #expect(items[5].uid == -2)
    }

    @Test func groupsUnderNamedParentsAndDeduplicates() {
        let groups = BackgroundItems.groups(BackgroundItems.parse(Self.sample), uid: 501)
        // ollama (once, though listed for two UIDs), Spotify, and the sh wrapper standing alone.
        #expect(groups.count == 3)
        #expect(groups.first?.title == "ollama" && groups.first?.enabled == true, "active groups first")
        let spotify = groups.first { $0.parent?.identifier == "2.com.spotify.client" }
        #expect(spotify?.items.map(\.displayName) == ["StartUpHelper"])
        #expect(spotify?.enabled == false)
        let wrapper = groups.first { $0.items.first?.identifier == "8.com.example.wrapper" }
        #expect(wrapper?.title == "com.example.wrapper", "generic executable names fall back to the label")
        #expect(wrapper?.enabled == false, "enabled but not allowed does not run")
    }
}
