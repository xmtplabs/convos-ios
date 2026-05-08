import ConvosCore
import SafariServices
import UIKit

enum InAppBrowser {
    static func open(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        guard ["http", "https"].contains(scheme) else {
            Task { @MainActor in
                UIApplication.shared.open(url)
            }
            return
        }
        Task { @MainActor in
            guard let presenter = topPresentedViewController() else {
                Log.warning("InAppBrowser: no presenter found, falling back to system browser for \(url.host ?? "")")
                UIApplication.shared.open(url)
                return
            }
            let safari = SFSafariViewController(url: url)
            presenter.present(safari, animated: true)
        }
    }

    @MainActor
    private static func topPresentedViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        guard let root = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController else {
            return nil
        }
        var presenter = root
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        return presenter
    }
}
