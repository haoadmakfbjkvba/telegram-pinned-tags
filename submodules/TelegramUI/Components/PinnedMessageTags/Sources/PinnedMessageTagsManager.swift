import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import TelegramUIPreferences

// Pinned messages in a private chat can be tagged: a tag is a custom emoji with a name, picked from the
// message menu ("Add Tag"). The list of pinned messages then shows a row "All / tags" above the messages
// that filters them by tag; holding a tag in the row renames it, changes its emoji or deletes it.
// The tags are stored on this device (TelegramUIPreferences, PinnedMessageTags).
public final class PinnedMessageTagsManager {
    private static let managers = Atomic<[EnginePeer.Id: PinnedMessageTagsManager]>(value: [:])

    // One manager per account (a new one after the account signs in again). Any thread may read `current`
    // (message menus are built off the main thread); the rest is used on the main thread.
    public static func shared(context: AccountContext) -> PinnedMessageTagsManager {
        var removed: [PinnedMessageTagsManager] = []
        let manager = self.managers.modify { managers in
            var managers = managers
            // Managers of accounts that are gone: they would keep the account's database open.
            for (peerId, manager) in managers where manager.context == nil {
                removed.append(manager)
                managers.removeValue(forKey: peerId)
            }
            if managers[context.account.peerId]?.context !== context {
                if let previous = managers[context.account.peerId] {
                    removed.append(previous)
                }
                managers[context.account.peerId] = PinnedMessageTagsManager(context: context)
            }
            return managers
        }[context.account.peerId]!
        // Released here, outside of the lock: their deinit stops their subscriptions.
        withExtendedLifetime(removed) {}
        return manager
    }

    private weak var context: AccountContext?
    private let currentValue = Atomic<PinnedMessageTags>(value: .default)
    private let valuePromise = Promise<PinnedMessageTags>()
    private var disposable: Disposable?

    // The tag picked in the row above the pinned messages of a chat (none means "All").
    private var selectedTagIds: [EnginePeer.Id: Int64] = [:]
    private let selectedTagIdsPromise = ValuePromise<[EnginePeer.Id: Int64]>([:], ignoreRepeated: true)
    // The tags that are on the pinned messages of a chat right now, which the row shows.
    private var visibleTags: [EnginePeer.Id: [PinnedMessageTag]] = [:]
    // Changes whenever the row has to be drawn again.
    public private(set) var rowVersion: Int = 0

    private init(context: AccountContext) {
        self.context = context

        let value = context.engine.data.subscribe(TelegramEngine.EngineData.Item.Configuration.ApplicationSpecificPreference(key: ApplicationSpecificPreferencesKeys.pinnedMessageTags))
        |> map { entry -> PinnedMessageTags in
            return entry?.get(PinnedMessageTags.self) ?? PinnedMessageTags.default
        }
        |> distinctUntilChanged
        self.valuePromise.set(value)
        self.disposable = value.startStrict(next: { [weak self] value in
            let _ = self?.currentValue.swap(value)
        })
    }

    deinit {
        self.disposable?.dispose()
    }

    public var current: PinnedMessageTags {
        return self.currentValue.with { $0 }
    }

    public var value: Signal<PinnedMessageTags, NoError> {
        return self.valuePromise.get()
    }

    public func update(_ f: @escaping (inout PinnedMessageTags) -> Void) {
        guard let context = self.context else {
            return
        }
        let _ = updatePinnedMessageTags(engine: context.engine, { value in
            var value = value
            f(&value)
            return value
        }).startStandalone()
    }

    public func selectedTagId(peerId: EnginePeer.Id) -> Int64? {
        return self.selectedTagIds[peerId]
    }

    public func selectedTagIdSignal(peerId: EnginePeer.Id) -> Signal<Int64?, NoError> {
        return self.selectedTagIdsPromise.get()
        |> map { $0[peerId] }
        |> distinctUntilChanged
    }

    public func selectTag(id: Int64?, peerId: EnginePeer.Id) {
        if self.selectedTagIds[peerId] == id {
            return
        }
        self.selectedTagIds[peerId] = id
        self.rowVersion += 1
        self.selectedTagIdsPromise.set(self.selectedTagIds)
    }

    public func visibleTags(peerId: EnginePeer.Id) -> [PinnedMessageTag] {
        return self.visibleTags[peerId] ?? []
    }

    public func setVisibleTags(_ tags: [PinnedMessageTag], peerId: EnginePeer.Id) {
        if self.visibleTags[peerId] ?? [] == tags {
            return
        }
        self.visibleTags[peerId] = tags.isEmpty ? nil : tags
        self.rowVersion += 1
    }
}
