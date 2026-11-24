import SwiftUI

/// 审计日志：谁在什么时候改了什么。
struct AuditLogView: View {
    @State private var entries: [SQLiteStore.AuditEntry] = []

    var body: some View {
        List {
            if entries.isEmpty {
                Text("还没有校正记录")
                    .font(.footnote)
                    .foregroundStyle(Theme.ink3)
            }
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: Theme.s2) {
                        Text(entry.action)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Tag(text: entry.operatorName, color: Theme.jade)
                        Spacer(minLength: Theme.s2)
                        Text(Fmt.dayTimeString(entry.ts))
                            .font(Theme.number(11, weight: .regular))
                            .foregroundStyle(Theme.ink3)
                    }
                    Text(entry.target)
                        .font(.caption)
                        .foregroundStyle(Theme.ink2)
                    Text(entry.detail)
                        .font(.caption2)
                        .foregroundStyle(Theme.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
                .listRowBackground(Theme.surface)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(PaperBackground())
        .navigationTitle("审计日志")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { entries = SQLiteStore.shared.auditEntries() }
    }
}
