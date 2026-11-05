load("@build_bazel_rules_swift//swift:swift.bzl", "swift_library")

swift_library(
    name = "PinnedMessageTags",
    module_name = "PinnedMessageTags",
    srcs = glob([
        "Sources/**/*.swift",
    ]),
    copts = [
        "-warnings-as-errors",
    ],
    deps = [
        "//submodules/SSignalKit/SwiftSignalKit",
        "//submodules/AsyncDisplayKit",
        "//submodules/Display",
        "//submodules/TelegramCore",
        "//submodules/AccountContext",
        "//submodules/TelegramPresentationData",
        "//submodules/TelegramUIPreferences",
        "//submodules/ContextUI",
        "//submodules/ComponentFlow",
        "//submodules/AppBundle",
        "//submodules/ChatPresentationInterfaceState",
        "//submodules/TelegramUI/Components/HorizontalTabsComponent",
        "//submodules/TelegramUI/Components/LegacyChatHeaderPanelComponent",
        "//submodules/TelegramUI/Components/EmojiStatusSelectionComponent",
        "//submodules/TelegramUI/Components/EntityKeyboard",
        "//submodules/TelegramUI/Components/Chat/SavedTagNameAlertController",
    ],
    visibility = [
        "//visibility:public",
    ],
)
