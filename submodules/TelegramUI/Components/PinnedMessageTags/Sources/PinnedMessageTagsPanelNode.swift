import Foundation
import UIKit
import Display
import SwiftSignalKit
import TelegramCore
import TelegramPresentationData
import TelegramUIPreferences
import AccountContext
import ContextUI
import ChatPresentationInterfaceState
import ComponentFlow
import HorizontalTabsComponent
import LegacyChatHeaderPanelComponent
import AppBundle

// The row "All / tags" above the pinned messages of a private chat. It is shown while at least one pinned
// message has a tag, and its glass background is only as wide as the tags.
public final class PinnedMessageTagsPanelNode: ChatTitleAccessoryPanelNode {
    private let context: AccountContext
    private let peerId: EnginePeer.Id
    private let manager: PinnedMessageTagsManager
    private let tabs = ComponentView<Empty>()
    private var fittedWidth: CGFloat?

    public init(context: AccountContext, peerId: EnginePeer.Id) {
        self.context = context
        self.peerId = peerId
        self.manager = PinnedMessageTagsManager.shared(context: context)

        super.init()
    }

    // The row changes (selection, tags) without a change of the chat state.
    override public var contentVersion: Int {
        return self.manager.rowVersion
    }

    override public var fittedContentWidth: CGFloat? {
        return self.fittedWidth
    }

    override public func updateLayout(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, transition: ContainedViewLayoutTransition, interfaceState: ChatPresentationInterfaceState) -> LayoutResult {
        let manager = self.manager
        let peerId = self.peerId
        let tags = manager.visibleTags(peerId: peerId)
        let selectedTagId = manager.selectedTagId(peerId: peerId)

        var items: [HorizontalTabsComponent.Tab] = []
        items.append(HorizontalTabsComponent.Tab(
            id: AnyHashable(Int64(0)),
            content: .title(HorizontalTabsComponent.Tab.Title(text: interfaceState.strings.ChatList_Tabs_All, entities: [], enableAnimations: false)),
            badge: nil,
            action: {
                manager.selectTag(id: nil, peerId: peerId)
            }
        ))
        for tag in tags {
            let title = pinnedMessageTagTitle(tag)
            items.append(HorizontalTabsComponent.Tab(
                id: AnyHashable(tag.id),
                content: .title(HorizontalTabsComponent.Tab.Title(text: title.text, entities: title.entities, enableAnimations: true)),
                badge: nil,
                action: {
                    manager.selectTag(id: tag.id, peerId: peerId)
                },
                contextAction: { [weak self] sourceView, gesture in
                    self?.openTagMenu(tag: tag, sourceView: sourceView, gesture: gesture)
                }
            ))
        }

        let tabsSize = self.tabs.update(
            transition: ComponentTransition(transition),
            component: AnyComponent(HorizontalTabsComponent(
                context: self.context,
                theme: interfaceState.theme,
                tabs: items,
                selectedTab: AnyHashable(selectedTagId ?? 0),
                isEditing: false,
                layout: .fit,
                liftWhileSwitching: false
            )),
            environment: {},
            containerSize: CGSize(width: max(1.0, width - leftInset - rightInset), height: 40.0)
        )
        self.fittedWidth = tabsSize.width
        if let tabsView = self.tabs.view as? HorizontalTabsComponent.View {
            if tabsView.superview == nil {
                self.view.addSubview(tabsView)
                tabsView.setOverlayContainerView(overlayContainerView: self.view)
            }
            transition.updateFrame(view: tabsView, frame: CGRect(origin: CGPoint(x: leftInset, y: 0.0), size: tabsSize))
            tabsView.updateTabSwitchFraction(fraction: 0.0, isDragging: false, transition: ComponentTransition(transition))
        }
        return LayoutResult(backgroundHeight: tabsSize.height, insetHeight: tabsSize.height, hitTestSlop: 0.0)
    }

    private func openTagMenu(tag: PinnedMessageTag, sourceView: ContextExtractedContentContainingView, gesture: ContextGesture?) {
        guard let interfaceInteraction = self.interfaceInteraction else {
            return
        }
        let context = self.context
        let manager = self.manager
        let peerId = self.peerId
        let presentationData = context.sharedContext.currentPresentationData.with { $0 }
        let strings = presentationData.strings
        let present: (ViewController) -> Void = { controller in
            interfaceInteraction.presentController(controller, nil)
        }

        var items: [ContextMenuItem] = []
        items.append(.action(ContextMenuActionItem(text: strings.Chat_EditTagTitle_TitleEdit, icon: pinnedMessageTagMenuIcon("Chat/Context Menu/TagEditName"), action: { _, f in
            f(.default)
            Queue.mainQueue().after(0.3) {
                openPinnedMessageTagEditor(context: context, editingTag: tag, present: present, completion: { updatedTag in
                    manager.update { value in
                        if let index = value.tags.firstIndex(where: { $0.id == updatedTag.id }) {
                            value.tags[index] = updatedTag
                        }
                    }
                })
            }
        })))
        items.append(.action(ContextMenuActionItem(text: strings.PinnedTags_ChangeEmoji, icon: pinnedMessageTagMenuIcon("Chat/Context Menu/Tag"), action: { [weak sourceView] _, f in
            f(.default)
            Queue.mainQueue().after(0.3) {
                guard let sourceView else {
                    return
                }
                openPinnedMessageTagEmojiPicker(context: context, sourceView: sourceView.contentView, destinationView: { [weak sourceView] in
                    return sourceView?.contentView
                }, currentFileId: tag.fileId, present: present, completion: { file in
                    manager.update { value in
                        if let index = value.tags.firstIndex(where: { $0.id == tag.id }) {
                            value.tags[index].fileId = file.fileId.id
                        }
                    }
                })
            }
        })))
        items.append(.separator)
        items.append(.action(ContextMenuActionItem(text: strings.PinnedTags_DeleteTag, textColor: .destructive, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Delete"), color: theme.contextMenu.destructiveColor)
        }, action: { _, f in
            f(.default)
            if manager.selectedTagId(peerId: peerId) == tag.id {
                manager.selectTag(id: nil, peerId: peerId)
            }
            manager.update { value in
                value.removeTag(id: tag.id)
            }
        })))

        let controller = makeContextController(
            context: context,
            presentationData: presentationData,
            source: .reference(PinnedMessageTagReferenceContentSource(sourceView: sourceView)),
            items: .single(ContextController.Items(content: .list(items))),
            recognizer: nil,
            gesture: gesture
        )
        interfaceInteraction.presentGlobalOverlayController(controller, nil)
    }
}

private final class PinnedMessageTagReferenceContentSource: ContextReferenceContentSource {
    let keepInPlace: Bool = true
    let actionsHorizontalAlignment: ContextActionsHorizontalAlignment = .center

    private let sourceView: ContextExtractedContentContainingView

    init(sourceView: ContextExtractedContentContainingView) {
        self.sourceView = sourceView
    }

    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(
            referenceView: self.sourceView.contentView,
            contentAreaInScreenSpace: UIScreen.main.bounds,
            actionsPosition: .bottom
        )
    }
}
