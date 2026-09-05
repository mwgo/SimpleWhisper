import AppKit
import SwiftUI

/// Floating panel listing the recent dictations/commands as cards; clicking one copies its text.
@MainActor
final class HistoryWindowController {
    private var panel: NSPanel?
    private let store: DataStore
    private let onCopy: (HistoryEntry) -> Void
    private let onPaste: (HistoryEntry) -> Void

    init(store: DataStore, onCopy: @escaping (HistoryEntry) -> Void, onPaste: @escaping (HistoryEntry) -> Void) {
        self.store = store
        self.onCopy = onCopy
        self.onPaste = onPaste
    }

    func show() {
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.title = "History"
            panel.level = .floating
            panel.isReleasedWhenClosed = false
            panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: HistoryView(
                store: store,
                onCopy: { [weak self] entry in
                    self?.panel?.orderOut(nil)
                    self?.onCopy(entry)
                },
                onPaste: { [weak self] entry in
                    self?.panel?.orderOut(nil)
                    self?.onPaste(entry)
                }
            ))
            panel.center()
            self.panel = panel
        }
        panel?.makeKeyAndOrderFront(nil)
    }

    var windowNumber: Int { panel?.windowNumber ?? 0 }
}

struct HistoryView: View {
    var store: DataStore
    var onCopy: (HistoryEntry) -> Void
    var onPaste: (HistoryEntry) -> Void
    @State private var copiedID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            if store.recentHistory.isEmpty {
                ContentUnavailableView("No history yet", systemImage: "clock.arrow.circlepath", description: Text("Dictations and commands will appear here."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.recentHistory) { entry in
                            HistoryCard(entry: entry, copied: copiedID == entry.id, onPaste: { onPaste(entry) })
                                .onTapGesture { copy(entry) }
                        }
                    }
                    .padding(14)
                }
            }
            Divider()
            HStack {
                Text("Click a card to copy its text, ▶ pastes it into the active editor. Showing the last \(HistoryEntry.maxShown).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear") { store.history.removeAll() }
                    .disabled(store.history.isEmpty)
                    .controlSize(.small)
            }
            .padding(10)
        }
        .frame(minWidth: 360, minHeight: 300)
    }

    private func copy(_ entry: HistoryEntry) {
        onCopy(entry)
    }
}

private struct HistoryCard: View {
    var entry: HistoryEntry
    var copied: Bool
    var onPaste: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: entry.kind == .command ? "play.circle.fill" : "mic.fill")
                    .font(.caption2)
                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                if let language = entry.language {
                    Text(language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Spacer()
                if copied {
                    Label("Copied to clipboard", systemImage: "checkmark")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(HUDView.freshGreen)
                        .transition(.opacity)
                } else if hovering {
                    Image(systemName: "doc.on.doc").font(.caption)
                        .help("Click the card to copy")
                    Button(action: onPaste) {
                        Image(systemName: "play").font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Paste into the active editor")
                }
            }
            .foregroundStyle(.secondary)
            if let instruction = entry.instruction, entry.kind == .command {
                Text(instruction)
                    .font(.callout.italic())
                    .foregroundStyle(.secondary)
            }
            Text(entry.text)
                .font(.body)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(copied ? HUDView.freshGreen : Color.secondary.opacity(hovering ? 0.35 : 0.15), lineWidth: 1))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: copied)
    }
}
