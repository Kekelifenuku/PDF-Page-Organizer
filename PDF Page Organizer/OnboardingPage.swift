//
//  OnboardingPage.swift
//  PDF Page Organizer
//
//  Created by Fenuku kekeli on 2/3/26.
//


import SwiftUI

// MARK: - Onboarding Models

struct OnboardingPage: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let description: String
    let color: Color
}

// MARK: - Onboarding View

struct OnboardingView: View {
    @AppStorage("hasSeenOnboarding") private var hasSeenOnboarding = false
    @Environment(\.dismiss) var dismiss
    @State private var currentPage = 0
    
    let pages = [
        OnboardingPage(
            icon: "doc.on.doc.fill",
            title: "Merge PDFs",
            description: "Combine multiple PDF documents into a single organized file with just a few taps",
            color: .indigo
        ),
        OnboardingPage(
            icon: "hand.tap.fill",
            title: "Select & Organize",
            description: "Tap to select pages and use drag & drop to arrange them in any order you want",
            color: .blue
        ),
        OnboardingPage(
            icon: "arrow.up.arrow.down.circle.fill",
            title: "Reorder Pages",
            description: "Drag pages up and down to rearrange them. See changes in real-time as you organize",
            color: .purple
        ),
        OnboardingPage(
            icon: "trash.fill",
            title: "Remove Unwanted",
            description: "Select multiple pages and delete them at once, or remove individual pages instantly",
            color: .red
        ),
        OnboardingPage(
            icon: "square.and.arrow.up.fill",
            title: "Export & Share",
            description: "Save your organized PDF with a custom name and share it anywhere you need",
            color: .green
        )
    ]
    
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                colors: [
                    pages[currentPage].color.opacity(0.1),
                    Color(.systemBackground)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            
            VStack(spacing: 0) {
                // Skip button
                HStack {
                    Spacer()
                    Button {
                        completeOnboarding()
                    } label: {
                        Text("Skip")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }
                    .padding(.trailing, 20)
                    .padding(.top, 16)
                }
                
                // Content
                TabView(selection: $currentPage) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { index, page in
                        OnboardingPageView(page: page)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut, value: currentPage)
                
                // Page indicators and button
                VStack(spacing: 24) {
                    // Custom page indicators
                    HStack(spacing: 8) {
                        ForEach(0..<pages.count, id: \.self) { index in
                            Capsule()
                                .fill(currentPage == index ? pages[currentPage].color : Color.gray.opacity(0.3))
                                .frame(width: currentPage == index ? 24 : 8, height: 8)
                                .animation(.spring(response: 0.3), value: currentPage)
                        }
                    }
                    
                    // Action button
                    Button {
                        if currentPage < pages.count - 1 {
                            withAnimation(.spring(response: 0.3)) {
                                currentPage += 1
                            }
                        } else {
                            completeOnboarding()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(currentPage == pages.count - 1 ? "Get Started" : "Next")
                                .fontWeight(.semibold)
                            
                            if currentPage < pages.count - 1 {
                                Image(systemName: "arrow.right")
                                    .font(.subheadline)
                            }
                        }
                        .font(.body)
                        .foregroundColor(.white)
                        .frame(maxWidth: 320)
                        .padding(.vertical, 16)
                        .background(
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [pages[currentPage].color, pages[currentPage].color.opacity(0.8)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .shadow(color: pages[currentPage].color.opacity(0.4), radius: 12, x: 0, y: 6)
                        )
                    }
                    .animation(.spring(response: 0.3), value: currentPage)
                }
                .padding(.bottom, 40)
                .padding(.horizontal, 20)
            }
        }
    }
    
    private func completeOnboarding() {
        hasSeenOnboarding = true
        dismiss()
    }
}

// MARK: - Onboarding Page View

struct OnboardingPageView: View {
    let page: OnboardingPage
    @State private var isAnimating = false
    
    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            
            // Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [page.color.opacity(0.2), page.color.opacity(0.05)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 140, height: 140)
                    .scaleEffect(isAnimating ? 1.0 : 0.8)
                    .opacity(isAnimating ? 1.0 : 0.0)
                
                Image(systemName: page.icon)
                    .font(.system(size: 64))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [page.color, page.color.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .symbolRenderingMode(.hierarchical)
                    .scaleEffect(isAnimating ? 1.0 : 0.5)
                    .opacity(isAnimating ? 1.0 : 0.0)
            }
            .padding(.bottom, 32)
            
            // Title
            Text(page.title)
                .font(.system(.largeTitle, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(.primary)
                .multilineTextAlignment(.center)
                .padding(.bottom, 12)
                .opacity(isAnimating ? 1.0 : 0.0)
                .offset(y: isAnimating ? 0 : 20)
            
            // Description
            Text(page.description)
                .font(.system(.body, design: .rounded))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.horizontal, 40)
                .opacity(isAnimating ? 1.0 : 0.0)
                .offset(y: isAnimating ? 0 : 20)
            
            Spacer()
            Spacer()
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(0.1)) {
                isAnimating = true
            }
        }
    }
}


