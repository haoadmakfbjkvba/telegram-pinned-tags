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
import EmojiStatusSelectionComponent
import EntityKeyboard
import SavedTagNameAlertController
import AppBundle

private let tagTitleLengthLimit = 16

// The tag name with its emoji in front: the custom emoji entity takes the place of the first character.
public func pinnedMessageTagTitle(_ tag: PinnedMessageTag) -> (text: String, entities: [MessageTextEntity]) {
    let text = tag.title.isEmpty ? "#" : "# " + tag.title
    return (text, [MessageTextEntity(range: 0 ..< 1, type: .CustomEmoji(stickerPack: nil, fileId: tag.fileId))])
}

// The emoji files of tags. Without a connection they come from what this device already has.
func pinnedMessageTagFiles(context: AccountContext, fileIds: [Int64]) -> Signal<[Int64: TelegramMediaFile], NoError> {
    if fileIds.isEmpty {
        return .single([:])
    }
    return context.engine.stickers.resolveInlineStickers(fileIds: fileIds)
    |> take(1)
    |> timeout(1.5, queue: Queue.concurrentDefaultQueue(), alternate: context.engine.stickers.resolveInlineStickersLocal(fileIds: fileIds) |> take(1))
}

func pinnedMessageTagMenuIcon(_ name: String) -> (PresentationTheme) -> UIImage? {
    return { theme in
        return generateTintedImage(image: UIImage(bundleImageName: name), color: theme.actionSheet.primaryTextColor)
    }
}

// "Add Tag" / "Change Tag" under "Unpin" in the menu of a message pinned in a private chat. It opens a submenu
// with the account's tags, "New Tag" and, for a tagged message, "Remove Tag".
public func pinnedMessageTagMenuItems(context: AccountContext, messageId: EngineMessage.Id, strings: PresentationStrings, interfaceInteraction: ChatPanelInterfaceInteraction) -> [ContextMenuItem] {
    guard messageId.peerId.namespace == Namespaces.Peer.CloudUser else {
        return []
    }
    let manager = PinnedMessageTagsManager.shared(context: context)
    let currentTag = manager.current.tag(messageId: messageId)

    return [.action(ContextMenuActionItem(text: currentTag == nil ? strings.PinnedTags_AddTag : strings.PinnedTags_ChangeTag, icon: pinnedMessageTagMenuIcon("Chat/Context Menu/Tag"), action: { c, _ in
        let items = manager.value
        |> take(1)
        |> mapToSignal { value -> Signal<(PinnedMessageTags, [Int64: TelegramMediaFile]), NoError> in
            return pinnedMessageTagFiles(context: context, fileIds: value.tags.map(\.fileId))
            |> map { files in
                return (value, files)
            }
        }
        |> map { value, files -> ContextController.Items in
            let selectedTagId = value.tag(messageId: messageId)?.id
            var items: [ContextMenuItem] = []

            items.append(.action(ContextMenuActionItem(text: strings.Common_Back, icon: pinnedMessageTagMenuIcon("Chat/Context Menu/Back"), iconPosition: .left, action: { c, _ in
                c?.popItems()
            })))
            items.append(.separator)

            for tag in value.tags {
                let title = pinnedMessageTagTitle(tag)
                let isSelected = tag.id == selectedTagId
                items.append(.action(ContextMenuActionItem(text: title.text, entities: title.entities, entityFiles: files, enableEntityAnimations: true, icon: { theme in
                    // An empty icon of the same size keeps the unchecked tags in line with the checked one.
                    let check = UIImage(bundleImageName: "Chat/Context Menu/Check")
                    if isSelected {
                        return generateTintedImage(image: check, color: theme.actionSheet.primaryTextColor)
                    }
                    return generateImage(check?.size ?? CGSize(width: 24.0, height: 24.0), rotatedContext: { size, context in
                        context.clear(CGRect(origin: CGPoint(), size: size))
                    })
                }, action: { _, f in
                    f(.default)
                    manager.update { value in
                        value.setTag(id: tag.id, messageId: messageId)
                    }
                })))
            }

            items.append(.action(ContextMenuActionItem(text: strings.PinnedTags_NewTag, icon: pinnedMessageTagMenuIcon("Chat/Context Menu/Add"), action: { _, f in
                f(.default)
                // The alert is presented once the menu has gone.
                Queue.mainQueue().after(0.3) {
                    openPinnedMessageTagEditor(context: context, editingTag: nil, present: { controller in
                        interfaceInteraction.presentController(controller, nil)
                    }, completion: { tag in
                        manager.update { value in
                            value.tags.append(tag)
                            value.setTag(id: tag.id, messageId: messageId)
                        }
                    })
                }
            })))

            if selectedTagId != nil {
                items.append(.action(ContextMenuActionItem(text: strings.PinnedTags_RemoveTag, icon: pinnedMessageTagMenuIcon("Chat/Context Menu/TagRemove"), action: { _, f in
                    f(.default)
                    manager.update { value in
                        value.setTag(id: nil, messageId: messageId)
                    }
                })))
            }
            return ContextController.Items(content: .list(items))
        }
        c?.pushItems(items: items)
    }))]
}

// The emoji picker of the emoji status, with all custom emoji. It opens from `sourceView`; the picked emoji flies
// into the view `destinationView` returns.
func openPinnedMessageTagEmojiPicker(context: AccountContext, sourceView: UIView, destinationView: @escaping () -> UIView?, currentFileId: Int64?, present: @escaping (ViewController) -> Void, completion: @escaping (TelegramMediaFile) -> Void) {
    let controller = EmojiStatusSelectionController(
        context: context,
        mode: .backgroundSelection(completion: { file in
            if let file {
                completion(file)
            }
        }),
        sourceView: sourceView,
        emojiContent: EmojiPagerContentComponent.emojiInputData(
            context: context,
            animationCache: context.animationCache,
            animationRenderer: context.animationRenderer,
            isStandalone: false,
            subject: .status,
            hasTrending: false,
            topReactionItems: [],
            areUnicodeEmojiEnabled: false,
            areCustomEmojiEnabled: true,
            chatPeerId: context.account.peerId,
            selectedItems: Set(currentFileId.flatMap { [AnyHashable(EngineMedia.Id(namespace: Namespaces.Media.CloudFile, id: $0))] } ?? []),
            topStatusTitle: nil,
            backgroundIconColor: nil
        ),
        currentSelection: currentFileId,
        color: nil,
        destinationItemView: {
            return destinationView()
        }
    )
    present(controller)
}

// The alert for a new tag (`editingTag == nil`) or for renaming one: the Saved Messages tag alert, with a
// tappable emoji in the text field that opens the emoji picker. `completion` gets the resulting tag. A new tag needs
// an emoji; an edited one keeps its emoji even if its file can't be loaded right now.
func openPinnedMessageTagEditor(context: AccountContext, editingTag: PinnedMessageTag?, present: @escaping (ViewController) -> Void, completion: @escaping (PinnedMessageTag) -> Void) {
    let presentationData = context.sharedContext.currentPresentationData.with { $0 }
    let _ = (pinnedMessageTagFiles(context: context, fileIds: editingTag.flatMap { [$0.fileId] } ?? [])
    |> deliverOnMainQueue).startStandalone(next: { files in
        var currentFileId = editingTag?.fileId
        var updateFileImpl: ((TelegramMediaFile) -> Void)?
        // Until an emoji is picked, the field shows the tag icon in the accent color, at the size of the emoji.
        let placeholder = UIImage(bundleImageName: "Chat/Context Menu/Tag").flatMap { image -> UIImage? in
            let side: CGFloat = 20.0
            let scale = min(side / image.size.width, side / image.size.height)
            let size = CGSize(width: floor(image.size.width * scale), height: floor(image.size.height * scale))
            return generateTintedImage(image: generateImage(size, rotatedContext: { size, context in
                context.clear(CGRect(origin: CGPoint(), size: size))
                UIGraphicsPushContext(context)
                image.draw(in: CGRect(origin: CGPoint(), size: size))
                UIGraphicsPopContext()
            }), color: presentationData.theme.actionSheet.controlAccentColor)
        }
        let editor = savedTagEditorAlertController(
            context: context,
            text: editingTag == nil ? presentationData.strings.PinnedTags_NewTag : presentationData.strings.PinnedTags_EditTag,
            subtext: presentationData.strings.PinnedTags_EditorText,
            value: editingTag?.title ?? "",
            file: editingTag.flatMap { files[$0.fileId] },
            emojiPlaceholder: placeholder,
            emojiRequired: editingTag == nil,
            characterLimit: tagTitleLengthLimit,
            emojiAction: { sourceView, destinationView in
                openPinnedMessageTagEmojiPicker(context: context, sourceView: sourceView, destinationView: destinationView, currentFileId: currentFileId, present: present, completion: { file in
                    currentFileId = file.fileId.id
                    updateFileImpl?(file)
                })
            },
            apply: { title, file in
                let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                if let editingTag {
                    completion(PinnedMessageTag(id: editingTag.id, title: title, fileId: file?.fileId.id ?? editingTag.fileId))
                } else if let file {
                    completion(PinnedMessageTag(id: Int64.random(in: 1 ... Int64.max), title: title, fileId: file.fileId.id))
                }
            }
        )
        updateFileImpl = editor.updateFile
        present(editor.controller)
    })
}
