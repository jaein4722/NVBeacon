import SwiftUI

struct OpenSourceLicensesView: View {
    // The notices run past 100 KB; a single Text that large renders blank, so show them paragraph by paragraph.
    private static let paragraphs: [String]? = {
        guard let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
              let notices = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = notices.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts
    }()

    var body: some View {
        ScrollView {
            if let paragraphs = Self.paragraphs {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(paragraphs.indices, id: \.self) { index in
                        Text(verbatim: paragraphs[index])
                            .font(.footnote)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
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
