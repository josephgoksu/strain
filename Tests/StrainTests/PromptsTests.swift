import Testing
@testable import Strain

@Test func appPromptCarriesTheFacts() {
    let g = Group(name: "mds_stores", path: "/System/Library/x/mds_stores", cpu: 45, rssKB: 58_000, seconds: 3600, pids: [524])
    let p = Prompts.app(g, title: "Spotlight index", entry: .init(what: "Spotlight writing its index.", advice: "a"), system: calm)
    #expect(p.contains("\"Spotlight index\" is using 45% CPU and 57 MB, running for 1h 0m"))
    #expect(p.contains("Process name: mds_stores (1 process)"))
    #expect(p.contains("My monitor says: Spotlight writing its index."))
    #expect(p.hasSuffix("If it's safe to stop, how?"))
}

@Test func serverPromptFlagsNetworkExposure() {
    let s = Server(pid: 1, uid: 501, command: "node", path: "node", args: "node vite --port 5195", ports: [5195, 5196],
                   exposed: true, project: "web", kind: .dev, rssKB: 30_000, seconds: 600)
    let p = Prompts.server(s)
    #expect(p.contains("listening on :5195, :5196 (reachable from my network)"))
    #expect(p.contains("Started from project: web"))
    #expect(p.contains("or bind it to localhost only?"))
}

@Test func backgroundAndUnknownPrompts() {
    let item = parseBTM(btmFixture)[0]
    #expect(Prompts.background(item, title: "CleanMyMac admin helper")
        .contains("\"CleanMyMac admin helper\": an admin helper (daemon), by MacPaw Way Ltd, currently allowed to run, with admin (root) rights."))
    #expect(Prompts.unknowns([("pmtiles", "/bin/pmtiles")]).hasSuffix("pmtiles\t/bin/pmtiles"))
}
