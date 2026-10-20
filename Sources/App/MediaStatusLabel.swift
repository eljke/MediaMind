import SwiftUI

struct MediaStatusLabel: View {
    let status: TranscriptStatus
    var activity: String? = nil
    var body: some View {
        Group {
            if let activity {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(activity) }
            } else {
                Label(title, systemImage: icon).foregroundStyle(color)
            }
        }.font(.caption).accessibilityElement(children: .combine)
    }
    private var title: String {
        switch status {
        case .empty: return "Без расшифровки"
        case .ready(let count): return "Расшифровка · \(count) фрагментов"
        case .paused: return "Распознавание приостановлено"
        case .failed: return "Ошибка распознавания"
        }
    }
    private var icon: String {
        switch status {
        case .empty: return "text.bubble"
        case .ready: return "checkmark.circle"
        case .paused: return "pause.circle"
        case .failed: return "exclamationmark.triangle"
        }
    }
    private var color: Color {
        switch status {
        case .empty: return .secondary
        case .ready: return .green
        case .paused: return .orange
        case .failed: return .red
        }
    }
}

struct MediaLibraryRow: View {
    let item: MediaItem
    let overview: MediaOverview
    var activity: String? = nil
    var showProgress = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ["mp4", "mov", "m4v"].contains(URL(fileURLWithPath: item.fileName).pathExtension) ? "video.circle.fill" : "waveform.circle.fill")
                .font(.largeTitle).foregroundStyle(.indigo).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title).font(.headline).lineLimit(2)
                Text("\(MediaDetail.time(item.duration)) · \(item.addedAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                MediaStatusLabel(status: overview.transcript, activity: activity)
                if showProgress, let playback = overview.playback {
                    ProgressView(value: playback.position, total: max(1, item.duration))
                        .accessibilityLabel("Прослушано")
                        .accessibilityValue("\(MediaDetail.time(playback.position)) из \(MediaDetail.time(item.duration))")
                    Text("Продолжить с \(MediaDetail.time(playback.position))").font(.caption).foregroundStyle(.indigo)
                }
            }
        }.padding(.vertical, 6)
    }
}
