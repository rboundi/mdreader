import SwiftUI

/// Sidebar listing the document's headings; highlights the section currently in view.
struct OutlineView: View {
    @EnvironmentObject private var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("OUTLINE")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            if state.selected?.showSource == true {
                placeholder("Not available in Markdown view")
            } else if state.outline.isEmpty {
                placeholder("No headings")
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(state.outline) { item in
                                row(item).id(item.id)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 12)
                    }
                    .onChange(of: state.activeHeading) { id in
                        if let id { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 230)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func row(_ item: OutlineItem) -> some View {
        let minLevel = state.outline.map(\.level).min() ?? 1
        let active = item.id == state.activeHeading
        return Button {
            state.scrollToHeading(item.id)
        } label: {
            Text(item.text)
                .font(.system(size: 12, weight: item.level == minLevel ? .medium : .regular))
                .foregroundStyle(active ? Color.accentColor : item.level == minLevel ? .primary : .secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, CGFloat(item.level - minLevel) * 12 + 8)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(active ? Color.accentColor.opacity(0.12) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.text)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 4)
    }
}
