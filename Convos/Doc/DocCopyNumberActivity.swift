import UIKit

class DocCopyNumberActivity: UIActivity {
    private let number: String

    init(number: String) {
        self.number = number
        super.init()
    }

    override class var activityCategory: UIActivity.Category { .action }

    override var activityType: UIActivity.ActivityType? {
        UIActivity.ActivityType("org.convos.copy-doc-number")
    }

    override var activityTitle: String? { "Copy Number" }

    override var activityImage: UIImage? { UIImage(systemName: "doc.on.doc") }

    override func canPerform(withActivityItems activityItems: [Any]) -> Bool { true }

    override func perform() {
        UIPasteboard.general.string = number
        activityDidFinish(true)
    }
}
