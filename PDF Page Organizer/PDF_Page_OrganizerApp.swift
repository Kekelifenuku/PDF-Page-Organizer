//
//  PDF_Page_OrganizerApp.swift
//  PDF Page Organizer
//
//  Created by Fenuku kekeli on 2/3/26.
//

import SwiftUI

@main
struct PDF_Page_OrganizerApp: App {

    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @State private var showOnboarding = false

    var body: some Scene {
        WindowGroup {
            PDFMergerOrganizerView()
                .fullScreenCover(isPresented: $showOnboarding) {
                    OnboardingView()
                }
                .onAppear {
                    if !hasSeenOnboarding {
                        // Small delay for smoother UX
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            showOnboarding = true
                        }
                    }
                }
        }
    }
}
