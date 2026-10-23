import Testing
@testable import Strain

@Test func ownerNamesComeFromPaths() {
    #expect(owner(of: "/Library/Developer/CoreSimulator/Volumes/iOS_24A434/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/System/Library/CoreServices/SpringBoard.app/SpringBoard")
            == Owner(name: simulatorGroup, bundle: nil))
    #expect(owner(of: "/Applications/Brave Browser.app/Contents/Frameworks/Brave Browser Framework.framework/Versions/154.1.96.60/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/Brave Browser Helper (Renderer)")
            == Owner(name: "Brave Browser", bundle: "/Applications/Brave Browser.app"))
    #expect(owner(of: "/System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd")
            == Owner(name: "mediaanalysisd", bundle: nil))
    #expect(owner(of: "node") == Owner(name: "node", bundle: nil))
}

@Test func groupsAggregateAndSortByCPU() {
    let groups = group(parsePS(psFixture))
    #expect(groups.map(\.name) == ["compile", "Claude", "WindowServer", simulatorGroup])
    let sim = groups.last!
    #expect(sim.pids == [61382] && sim.rssKB == 48208 && sim.seconds == 4 * 86400 + 16 * 3600 + 50 * 60 + 51)
}

@Test func manyDaemonsOfOneOwnerBecomeOneRow() {
    let procs = (0..<40).map { Proc(pid: Int32($0), uid: 501, cpu: 10, rssKB: 1000, seconds: $0,
                                    path: "/Library/Developer/CoreSimulator/Volumes/x/d\($0)") }
    let groups = group(procs)
    #expect(groups.count == 1 && groups[0].cpu == 400 && groups[0].rssKB == 40_000 && groups[0].seconds == 39)
}

@Test func liveSampleParsesNearlyEveryProcess() {
    #expect(group(sampleProcesses()).count > 20)
}
