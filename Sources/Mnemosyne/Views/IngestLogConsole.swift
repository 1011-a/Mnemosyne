import SwiftUI

/// A terminal-style console that streams the ingestion log under the live-activity scene, so you
/// can SEE what's happening during slow steps (audio transcription, OCR, embedding) and tell at a
/// glance that ingest is working, not stuck. Theme-independent — shown for every live-activity
/// scene. Auto-scrolls to the newest line.
struct IngestLogConsole: View {
    @Bindable var progress: IngestProgress

    private func color(_ level: IngestLogLine.Level) -> Color {
        switch level {
        case .added: return DS.ColorToken.success
        case .skip:  return DS.ColorToken.textTertiary
        case .warn:  return DS.ColorToken.warning
        case .work:  return DS.ColorToken.iris
        }
    }

    var body: some View {
        if !progress.log.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.x2) {
                HStack(spacing: 6) {
                    Circle().fill(progress.isRunning ? DS.ColorToken.success : DS.ColorToken.textTertiary)
                        .frame(width: 6, height: 6)
                    Text("Activity log").font(DS.Typo.caption)
                        .foregroundStyle(DS.ColorToken.textTertiary)
                    Spacer()
                    if progress.isRunning, !progress.currentFile.isEmpty {
                        Text(progress.activity.isEmpty ? "working…" : progress.activity)
                            .font(DS.Typo.caption).foregroundStyle(DS.ColorToken.textTertiary)
                            .lineLimit(1)
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(progress.log.suffix(60)) { line in
                                HStack(alignment: .top, spacing: 8) {
                                    Text(line.symbol).foregroundStyle(color(line.level))
                                        .frame(width: 10, alignment: .center)
                                    Text(line.text).foregroundStyle(DS.ColorToken.textSecondary)
                                        .lineLimit(1).truncationMode(.middle)
                                    Spacer(minLength: 0)
                                }
                                .font(DS.Typo.mono)
                                .id(line.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Space.x4).padding(.vertical, DS.Space.x3)
                    }
                    .frame(height: 132)
                    .onChange(of: progress.log.last?.id) { _, id in
                        guard let id else { return }
                        withAnimation(DS.Motion.snappy) { proxy.scrollTo(id, anchor: .bottom) }
                    }
                    .onAppear {
                        if let id = progress.log.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                    }
                }
                .background(Color.black.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .strokeBorder(DS.ColorToken.borderDefault))
            }
        }
    }
}
