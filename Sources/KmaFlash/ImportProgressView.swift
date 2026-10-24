import SwiftUI
struct ImportProgressView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { ProgressView().controlSize(.small); Text(app.importStatus).font(.callout.weight(.medium)).lineLimit(1); Spacer()
                if let progress = app.importProgress { Text("\(Int(progress * 100))%").monospacedDigit().font(.caption) }
            }
            if let progress = app.importProgress { ProgressView(value: progress).progressViewStyle(.linear) }
            else { ProgressView().progressViewStyle(.linear) }
            Text(app.importDetail.isEmpty ? "正在处理，请稍候…" : app.importDetail).font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(KmaTheme.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .combine)
    }
}
