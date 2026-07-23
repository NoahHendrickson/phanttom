import Testing
@testable import Ghostty

/// Tests for the pure merge/strip logic behind the Claude Code hook
/// installer. See PHANTTOM.md "Claude Code integration (hooks protocol)"
/// for the ownership rules these encode.
@Suite
@MainActor
struct PhanttomClaudeIntegrationTests {
    private typealias Integration = PhanttomClaudeIntegration

    /// Events the specs install into, with expected entry counts.
    private let expectedCounts = [
        "UserPromptSubmit": 3,
        "Stop": 1,
        "Notification": 1,
        "SessionStart": 1,
        "PostToolUse": 1,
    ]

    private func entries(
        _ root: [String: Any], _ event: String
    ) -> [[String: Any]] {
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        return hooks[event] as? [[String: Any]] ?? []
    }

    private func commands(
        _ root: [String: Any], _ event: String
    ) -> [String] {
        entries(root, event).flatMap { entry -> [String] in
            let inner = entry["hooks"] as? [[String: Any]] ?? []
            return inner.compactMap { $0["command"] as? String }
        }
    }

    // MARK: - Merge

    @Test func mergeIntoFreshFileInstallsAllHooks() throws {
        let result = try #require(Integration.merged(into: [:]))
        for (event, count) in expectedCounts {
            #expect(entries(result, event).count == count)
        }
        let postToolUse = entries(result, "PostToolUse")
        #expect(
            postToolUse.first?["matcher"] as? String
                == "EnterWorktree|ExitWorktree")
    }

    @Test func mergePreservesUserContent() throws {
        let userHook: [String: Any] = [
            "hooks": [["type": "command", "command": "echo mine"]]
        ]
        let root: [String: Any] = [
            "model": "opus",
            "hooks": ["UserPromptSubmit": [userHook], "PreToolUse": [userHook]],
        ]
        let result = try #require(Integration.merged(into: root))
        #expect(result["model"] as? String == "opus")
        #expect(commands(result, "PreToolUse") == ["echo mine"])
        // User's entry survives, ours are appended after it.
        let prompt = commands(result, "UserPromptSubmit")
        #expect(prompt.first == "echo mine")
        #expect(prompt.count == 4)
    }

    @Test func mergeReplacesLegacyDevTtyVariants() throws {
        // The /dev/tty-era commands: same payload signatures, broken write.
        let legacy: [String: Any] = [
            "hooks": [
                "UserPromptSubmit": [
                    [
                        "hooks": [[
                            "type": "command",
                            "command":
                                #"printf '\033]9;4;3;0\033\\' > /dev/tty 2>/dev/null || true"#,
                        ]]
                    ]
                ],
                "Stop": [
                    [
                        "hooks": [[
                            "type": "command",
                            "command":
                                #"printf '\033]9;4;0;0\033\\' > /dev/tty 2>/dev/null || true"#,
                        ]]
                    ]
                ],
            ]
        ]
        let result = try #require(Integration.merged(into: legacy))
        for event in ["UserPromptSubmit", "Stop"] {
            for command in commands(result, event) {
                #expect(!command.contains("> /dev/tty"))
                #expect(command.contains("CLAUDE_PID"))
            }
        }
        #expect(commands(result, "UserPromptSubmit").count == 3)
        #expect(commands(result, "Stop").count == 1)
    }

    @Test func mergeIsIdempotent() throws {
        let once = try #require(Integration.merged(into: [:]))
        #expect(Integration.merged(into: once) == nil)
    }

    @Test func mergeLeavesNonArrayEventValuesAlone() throws {
        let root: [String: Any] = ["hooks": ["Stop": "not an array"]]
        let result = try #require(Integration.merged(into: root))
        // The malformed value is preserved... under a shape our specs don't
        // use; our Stop hook still lands because merged appends to a fresh
        // array when the existing value has the wrong type.
        let hooks = result["hooks"] as? [String: Any]
        #expect(hooks?["Stop"] as? [[String: Any]] != nil)
    }

    // MARK: - Strip

    @Test func stripRemovesOnlyPhanttomEntries() throws {
        let installed = try #require(Integration.merged(into: [
            "hooks": [
                "UserPromptSubmit": [
                    ["hooks": [["type": "command", "command": "echo mine"]]]
                ]
            ]
        ]))
        let stripped = Integration.strip(from: installed)
        #expect(commands(stripped, "UserPromptSubmit") == ["echo mine"])
        #expect(entries(stripped, "Stop").isEmpty)
    }

    @Test func stripKeepsUserHookSharingAnEntryWithOurs() {
        let mixed: [String: Any] = [
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": "echo mine"],
                            [
                                "type": "command",
                                "command":
                                    #"printf '\033]9;4;0;0\033\\' > /dev/tty"#,
                            ],
                        ]
                    ]
                ]
            ]
        ]
        let stripped = Integration.strip(from: mixed)
        #expect(commands(stripped, "Stop") == ["echo mine"])
    }

    @Test func stripDropsEventsLeftEmpty() throws {
        let installed = try #require(Integration.merged(into: [:]))
        let stripped = Integration.strip(from: installed)
        let hooks = stripped["hooks"] as? [String: Any]
        #expect(hooks?.isEmpty == true)
    }

    // MARK: - Protocol guards

    /// The title hook must keep the model-extracting form: marker, prompt,
    /// second U+2063, model id from the transcript. A downgrade here breaks
    /// the sidebar's model badge (PhanttomTabState parses this format).
    @Test func titleSpecEmitsModelField() {
        let title = Integration.hookSpecs
            .first { $0.event == "UserPromptSubmit" && $0.command.contains("]2;") }
        #expect(title?.command.contains("transcript_path") == true)
        #expect(
            title?.command.contains(
                #"\xe2\x9d\xaf\xe2\x81\xa3 %s\xe2\x81\xa3%s"#) == true)
    }

    @Test func everySpecResolvesTtyViaClaudePid() {
        for spec in Integration.hookSpecs {
            #expect(spec.command.contains("CLAUDE_PID"))
            // Empty/`?`/`??` all mean "no controlling terminal"; a bare `?`
            // must not become `/dev/?`.
            #expect(spec.command.contains(#"|"?"|"??"#))
            #expect(Integration.isPhanttomCommand(spec.command))
        }
    }
}
