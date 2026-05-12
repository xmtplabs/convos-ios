import Combine
import Foundation

public protocol CreditsServiceProtocol: AnyObject, Sendable {
    var balancePublisher: AnyPublisher<CreditBalance?, Never> { get }
    var currentBalance: CreditBalance? { get }

    func refresh() async
}
