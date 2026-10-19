import Foundation

/// Opt-in background pruning (BACKGROUND_PRUNE_PLAN v4.1). Types only; the
/// behaviour lives in the marked ConversationManager extension.
@MainActor
final class BackgroundPruneJob {
    let id = UUID()
}
