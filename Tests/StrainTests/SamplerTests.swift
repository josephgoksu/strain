import Testing
@testable import Strain

// Real `ps -Ao pid=,uid=,pcpu=,rss=,etime=,comm=` lines from the 2026-10-22 slowdown.
let psFixture = """
  422    88  48.9  48992 14-12:41:13 /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
61382   501  47.6  48208 04-16:50:51 /Library/Developer/CoreSimulator/Volumes/iOS_24A434/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 27.0.simruntime/Contents/Resources/RuntimeRoot/System/Library/CoreServices/SpringBoard.app/SpringBoard
74212   501  72.1 189504       00:05 /opt/homebrew/Cellar/go/1.27.3/libexec/pkg/tool/darwin_arm64/compile
81403   501  48.9 1103824    23:43:18 /Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)
84000   501   0.0      0       00:01 (ReportCrashServi)
garbage line
"""

@Test func parsesPsLinesWithSpacesInPaths() {
    let procs = parsePS(psFixture)
    #expect(procs.count == 4)
    let claude = procs[3]
    #expect(claude.pid == 81403 && claude.uid == 501 && claude.cpu == 48.9 && claude.rssKB == 1_103_824)
    #expect(claude.path == "/Applications/Claude.app/Contents/Frameworks/Claude Helper (Renderer).app/Contents/MacOS/Claude Helper (Renderer)")
    #expect(procs[1].path.hasSuffix("SpringBoard.app/SpringBoard"))
}

@Test func parsesEveryElapsedFormat() {
    #expect(parseElapsed("00:05") == 5)
    #expect(parseElapsed("23:43:18") == 23 * 3600 + 43 * 60 + 18)
    #expect(parseElapsed("14-12:41:13") == 14 * 86400 + 12 * 3600 + 41 * 60 + 13)
    #expect(parseElapsed("nonsense") == nil)
}

@Test func readsLiveSystemNumbers() {
    let s = SystemSample.read()
    #expect([1, 2, 4].contains(s.pressure))
    #expect(s.cores > 0 && s.swapTotalMB >= s.swapUsedMB && s.load >= 0)
}
