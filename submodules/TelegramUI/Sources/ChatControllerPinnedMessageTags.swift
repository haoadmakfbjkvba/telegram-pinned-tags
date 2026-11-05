import Foundation
import SwiftSignalKit
import TelegramCore
import AccountContext
import PinnedMessageTags

extension ChatControllerImpl {
    // Called when the chat screen loads. Reads the tags early, as the menu of a pinned message needs them right
    // away. In the list of pinned messages of a private chat, it shows the tags row (see
    // ChatInterfaceTitlePanelNodes) and hides the messages that don't have the picked tag.
    func setupPinnedMessageTags() {
        let manager = PinnedMessageTagsManager.shared(context: self.context)

        guard case .pinnedMessages = self.subject, case let .peer(peerId) = self.chatLocation, peerId.namespace == Namespaces.Peer.CloudUser else {
            return
        }
        manager.selectTag(id: nil, peerId: peerId)
        manager.setVisibleTags([], peerId: peerId)
        // Filtered messages leave the list without the deletion effect.
        self.chatDisplayNode.historyNode.ignoreMessageIdsAnimateAsDeletion = false

        let pinnedMessageIds = self.context.account.viewTracker.aroundMessageHistoryViewForLocation(.peer(peerId: peerId, threadId: nil), index: .upperBound, anchorIndex: .upperBound, count: 1000, clipHoles: false, fixedCombinedReadStates: nil, tag: .tag(.pinned))
        |> filter { view, _, _ in
            return !view.isLoading
        }
        |> map { view, _, _ -> Set<EngineMessage.Id> in
            return Set(view.entries.map { $0.message.id })
        }
        |> distinctUntilChanged

        var previousRowVersion: Int?
        self.pinnedMessageTagsDisposable = (combineLatest(queue: .mainQueue(), manager.value, manager.selectedTagIdSignal(peerId: peerId), pinnedMessageIds, self.chatDisplayNode.historyNode.pendingRemovedMessagesSignal)
        |> deliverOnMainQueue).startStrict(next: { [weak self] value, selectedTagId, pinnedMessageIds, pendingRemovedMessageIds in
            guard let self else {
                return
            }
            // A message unpinned from this list stays pinned until its undo toast goes away; it already counts as unpinned.
            let pinnedMessageIds = pinnedMessageIds.subtracting(pendingRemovedMessageIds)

            // The row shows the tags that are on at least one pinned message.
            var usedTagIds = Set<Int64>()
            for messageId in pinnedMessageIds {
                if let tagId = value.messageTags[messageId] {
                    usedTagIds.insert(tagId)
                }
            }
            manager.setVisibleTags(value.tags.filter { usedTagIds.contains($0.id) }, peerId: peerId)

            var effectiveTagId = selectedTagId
            if let tagId = effectiveTagId, !usedTagIds.contains(tagId) {
                effectiveTagId = nil
                manager.selectTag(id: nil, peerId: peerId)
            }

            var hiddenMessageIds = Set<EngineMessage.Id>()
            if let tagId = effectiveTagId {
                for messageId in pinnedMessageIds where value.messageTags[messageId] != tagId {
                    hiddenMessageIds.insert(messageId)
                }
            }
            var updated = false
            if self.chatDisplayNode.historyNode.ignoreMessageIds != hiddenMessageIds {
                self.chatDisplayNode.historyNode.ignoreMessageIds = hiddenMessageIds
                updated = true
            }
            if previousRowVersion != manager.rowVersion {
                previousRowVersion = manager.rowVersion
                updated = true
            }
            if updated {
                self.requestLayout(transition: .animated(duration: 0.4, curve: .spring))
            }
        })
    }
    
    // The pinned messages list closes itself once it is empty. While it has the tags row, it may be empty only
    // because of the filter, or because of a filter that has just been switched off: then it goes back to all
    // messages and closes only if it is still empty a moment later. Returns true when it takes over the closing.
    func deferClosingEmptyPinnedMessagesForTags() -> Bool {
        guard case .pinnedMessages = self.subject, case let .peer(peerId) = self.chatLocation, peerId.namespace == Namespaces.Peer.CloudUser else {
            return false
        }
        let manager = PinnedMessageTagsManager.shared(context: self.context)
        guard manager.selectedTagId(peerId: peerId) != nil || !manager.visibleTags(peerId: peerId).isEmpty || !self.chatDisplayNode.historyNode.ignoreMessageIds.isEmpty else {
            return false
        }
        manager.selectTag(id: nil, peerId: peerId)
        Queue.mainQueue().after(0.4, { [weak self] in
            guard let self else {
                return
            }
            if case .empty = self.chatDisplayNode.historyNode.loadState, self.chatDisplayNode.historyNode.ignoreMessageIds.isEmpty {
                self.dismiss()
            }
        })
        return true
    }
}
