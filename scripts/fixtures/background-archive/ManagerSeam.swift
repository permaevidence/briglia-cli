
// Appended to ConversationManager.swift in DISPOSABLE builds only
// (scripts/background_archive_inline_test.py), identically for the v0.2.49
// base and the candidate: attaches a recording channel as the reply target.
extension ConversationManager {
    func _inlineAttach(_ channel: any ChatChannel, address: ChannelAddress) {
        channels[channel.kind] = channel
        lastUserChannelAddress = address
    }
}
