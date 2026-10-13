import SwiftUI

/// The view's own one-shot positioning always runs in a nil-animation transaction, so
/// `.animating` only comes from system scrolls (status-bar scroll-to-top, keyboard
/// avoidance). Not releasing there lets the next timeline tick yank the reader back down.
@available(iOS 18.0, *)
func chatReaderScrollReleasesFollow(_ phase: ScrollPhase) -> Bool {
    switch phase {
    case .interacting, .animating:
        true
    case .idle, .tracking, .decelerating:
        false
    @unknown default:
        false
    }
}

/// The parts of a `ScrollPhase` transition the reader acts on, so `ChatView` can stay iOS 17 compatible.
struct ChatReaderScrollPhaseChange {
    let isInteracting: Bool
    let releasesFollow: Bool
    let isIdle: Bool
}

/// iOS 17 backport: `onScrollGeometryChange` / `onScrollPhaseChange` are iOS 18+. On iOS 17 neither
/// callback fires, so the reader stays at the live edge and keeps following the latest message.
struct ChatReaderScrollObserversModifier: ViewModifier {
    let liveEdgeThreshold: CGFloat
    let onLiveEdgeChange: @MainActor (Bool) -> Void
    let onPhaseChange: @MainActor (ChatReaderScrollPhaseChange) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            let liveEdgeThreshold = self.liveEdgeThreshold
            content
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    let distanceFromBottom = geometry.contentSize.height - geometry.visibleRect.maxY
                    return distanceFromBottom <= liveEdgeThreshold
                } action: { _, isAtLiveEdge in
                    self.onLiveEdgeChange(isAtLiveEdge)
                }
                .onScrollPhaseChange { _, phase in
                    self.onPhaseChange(ChatReaderScrollPhaseChange(
                        isInteracting: phase == .interacting,
                        releasesFollow: chatReaderScrollReleasesFollow(phase),
                        isIdle: phase == .idle))
                }
        } else {
            content
        }
    }
}

struct ChatScrollCommand {
    struct Request: Equatable {
        let id = UUID()
        let targetID: UUID
        let anchor: UnitPoint
        let sessionTarget: OpenClawChatSessionTarget
    }

    private(set) var pending: Request?

    mutating func enqueue(to id: UUID, anchor: UnitPoint, sessionTarget: OpenClawChatSessionTarget) {
        self.pending = Request(targetID: id, anchor: anchor, sessionTarget: sessionTarget)
    }

    mutating func cancel() {
        self.pending = nil
    }

    mutating func cancel(targetID: UUID?) {
        guard let targetID, self.pending?.targetID == targetID else { return }
        self.cancel()
    }

    mutating func take(_ request: Request, sessionTarget: OpenClawChatSessionTarget) -> Request? {
        guard self.pending?.id == request.id else { return nil }
        self.pending = nil
        guard request.sessionTarget == sessionTarget else { return nil }
        return request
    }
}

struct ChatScrollCommandModifier: ViewModifier {
    @Binding var command: ChatScrollCommand
    let currentSessionTarget: @MainActor () -> OpenClawChatSessionTarget

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content.onChange(of: self.command.pending) { _, request in
                guard let request else { return }
                // Let the new rows lay out without retaining an ID-based scroll constraint.
                DispatchQueue.main.async {
                    guard let command = self.command.take(request, sessionTarget: self.currentSessionTarget()) else {
                        return
                    }
                    withTransaction(Transaction(animation: nil)) {
                        proxy.scrollTo(command.targetID, anchor: command.anchor)
                    }
                }
            }
        }
    }
}
