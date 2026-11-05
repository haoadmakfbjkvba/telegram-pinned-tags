import Foundation
import SwiftSignalKit
import TelegramCore

// A tag is a custom emoji with an optional name. A pinned message can carry one tag; the tags belong to the
// account and are shared by all of its chats. Tags are kept on this device only.
public struct PinnedMessageTag: Equatable, Hashable {
    public var id: Int64
    public var title: String
    public var fileId: Int64

    public init(id: Int64, title: String, fileId: Int64) {
        self.id = id
        self.title = title
        self.fileId = fileId
    }
}

public struct PinnedMessageTags: Equatable, Codable {
    // In the order they were created.
    public var tags: [PinnedMessageTag]
    // Tag of each tagged message.
    public var messageTags: [EngineMessage.Id: Int64]

    public static var `default`: PinnedMessageTags {
        return PinnedMessageTags(tags: [], messageTags: [:])
    }

    public init(tags: [PinnedMessageTag], messageTags: [EngineMessage.Id: Int64]) {
        self.tags = tags
        self.messageTags = messageTags
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StringCodingKey.self)

        let tagIds = try container.decodeIfPresent([Int64].self, forKey: "tagIds") ?? []
        let tagTitles = try container.decodeIfPresent([String].self, forKey: "tagTitles") ?? []
        let tagFileIds = try container.decodeIfPresent([Int64].self, forKey: "tagFileIds") ?? []
        var tags: [PinnedMessageTag] = []
        for i in 0 ..< min(tagIds.count, tagTitles.count, tagFileIds.count) {
            tags.append(PinnedMessageTag(id: tagIds[i], title: tagTitles[i], fileId: tagFileIds[i]))
        }
        self.tags = tags

        let peerIds = try container.decodeIfPresent([Int64].self, forKey: "peerIds") ?? []
        let namespaces = try container.decodeIfPresent([Int32].self, forKey: "namespaces") ?? []
        let messageIds = try container.decodeIfPresent([Int32].self, forKey: "messageIds") ?? []
        let messageTagIds = try container.decodeIfPresent([Int64].self, forKey: "messageTagIds") ?? []
        var messageTags: [EngineMessage.Id: Int64] = [:]
        for i in 0 ..< min(peerIds.count, namespaces.count, messageIds.count, messageTagIds.count) {
            messageTags[EngineMessage.Id(peerId: EnginePeer.Id(peerIds[i]), namespace: namespaces[i], id: messageIds[i])] = messageTagIds[i]
        }
        self.messageTags = messageTags
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StringCodingKey.self)

        try container.encode(self.tags.map(\.id), forKey: "tagIds")
        try container.encode(self.tags.map(\.title), forKey: "tagTitles")
        try container.encode(self.tags.map(\.fileId), forKey: "tagFileIds")

        let messageTags = self.messageTags.sorted(by: { $0.key < $1.key })
        try container.encode(messageTags.map { $0.key.peerId.toInt64() }, forKey: "peerIds")
        try container.encode(messageTags.map { $0.key.namespace }, forKey: "namespaces")
        try container.encode(messageTags.map { $0.key.id }, forKey: "messageIds")
        try container.encode(messageTags.map(\.value), forKey: "messageTagIds")
    }

    public func tag(id: Int64) -> PinnedMessageTag? {
        return self.tags.first(where: { $0.id == id })
    }

    public func tag(messageId: EngineMessage.Id) -> PinnedMessageTag? {
        return self.messageTags[messageId].flatMap { self.tag(id: $0) }
    }

    public mutating func setTag(id: Int64?, messageId: EngineMessage.Id) {
        self.messageTags[messageId] = id
    }

    public mutating func removeTag(id: Int64) {
        self.tags.removeAll(where: { $0.id == id })
        self.messageTags = self.messageTags.filter { $0.value != id }
    }
}

public func updatePinnedMessageTags(engine: TelegramEngine, _ f: @escaping (PinnedMessageTags) -> PinnedMessageTags) -> Signal<Never, NoError> {
    return engine.preferences.update(id: ApplicationSpecificPreferencesKeys.pinnedMessageTags, { entry in
        let current = entry?.get(PinnedMessageTags.self) ?? PinnedMessageTags.default
        return SharedPreferencesEntry(f(current))
    })
}
