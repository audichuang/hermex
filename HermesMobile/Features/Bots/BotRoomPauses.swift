import SwiftUI

struct BotRoomPause: Equatable {
    let count: Int
    let actionable: Bool
    let discussionEventID: String

    static func pauses(in events: [BotRoomEvent], maxContinues: Int) -> [Int: BotRoomPause] {
        var messageCounts: [String: Int] = [:]
        var continueCounts: [String: Int] = [:]
        var countsAtPause: [Int: Int] = [:]
        var sourceSequences: [String: Int] = [:]
        var latestUserInThread: [String: Int] = [:]
        var latestStop = 0

        for event in events {
            if event.kind == "room.stop_requested" { latestStop = event.seq }
            if event.kind == "message.user" {
                if let id = event.eventID { sourceSequences[id] = event.seq }
                if let thread = event.threadID { latestUserInThread[thread] = event.seq }
            }
            guard let discussion = event.payload["discussion_event_id"].text else { continue }
            if event.kind == "message.member" { messageCounts[discussion, default: 0] += 1 }
            if event.kind == "room.continued" { continueCounts[discussion, default: 0] += 1 }
            if event.isBoundedActivity { countsAtPause[event.seq] = messageCounts[discussion, default: 0] }
        }

        var result: [Int: BotRoomPause] = [:]
        var laterDiscussions: Set<String> = []
        for event in events.reversed() {
            guard event.isBoundedActivity || event.kind == "room.continued" else { continue }
            let discussion = event.payload["discussion_event_id"].text ?? ""
            let isLatest = laterDiscussions.insert(discussion).inserted
            guard event.isBoundedActivity else { continue }
            let source = sourceSequences[discussion] ?? event.seq
            let latestReply = event.threadID.flatMap { latestUserInThread[$0] } ?? 0
            let actionable = !discussion.isEmpty && isLatest && latestStop <= source && latestReply <= source
                && continueCounts[discussion, default: 0] < maxContinues
            result[event.seq] = BotRoomPause(count: countsAtPause[event.seq, default: 0],
                                             actionable: actionable, discussionEventID: discussion)
        }
        return result
    }
}

struct BotRoomPausedRow: View {
    let event: BotRoomEvent
    let reader: BotRoomReader
    @State private var confirmingStop = false

    private var pause: BotRoomPause? { reader.pauses[event.seq] }

    var body: some View {
        VStack(spacing: 6) {
            if let pause {
                Text("Paused · Messages: \(pause.count)")
                    .font(AppFont.caption()).foregroundStyle(.appSecondary)
                if pause.actionable {
                    ViewThatFits(in: .horizontal) {
                        HStack { buttons(pause) }.fixedSize(horizontal: true, vertical: false)
                        VStack { buttons(pause) }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                Text(event.systemText)
                    .font(AppFont.caption()).foregroundStyle(.appSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
        .alert("Stop room work?", isPresented: $confirmingStop) {
            Button("Stop", role: .destructive, action: stop)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Work in other threads will also stop.")
        }
    }

    @ViewBuilder private func buttons(_ pause: BotRoomPause) -> some View {
        Button("Continue") { Task { await reader.continueDiscussion(pause.discussionEventID) } }
            .disabled(!reader.mayContinue)
        Button("Stop", role: .destructive) {
            if reader.pausedStopNeedsConfirmation { confirmingStop = true }
            else { stop() }
        }
        .accessibilityLabel(Text("Stop every bot in this room"))
        .disabled(!reader.mayStopPaused)
    }

    private func stop() {
        guard pause?.actionable == true else { return }
        Task { await reader.stopPausedDiscussion() }
    }
}
