//
//  PaywallView.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 14/03/2026.
//

import StoreKit
import SwiftUI

/// Presented as a sheet when the free-tier 50-frame limit is reached.
struct PaywallView: View {
    @Environment(PurchaseManager.self) private var purchases
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.yellow)

                Text("Upgrade to FITS Blaster Pro")
                    .font(.title2)
                    .bold()

                Text("You've reached the 50-frame limit for the free tier.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.horizontal, 32)
            .padding(.bottom, 24)

            Divider()

            // Feature list
            VStack(alignment: .leading, spacing: 10) {
                FeatureRow(icon: "infinity", text: "Unlimited frames per session")
                FeatureRow(icon: "chart.bar.fill", text: "Full metrics: FWHM, eccentricity, SNR, star count")
                FeatureRow(icon: "rectangle.3.group.fill", text: "Session chart with drag-to-reject")
                FeatureRow(icon: "checkmark.seal.fill", text: "Auto-reject with configurable thresholds")
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)

            Divider()

            // Price and actions
            VStack(spacing: 12) {
                if let product = purchases.product {
                    Text(product.displayPrice + " / year")
                        .font(.headline)
                } else {
                    Text("Loading…")
                        .foregroundStyle(.secondary)
                }

                Button {
                    Task { await purchases.purchase() }
                } label: {
                    Group {
                        if purchases.isPurchasing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Subscribe")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(purchases.product == nil || purchases.isPurchasing)
                .controlSize(.large)

                Button("Restore Purchases") {
                    Task { await purchases.restorePurchases() }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(purchases.isPurchasing)

                Button("Not Now") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)

            if let error = purchases.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .scaledFont(size: 11)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                    .padding(.bottom, 12)
            }
        }
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: purchases.isUnlocked) { _, unlocked in
            if unlocked { dismiss() }
        }
    }
}

private struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.yellow)
                .frame(width: 20)
            Text(text)
        }
    }
}
