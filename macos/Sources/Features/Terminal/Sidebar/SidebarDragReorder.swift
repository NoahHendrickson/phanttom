import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Sidebar tab drag payload: the tab window's `windowNumber` as UTF-8 text.
    static let phanttomSidebarTab = UTType(exportedAs: "com.mitchellh.ghostty.phanttomSidebarTab")

    /// Sidebar project-group drag payload: the project root path as UTF-8 text.
    static let phanttomSidebarGroup = UTType(exportedAs: "com.mitchellh.ghostty.phanttomSidebarGroup")
}

enum SidebarDragReorder {
    static func tabProvider(windowNumber: Int) -> NSItemProvider {
        provider(utf8: String(windowNumber), type: .phanttomSidebarTab)
    }

    static func groupProvider(projectRoot: String) -> NSItemProvider {
        provider(utf8: projectRoot, type: .phanttomSidebarGroup)
    }

    /// Load a UTF-8 string payload and deliver it on the main queue.
    static func loadString(
        from providers: [NSItemProvider],
        type: UTType,
        completion: @escaping (String) -> Void
    ) -> Bool {
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(type.identifier)
        }) else { return false }

        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
            guard let data, let string = String(data: data, encoding: .utf8), !string.isEmpty
            else { return }
            DispatchQueue.main.async {
                completion(string)
            }
        }
        return true
    }

    private static func provider(utf8: String, type: UTType) -> NSItemProvider {
        let provider = NSItemProvider()
        let data = Data(utf8.utf8)
        provider.registerDataRepresentation(
            forTypeIdentifier: type.identifier,
            visibility: .ownProcess
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}
