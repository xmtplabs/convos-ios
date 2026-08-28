import Contacts
import ContactsUI
import SwiftUI

struct DocAddContactView: UIViewControllerRepresentable {
    let name: String
    let phoneNumber: String
    @Environment(\.dismiss) private var dismiss: DismissAction

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    func makeUIViewController(context: Context) -> UINavigationController {
        let contact = CNMutableContact()
        contact.givenName = name
        contact.phoneNumbers = [
            CNLabeledValue(
                label: CNLabelPhoneNumberMobile,
                value: CNPhoneNumber(stringValue: phoneNumber)
            ),
        ]

        let contactViewController = CNContactViewController(forUnknownContact: contact)
        contactViewController.contactStore = CNContactStore()
        contactViewController.delegate = context.coordinator
        contactViewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: context.coordinator,
            action: #selector(Coordinator.cancel)
        )

        return UINavigationController(rootViewController: contactViewController)
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, @preconcurrency CNContactViewControllerDelegate {
        private let dismiss: DismissAction

        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }

        @objc func cancel() {
            dismiss()
        }

        func contactViewController(_ viewController: CNContactViewController, didCompleteWith contact: CNContact?) {
            dismiss()
        }
    }
}
