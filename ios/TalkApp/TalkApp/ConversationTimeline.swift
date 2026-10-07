import SwiftUI
import PttTalkLib

private struct MessageFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] { [:] }
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Reading position is independent of delivery updates and background polling.
struct ConversationTimeline<Bubble: View>: View {
    let messages: [ChatConversationMessage]
    @Binding var locate: UUID?
    let presented: (Set<UUID>) -> Void
    let reply: (ChatConversationMessage) -> Void
    @ViewBuilder var bubble: (ChatConversationMessage, Bool) -> Bubble
    @State private var positioned = false
    @State private var atBottom = true
    @State private var newMessages = false
    @State private var unreadBoundary: UUID?
    @State private var visibleIds: Set<UUID> = []

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottom) {
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            if messages.isEmpty { Text("No messages yet. Start the conversation securely.").foregroundStyle(.secondary).padding(32) }
                            ForEach(Array(messages.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || !Calendar.current.isDate(messages[index - 1].message.sentAt, inSameDayAs: item.message.sentAt) {
                                    Text(item.message.sentAt, style: .date)
                                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.vertical, 12)
                                }
                                if unreadBoundary == item.id {
                                    Text("Unread messages").font(.caption.bold()).foregroundStyle(Color.accentColor)
                                        .frame(maxWidth: .infinity).padding(8).background(Color.accentColor.opacity(0.08))
                                }
                                let grouped = index > 0 && messages[index - 1].message.senderAci == item.message.senderAci &&
                                    item.message.sentAt.timeIntervalSince(messages[index - 1].message.sentAt) < 300 && unreadBoundary != item.id &&
                                    Calendar.current.isDate(messages[index - 1].message.sentAt, inSameDayAs: item.message.sentAt)
                                bubble(item, grouped)
                                    .padding(.top, grouped ? 0 : 8)
                                    .id(item.id)
                                    .background(GeometryReader { frame in
                                        Color.clear.preference(key: MessageFrames.self, value: [item.id: frame.frame(in: .named("timeline"))])
                                    })
                                    .simultaneousGesture(DragGesture(minimumDistance: 35).onEnded { value in
                                        if value.translation.width > 70 && abs(value.translation.height) < 35 && !item.isDeleted { reply(item) }
                                    })
                                    .accessibilityAction(named: Text("Reply")) { reply(item) }
                            }
                        }.padding(16)
                    }
                    .coordinateSpace(name: "timeline")
                    .accessibilityIdentifier("Conversation timeline")
                    .onPreferenceChange(MessageFrames.self) { frames in
                        let bounds = CGRect(origin: .zero, size: viewport.size)
                        let ids = Set(frames.filter { $0.value.intersection(bounds).height >= min(40, $0.value.height) }.map(\.key))
                        if ids != visibleIds { visibleIds = ids; if positioned { presented(ids) } }
                        if let last = messages.last, let frame = frames[last.id] { atBottom = frame.maxY <= viewport.size.height + 16 }
                        else { atBottom = messages.isEmpty }
                        if atBottom { newMessages = false }
                    }
                    .onChange(of: messages.map(\.id)) { _ in
                        if !positioned { position(proxy) }
                        else if atBottom { if let last = messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                        else { newMessages = true }
                    }
                    .onAppear { position(proxy) }
                    .onChange(of: positioned) { ready in
                        if ready { DispatchQueue.main.async { presented(visibleIds) } }
                    }
                    .onChange(of: locate) { id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) }; locate = nil }
                    }
                    if newMessages {
                        Button { if let last = messages.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } } label: {
                            Label("New messages", systemImage: "arrow.down").padding(10)
                        }.buttonStyle(.borderedProminent).clipShape(Capsule()).padding(8)
                    }
                }
            }
        }
    }

    private func position(_ proxy: ScrollViewProxy) {
        guard !positioned, !messages.isEmpty else { return }
        unreadBoundary = messages.first(where: \.isUnread)?.id
        let target = locate ?? unreadBoundary ?? messages.last?.id
        DispatchQueue.main.async {
            if let target { proxy.scrollTo(target, anchor: unreadBoundary == nil ? .bottom : .top) }
            positioned = true
        }
    }
}
