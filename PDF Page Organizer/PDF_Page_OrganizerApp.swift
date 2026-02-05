//
//  PDF_Page_OrganizerApp.swift
//  PDF Page Organizer
//
//  Created by Fenuku kekeli on 2/3/26.
//

import SwiftUI
import Network
import StoreKit
import RevenueCat
import RevenueCatUI
import Combine
// ---------------------------------------------------------
// MARK: - APP ENTRY
// ---------------------------------------------------------
@main
struct PDF_Page_OrganizerApp: App {

    @StateObject private var subscriptionManager = SubscriptionManager()
    @StateObject private var networkMonitor = NetworkMonitor()

    @AppStorage("hasCompletedOnboarding")
    private var hasCompletedOnboarding: Bool = false

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(subscriptionManager)
                .environmentObject(networkMonitor)
                .fullScreenCover(
                    isPresented: .constant(!hasCompletedOnboarding)
                ) {
                    OnboardingView()
                }
        }
    }
}

//
// ---------------------------------------------------------
// MARK: - ROOT VIEW
// ---------------------------------------------------------
struct RootView: View {

    @EnvironmentObject var subscriptionManager: SubscriptionManager
    @EnvironmentObject var networkMonitor: NetworkMonitor

    @State private var isLoading = true

    var body: some View {
        Group {
            if !networkMonitor.isConnected {
                NoConnectionView()
            } else if isLoading {
                ProgressView()
                    .scaleEffect(1.4)
            } else {
                PDFMergerOrganizerView()
            }
        }
        .onAppear {
            checkSubscription()
        }
    }

    private func checkSubscription() {
        isLoading = true

        subscriptionManager.checkSubscriptionStatus { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                isLoading = false
            }
        }

        // Failsafe timeout (prevents infinite loader)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            isLoading = false
        }
    }
}

//
// ---------------------------------------------------------
// MARK: - NO CONNECTION VIEW
// ---------------------------------------------------------
struct NoConnectionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("🔌 No Internet Connection")
                .font(.title2)
                .bold()

            Text("Internet is required to sync your subscription status.")
                .multilineTextAlignment(.center)
                .padding()

            ProgressView("Waiting for connection…")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
    }
}

//
// ---------------------------------------------------------
// MARK: - REVIEW REQUEST MANAGER
// ---------------------------------------------------------
final class ReviewRequestManager {

    @AppStorage("hasCompletedOnboarding")
    private var hasCompletedOnboarding = false

    @AppStorage("hasRequestedReview")
    private var hasRequestedReview = false

    func askForReviewIfNeeded() {
        guard hasCompletedOnboarding, !hasRequestedReview else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if let scene = UIApplication.shared.connectedScenes
                .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene {

                SKStoreReviewController.requestReview(in: scene)
                self.hasRequestedReview = true
            }
        }
    }
}

//
// ---------------------------------------------------------
// MARK: - NETWORK MONITOR
// ---------------------------------------------------------
final class NetworkMonitor: ObservableObject {

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")

    @Published var isConnected: Bool = true

    init() {
        monitor.pathUpdateHandler = { path in
            DispatchQueue.main.async {
                self.isConnected = (path.status == .satisfied)
            }
        }
        monitor.start(queue: queue)
    }
}

//
// ---------------------------------------------------------
// MARK: - SUBSCRIPTION MANAGER (RevenueCat)
// ---------------------------------------------------------
final class SubscriptionManager: NSObject, ObservableObject {

    @Published var isSubscribed: Bool = false

    private let entitlementID = "pro"

    override init() {
        super.init()

        Purchases.configure(withAPIKey: "appl_dCZzisIHyiFbLzGdLhrRsAiweUP")
        Purchases.shared.delegate = self

        checkSubscriptionStatus()
    }

    func checkSubscriptionStatus(completion: ((Bool) -> Void)? = nil) {
        Purchases.shared.getCustomerInfo { [weak self] info, error in
            DispatchQueue.main.async {
                if let error = error {
                    print("❌ RevenueCat error:", error.localizedDescription)
                    completion?(false)
                    return
                }

                let active =
                info?.entitlements[self?.entitlementID ?? ""]?.isActive ?? false

                self?.isSubscribed = active
                completion?(active)
            }
        }
    }
}

//
// ---------------------------------------------------------
// MARK: - RevenueCat Delegate
// ---------------------------------------------------------
extension SubscriptionManager: PurchasesDelegate {
    func purchases(
        _ purchases: Purchases,
        receivedUpdated customerInfo: CustomerInfo
    ) {
        DispatchQueue.main.async {
            self.isSubscribed =
                customerInfo.entitlements[self.entitlementID]?.isActive == true
        }
    }
}
