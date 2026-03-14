//
//  PurchaseManager.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 14/03/2026.
//

import StoreKit

/// Manages the annual subscription via StoreKit 2.
///
/// Inject into the view hierarchy via `.environment(purchaseManager)` and
/// read `isUnlocked` to gate features. Call `load()` once on app launch.
@Observable
@MainActor
final class PurchaseManager {

    static let productID = "com.astrophotoapp.FitsBlaster.pro.annual"

    /// `true` when the user holds an active subscription entitlement.
    private(set) var isUnlocked: Bool = false

    /// The subscription product fetched from the App Store.
    private(set) var product: Product? = nil

    /// `true` while a purchase or restore is in progress.
    private(set) var isPurchasing: Bool = false

    /// Non-nil when the last purchase or restore attempt failed.
    private(set) var errorMessage: String? = nil

    private var transactionListener: Task<Void, Never>? = nil


    // MARK: - Public API

    /// Loads the product and checks the current entitlement.
    /// Call once from `FitsBlasterApp` using `.task { await purchaseManager.load() }`.
    func load() async {
        listenForTransactions()
        await fetchProduct()
        await checkEntitlement()
    }

    /// Initiates the App Store purchase flow for the annual subscription.
    func purchase() async {
        guard let product else {
            errorMessage = "Product unavailable. Please try again later."
            return
        }
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try checkVerified(verification)
                await transaction.finish()
                await checkEntitlement()
            case .userCancelled:
                break
            case .pending:
                break
            @unknown default:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Restores completed transactions (required by App Store Review guidelines).
    func restorePurchases() async {
        isPurchasing = true
        errorMessage = nil
        defer { isPurchasing = false }

        do {
            try await AppStore.sync()
            await checkEntitlement()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Private

    private func fetchProduct() async {
        do {
            let products = try await Product.products(for: [Self.productID])
            product = products.first
        } catch {
            // Non-fatal — product info unavailable (e.g. no network). Entitlement check
            // still runs independently via Transaction.currentEntitlement.
        }
    }

    private func checkEntitlement() async {
        var entitled = false
        for await result in Transaction.currentEntitlements(for: Self.productID) {
            if let transaction = try? checkVerified(result) {
                entitled = transaction.revocationDate == nil
                break
            }
        }
        isUnlocked = entitled
    }

    private func listenForTransactions() {
        transactionListener?.cancel()
        transactionListener = Task(priority: .background) { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }
                if let transaction = try? self.checkVerified(result) {
                    await transaction.finish()
                }
                await self.checkEntitlement()
            }
        }
    }

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error):
            throw error
        case .verified(let value):
            return value
        }
    }
}
