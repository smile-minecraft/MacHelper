import AppKit
@testable import CleanEngine
import Foundation
@testable import MacHelper
import os
import SwiftUI
import Testing

@Suite(.serialized)
@MainActor
struct OptimizeUninstallUITests {
    // MARK: - ScrollingCenter

    @Test func scrollingCenterAvoidsScrollViewWhenContentFitsAndFallsBackWhenShort() {
        let content = ScrollingCenter {
            PixelEmptyState(art: "px.empty.clean", title: "Optimize",
                            message: "Scan first to list what can be cleaned.") {
                VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        Button("Start Scan") {}
                        Button("Deep Optimize…") {}
                    }
                    Text("Goes deeper into system folders. You review everything first; deleting asks for your administrator password.")
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
        }

        let tallHost = layoutInOffscreenWindow(content, width: 960, height: 780)
        #expect(!containsView(NSScrollView.self, in: tallHost),
                "tall windows must center without creating an NSScrollView that toggles its scroller during page-in transitions")

        let shortHost = layoutInOffscreenWindow(content, width: 720, height: 300)
        #expect(containsView(NSScrollView.self, in: shortHost),
                "short windows must fall back to ScrollView so the empty state's buttons stay reachable")
    }

    // MARK: - OptimizeView toolbar search scoping

    @Test func optimizeViewOnlyShowsToolbarSearchInReadyPhase() {
        let model = OptimizeModel()
        let autoClean = AutoCleanModel(
            agent: StubAutoCleanAgent(),
            configURL: FileManager.default.temporaryDirectory.appending(path: "opt-ui-test-\(UUID().uuidString).json"),
            defaults: TestHost.defaults
        )
        let view = OptimizeView(model: model, autoClean: autoClean)
        #expect(model.phase == .idle)
        #expect(!view.showsToolbarSearch, "idle start screen must not attach an unused toolbar search field")
    }

    // MARK: - UninstallModel loading & selection state transitions

    @Test func uninstallModelEntersLoadingSynchronouslyAndIgnoresDuplicateOrStaleSelections() async {
        let appA = makeApp(name: "Alpha", bundleID: "com.example.alpha", path: "/Applications/Alpha.app")
        let appB = makeApp(name: "Beta", bundleID: "com.example.beta", path: "/Applications/Beta.app")

        let planCalls = OSAllocatedUnfairLock(initialState: 0)
        let releaseAlpha = DispatchSemaphore(value: 0)
        let alphaStarted = OSAllocatedUnfairLock(initialState: false)

        let model = UninstallModel(
            installedAppsLoader: { [appA, appB] },
            planLoader: { app, _, _ in
                planCalls.withLock { $0 += 1 }
                if app.id == appA.id {
                    alphaStarted.withLock { $0 = true }
                    _ = releaseAlpha.wait(timeout: .now() + 2)
                }
                return UninstallPlan(
                    schemaVersion: 1,
                    app: app,
                    items: [
                        UninstallItem(
                            path: app.path,
                            kind: .appBundle,
                            size: app.size,
                            selected: true,
                            evidence: .bundleID
                        ),
                    ],
                    systemItems: [],
                    kept: []
                )
            },
            helperStatusProvider: { false }
        )

        #expect(!model.hasLoadedApps)
        await model.loadApps()
        #expect(model.hasLoadedApps)
        #expect(model.apps.count == 2)

        // Selecting an app synchronously enters the loading state so AppDetail never renders a blank frame.
        model.selectedAppID = appA.id
        #expect(model.loadingPlan)
        #expect(model.plan == nil)
        #expect(!model.canUninstallSelected)

        // Wait until Alpha's plan loader is running, then switch to Beta before Alpha returns.
        #expect(await eventually { alphaStarted.withLock { $0 } })
        model.selectedAppID = appB.id
        #expect(model.loadingPlan)
        #expect(model.plan == nil)

        // Beta finishes first; release Alpha afterwards and verify stale Alpha cannot overwrite Beta.
        #expect(await eventually { !model.loadingPlan && model.plan?.app.id == appB.id })
        releaseAlpha.signal()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.plan?.app.id == appB.id)
        #expect(!model.loadingPlan)
        #expect(model.canUninstallSelected)

        // Re-assigning the same selectedAppID must not wipe the loaded plan or re-trigger loading.
        let callsBeforeDuplicate = planCalls.withLock { $0 }
        model.selectedAppID = appB.id
        #expect(!model.loadingPlan)
        #expect(model.plan?.app.id == appB.id)
        #expect(planCalls.withLock { $0 } == callsBeforeDuplicate)

        // Clearing selection synchronously stops loading and drops the plan.
        model.selectedAppID = nil
        #expect(!model.loadingPlan)
        #expect(model.plan == nil)
    }

    // MARK: - UninstallView layout stability

    @Test func uninstallViewUsesStableTwoPaneLayoutWithoutNSSplitView() async {
        let appA = makeApp(name: "Alpha", bundleID: "com.example.alpha", path: "/Applications/Alpha.app")
        let model = UninstallModel(
            installedAppsLoader: { [appA] },
            planLoader: { app, _, _ in
                UninstallPlan(
                    schemaVersion: 1,
                    app: app,
                    items: [
                        UninstallItem(
                            path: app.path,
                            kind: .appBundle,
                            size: app.size,
                            selected: true,
                            evidence: .bundleID
                        ),
                    ],
                    systemItems: [],
                    kept: []
                )
            },
            helperStatusProvider: { false }
        )
        await model.loadApps()

        let host = layoutInOffscreenWindow(UninstallView(model: model), width: 960, height: 680)
        #expect(!containsView(NSSplitView.self, in: host),
                "UninstallView must not embed an NSSplitView (HSplitView) inside a transitioning tab container")

        model.selectedAppID = appA.id
        #expect(await eventually { !model.loadingPlan && model.plan?.app.id == appA.id })
        host.layoutSubtreeIfNeeded()
        #expect(!containsView(NSSplitView.self, in: host))
    }

    // MARK: - Helpers

    private func makeApp(name: String, bundleID: String, path: String) -> InstalledApp {
        InstalledApp(
            name: name,
            bundleID: bundleID,
            version: "1.0",
            path: path,
            size: 10_000_000,
            isAppStore: false,
            lastUsed: nil,
            isRunning: false,
            teamID: nil,
            protectedReason: nil
        )
    }

    private func layoutInOffscreenWindow<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSView {
        let window = NSWindow(
            contentRect: NSRect(x: -4000, y: -4000, width: width, height: height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        return host
    }

    private func containsView<T: NSView>(_ type: T.Type, in view: NSView) -> Bool {
        if view is T { return true }
        return view.subviews.contains { containsView(type, in: $0) }
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool,
                            timeout: Duration = .seconds(5)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private struct StubAutoCleanAgent: AutoCleanAgentServicing {
    var status: AutoCleanAgentStatus { .notRegistered }
    func register() throws {}
    func unregister() async throws {}
}
