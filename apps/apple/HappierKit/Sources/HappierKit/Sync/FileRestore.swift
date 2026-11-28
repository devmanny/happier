import Foundation

/// An Edit from Here waiting for the user to say what happens to the files on disk
/// (`HappierStore.editFromHere`): the agent's own checkpoints (`session.restoreFiles`,
/// `packages/protocol/src/sessionRestoreFiles.ts`) can put the conversation's folder back as it
/// was just before the message.
public struct FileRestoreQuestion: Equatable, Sendable {
    /// The message as the conversation shows it: the files go back to just before it.
    public let message: MessageVersion
    /// Where the branch is made from (`editTarget`): the message itself, or the one it's a
    /// version of.
    public let from: MessageVersion
    /// What comes back in the branch's composer.
    public let text: String
    /// The files restoring would put back (paths as the agent reports them); nil when the agent
    /// can restore files but has no restore point for this message.
    public let files: [String]?
}

/// What a dry run of restoring the files before a message found.
enum FileRestoreOffer: Equatable, Sendable {
    /// These files changed since the message.
    case files([String])
    /// The agent can restore files, but has no restore point for this message.
    case unavailable
    /// Nothing to offer (an agent that can't, nothing changed, the agent mid-turn, a daemon from
    /// before restores, or no answer): editing goes ahead as it always did.
    case none
}
