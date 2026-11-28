import SwiftUI
import Combine
import WebKit

/// The page renders locally. Only files discovered in the character directories
/// can be requested by the model picker.
@MainActor struct CharacterPreview: NSViewRepresentable {
    let model: ReceiverModel
    let visible: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isElementFullscreenEnabled = true
        config.userContentController.add(context.coordinator, name: "characters")
        let view = WKWebView(frame: .zero, configuration: config)
        context.coordinator.attach(view, model: model)
        context.coordinator.setVisible(visible)
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Preview") {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) { context.coordinator.setVisible(visible) }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "characters")
        coordinator.subscription?.cancel()
    }

    @MainActor final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        weak var view: WKWebView?
        var subscription: AnyCancellable?
        private var current = GamepadState()
        private var visible = true
        func setVisible(_ value: Bool) {
            guard value != visible else { return }
            visible = value
            if ready { view?.evaluateJavaScript("preview.visible(\(value))") }
        }
        private var ready = false
        private var files: [String: URL] = [:]

        func attach(_ view: WKWebView, model: ReceiverModel) {
            self.view = view
            view.navigationDelegate = self
            subscription = model.$input.removeDuplicates().sink { [weak self] state in
                self?.current = state
                self?.sendInput()
            }
        }

        private func sendInput() {
            guard ready else { return }
            let s = current
            view?.evaluateJavaScript("preview.input(\(s.thumbLX),\(s.thumbLY),\(s.thumbRX),\(s.thumbRY),\(s.flags),\(s.rightTrigger))")
        }

        private func listModels() {
            var result: [String: URL] = [:]
            let fm = FileManager.default
            var folders = [Bundle.main.resourceURL?.appendingPathComponent("Characters")]
            let applicationSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            // Read legacy custom models too, with PadRelay files taking precedence.
            folders.append(applicationSupport?.appendingPathComponent("Kishi Receiver/Characters", isDirectory: true))
            let support = applicationSupport?.appendingPathComponent("PadRelay/Characters", isDirectory: true)
            if let support {
                try? fm.createDirectory(at: support, withIntermediateDirectories: true)
                folders.append(support)
            }
            for folder in folders.compactMap({ $0 }) {
                let urls = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])) ?? []
                for url in urls where url.pathExtension.lowercased() == "glb" {
                    if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                        result[url.lastPathComponent] = url
                    }
                }
            }
            files = result
            view?.callAsyncJavaScript("preview.catalog(names)", arguments: ["names": result.keys.sorted()], in: nil, in: .page, completionHandler: nil)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.webView === view,
                  let request = message.body as? [String: String] else { return }
            switch request["action"] {
            case "ready":
                ready = true
                view?.evaluateJavaScript("preview.visible(\(visible))")
                listModels()
                sendInput()
            case "list": listModels()
            case "load":
                guard let name = request["name"], let url = files[name] else { return }
                Task {
                    let encoded = await Task.detached(priority: .userInitiated) {
                        (try? Data(contentsOf: url))?.base64EncodedString()
                    }.value
                    view?.callAsyncJavaScript("preview.loaded(name, bytes)", arguments: ["name": name, "bytes": encoded ?? ""], in: nil, in: .page, completionHandler: nil)
                }
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
        }
    }
}
