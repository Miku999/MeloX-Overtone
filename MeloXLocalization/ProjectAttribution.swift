import SwiftUI

nonisolated enum AppProject {
    private static let repository = "AritxOnly/MeloX-Overtone"
    static let repositoryURL = URL(string: "https://github.com/\(repository)")!
    static let releasesAPI = URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")!
    static let upstreamURL = URL(string: "https://github.com/youshen2/MeloX")!
}

struct ProjectAttribution: View {
    var body: some View {
        Group {
            Text("ui.about.fork_credits")
            Link("ui.about.github", destination: AppProject.repositoryURL)
            Link("ui.about.upstream", destination: AppProject.upstreamURL)
        }
    }
}
