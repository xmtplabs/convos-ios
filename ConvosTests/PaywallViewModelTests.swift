import Combine
@testable import Convos
import ConvosCore
import XCTest

@MainActor
final class PaywallViewModelTests: XCTestCase {
    // MARK: - loadProducts re-entrancy guard

    func testLoadProducts_concurrentCalls_onlyFetchOnce_bothCallersSeeProducts() async {
        let service: SlowAvailableProductsService = SlowAvailableProductsService(
            sleepNanoseconds: 50_000_000  // 50ms — long enough for both calls to overlap
        )
        let viewModel: PaywallViewModel = PaywallViewModel(subscriptionService: service)

        async let first: Void = viewModel.loadProducts()
        async let second: Void = viewModel.loadProducts()
        _ = await (first, second)

        XCTAssertEqual(
            service.availableProductsCallCount,
            1,
            "Concurrent loadProducts calls must share the same fetch — actors are re-entrant at await suspension points"
        )
        // Both callers must observe the loaded products on return — the bug
        // we're guarding against is the second caller silently bailing
        // out while the first fetch is in flight, leaving its view to
        // render without products.
        XCTAssertFalse(
            viewModel.products.isEmpty,
            "Both concurrent callers must see populated products when they return"
        )
    }

    func testLoadProducts_secondCallAfterSuccess_isNoOp() async {
        let service: SlowAvailableProductsService = SlowAvailableProductsService(sleepNanoseconds: 0)
        let viewModel: PaywallViewModel = PaywallViewModel(subscriptionService: service)

        await viewModel.loadProducts()
        XCTAssertEqual(service.availableProductsCallCount, 1)

        await viewModel.loadProducts()
        XCTAssertEqual(
            service.availableProductsCallCount,
            1,
            "loadProducts must early-out when products are already loaded"
        )
    }

    // MARK: - purchase error alert mapping

    func testPurchase_pending_showsAwaitingApprovalAlert() async {
        let service: StubSubscriptionService = StubSubscriptionService(
            purchaseResult: .failure(SubscriptionServiceError.purchasePending)
        )
        let viewModel: PaywallViewModel = PaywallViewModel(subscriptionService: service)
        let product: PaywallProduct = .builderMonthlyTestProduct

        await viewModel.purchase(product: product)

        XCTAssertTrue(viewModel.isShowingAlert)
        XCTAssertEqual(viewModel.alertTitle, "Awaiting approval")
    }

    func testPurchase_unverified_showsCouldntVerifyAlert() async {
        let service: StubSubscriptionService = StubSubscriptionService(
            purchaseResult: .failure(SubscriptionServiceError.purchaseUnverified)
        )
        let viewModel: PaywallViewModel = PaywallViewModel(subscriptionService: service)

        await viewModel.purchase(product: .builderMonthlyTestProduct)

        XCTAssertTrue(viewModel.isShowingAlert)
        XCTAssertEqual(viewModel.alertTitle, "Couldn't verify purchase")
    }

    func testPurchase_cancelled_doesNotShowAlert() async {
        let service: StubSubscriptionService = StubSubscriptionService(
            purchaseResult: .failure(SubscriptionServiceError.purchaseCancelled)
        )
        let viewModel: PaywallViewModel = PaywallViewModel(subscriptionService: service)

        await viewModel.purchase(product: .builderMonthlyTestProduct)

        XCTAssertFalse(viewModel.isShowingAlert, "User-cancelled purchases must be silent")
    }

    func testPurchase_genericFailure_showsSomethingWentWrong() async {
        let service: StubSubscriptionService = StubSubscriptionService(
            purchaseResult: .failure(SubscriptionServiceError.purchaseFailed(reason: "boom"))
        )
        let viewModel: PaywallViewModel = PaywallViewModel(subscriptionService: service)

        await viewModel.purchase(product: .builderMonthlyTestProduct)

        XCTAssertTrue(viewModel.isShowingAlert)
        XCTAssertEqual(viewModel.alertTitle, "Something went wrong")
    }

    func testPurchase_success_callsOnPurchaseSucceededOnce() async {
        let service: StubSubscriptionService = StubSubscriptionService(purchaseResult: .success(()))
        let viewModel: PaywallViewModel = PaywallViewModel(subscriptionService: service)
        var callbackCount: Int = 0
        viewModel.onPurchaseSucceeded = { callbackCount += 1 }

        await viewModel.purchase(product: .builderMonthlyTestProduct)

        XCTAssertEqual(callbackCount, 1)
        XCTAssertFalse(viewModel.isShowingAlert, "Success path must not show an error alert")
    }
}

// MARK: - Fakes

private final class SlowAvailableProductsService: SubscriptionServiceProtocol, @unchecked Sendable {
    private let sleepNanoseconds: UInt64
    private let countQueue: DispatchQueue = DispatchQueue(label: "SlowAvailableProductsService.count")
    private var _availableProductsCallCount: Int = 0

    var availableProductsCallCount: Int {
        countQueue.sync { _availableProductsCallCount }
    }

    init(sleepNanoseconds: UInt64) {
        self.sleepNanoseconds = sleepNanoseconds
    }

    var subscriptionPublisher: AnyPublisher<UserSubscription?, Never> {
        Just<UserSubscription?>(nil).eraseToAnyPublisher()
    }
    var currentSubscription: UserSubscription? { nil }

    func availableProducts() async throws -> [PaywallProduct] {
        countQueue.sync { _availableProductsCallCount += 1 }
        if sleepNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: sleepNanoseconds)
        }
        return [.builderMonthlyTestProduct]
    }

    func purchase(productId: String) async throws {}
    func restorePurchases() async throws {}
    func refresh(force: Bool) async {}
}

private final class StubSubscriptionService: SubscriptionServiceProtocol, @unchecked Sendable {
    private let purchaseResult: Result<Void, Error>

    init(purchaseResult: Result<Void, Error>) {
        self.purchaseResult = purchaseResult
    }

    var subscriptionPublisher: AnyPublisher<UserSubscription?, Never> {
        Just<UserSubscription?>(nil).eraseToAnyPublisher()
    }
    var currentSubscription: UserSubscription? { nil }

    func availableProducts() async throws -> [PaywallProduct] { [] }

    func purchase(productId: String) async throws {
        switch purchaseResult {
        case .success: return
        case .failure(let error): throw error
        }
    }

    func restorePurchases() async throws {}
    func refresh(force: Bool) async {}
}

private extension PaywallProduct {
    static let builderMonthlyTestProduct: PaywallProduct = PaywallProduct(
        id: SubscriptionProductIDs.builderMonthly,
        tier: .builder,
        period: .monthly,
        displayPrice: "$19.99",
        pricePerMonthDisplay: nil,
        currencyCode: "USD"
    )
}
