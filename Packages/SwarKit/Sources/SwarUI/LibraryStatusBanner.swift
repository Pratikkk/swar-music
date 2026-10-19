import SwiftUI
import Library

/// Observes only scan/error state so progress ticks do not invalidate the
/// surrounding song or album list while the user is scrolling.
@MainActor
struct LibraryStatusBanner: View {
    let library: LibraryModel
    var inset: CGFloat = 0
    var dismissibleError = false
    var detailedProgress = false

    var body: some View {
        if library.errorMessage != nil || library.progress != nil {
            VStack(spacing: 8) {
                if let error = library.errorMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .lineLimit(detailedProgress ? 3 : 2)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        if dismissibleError {
                            Button { library.dismissError() } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dismiss library error")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
                if let progress = library.progress {
                    if detailedProgress {
                        HStack(spacing: 8) {
                            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                                .frame(maxWidth: 180)
                            Text("\(progress.folder): \(progress.completed) of \(progress.total)")
                            if progress.failed > 0 {
                                Text("\(progress.failed) unreadable").foregroundStyle(.orange)
                            }
                            Spacer(minLength: 0)
                        }
                        .font(.caption)
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Updating library · \(progress.completed) of \(progress.total)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            .padding(.horizontal, inset)
            .padding(.vertical, 8)
        }
    }
}
