import SwiftUI

struct OpenSourceLicensesView: View {
    private static let notices: String? = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }()

    var body: some View {
        ScrollView {
            if let notices = Self.notices {
                Text(verbatim: notices)
                    .font(.footnote)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            } else {
                ContentUnavailableView("Licenses unavailable", systemImage: "doc.text",
                    description: Text("The license notices could not be loaded."))
            }
        }
        .navigationTitle("Open Source Licenses")
        .navigationBarTitleDisplayMode(.inline)
    }
}
