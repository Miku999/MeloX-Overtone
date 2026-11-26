import SwiftUI
import UIKit

struct TabBarTapObserver: UIViewRepresentable {
    let visibleTabs: [AppTab]
    let selectedTab: AppTab
    let onReselect: (AppTab) -> Void

    func makeUIView(context: Context) -> TabBarTapObserverView {
        let view = TabBarTapObserverView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: TabBarTapObserverView, context: Context) {
        uiView.configure(
            visibleTabs: visibleTabs,
            selectedTab: selectedTab,
            onReselect: onReselect
        )
    }
}

final class TabBarTapObserverView: UIView, UIGestureRecognizerDelegate {
    private weak var observedTabBar: UITabBar?
    private var observedCandidateControls: [UIControl] = []
    private var observedLogicalIndices: [Int] = []
    private var tabBarTapGestureRecognizer: UITapGestureRecognizer?
    private var visibleTabs: [AppTab] = []
    private var selectedTab: AppTab = .home
    private var onReselect: ((AppTab) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.attachIfNeeded()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        attachIfNeeded()
    }

    func configure(
        visibleTabs: [AppTab],
        selectedTab: AppTab,
        onReselect: @escaping (AppTab) -> Void
    ) {
        self.visibleTabs = visibleTabs
        self.selectedTab = selectedTab
        self.onReselect = onReselect

        DispatchQueue.main.async { [weak self] in
            self?.attachIfNeeded()
        }
    }

    private func attachIfNeeded() {
        guard let tabBar = findTabBar() else { return }
        if observedTabBar !== tabBar {
            unbindTabBarCandidates()
            removeTabBarTapGesture()
            observedTabBar = tabBar
        }
        bindTabBarCandidatesIfNeeded()
        installTabBarTapGestureIfNeeded()
    }

    private func bindTabBarCandidatesIfNeeded() {
        guard let tabBar = observedTabBar else { return }
        let directSubviews = tabBar.subviews
            .filter { $0.bounds.width > 0 && !$0.isHidden }
            .sorted { $0.frame.minX < $1.frame.minX }

        let candidates = directSubviews.filter { view in
            let className = NSStringFromClass(type(of: view)).lowercased()
            return className.contains("tab") || className.contains("button") || className.contains("item")
        }

        let platterCandidates = platterCandidateViews(from: directSubviews)
        let resolvedCandidates: [UIView]
        if !platterCandidates.isEmpty {
            resolvedCandidates = platterCandidates
        } else if !candidates.isEmpty {
            resolvedCandidates = candidates
        } else {
            resolvedCandidates = directSubviews
        }
        let resolvedControls = resolvedCandidates.compactMap { $0 as? UIControl }
        guard !resolvedControls.isEmpty else { return }
        guard resolvedControls.map(ObjectIdentifier.init) != observedCandidateControls.map(ObjectIdentifier.init) else { return }

        let logicalIndices = logicalTabIndices(for: resolvedControls)

        unbindTabBarCandidates()
        observedCandidateControls = resolvedControls
        observedLogicalIndices = logicalIndices
    }

    private func platterCandidateViews(from directSubviews: [UIView]) -> [UIView] {
        guard let platterView = directSubviews.first(where: {
            NSStringFromClass(type(of: $0)).lowercased().contains("platter")
        }) else {
            return []
        }

        let levelOne = platterView.subviews
            .filter { $0.bounds.width > 0 && !$0.isHidden }
            .sorted { $0.frame.minX < $1.frame.minX }

        let contentLikeLevelOne = levelOne.filter { view in
            let className = NSStringFromClass(type(of: view)).lowercased()
            return className.contains("contentview")
        }

        let levelTwoParents = contentLikeLevelOne.isEmpty ? levelOne : contentLikeLevelOne
        let levelTwo = levelTwoParents
            .flatMap(visibleSubviews(of:))
            .sorted { lhs, rhs in
                if lhs.frame.minY == rhs.frame.minY {
                    return lhs.frame.minX < rhs.frame.minX
                }
                return lhs.frame.minY < rhs.frame.minY
            }

        let itemLikeLevelTwo = candidateItemViews(from: levelTwo, containerWidth: platterView.bounds.width)
        if itemLikeLevelTwo.count >= visibleTabs.count {
            return itemLikeLevelTwo
        }

        let levelThree = levelTwo
            .flatMap(visibleSubviews(of:))
            .sorted { lhs, rhs in
                if lhs.frame.minY == rhs.frame.minY {
                    return lhs.frame.minX < rhs.frame.minX
                }
                return lhs.frame.minY < rhs.frame.minY
            }

        let itemLikeLevelThree = candidateItemViews(from: levelThree, containerWidth: platterView.bounds.width)
        if itemLikeLevelThree.count >= visibleTabs.count {
            return itemLikeLevelThree
        }

        return levelTwo
    }

    private func visibleSubviews(of view: UIView) -> [UIView] {
        view.subviews.filter { $0.bounds.width > 0 && !$0.isHidden }
    }

    private func candidateItemViews(from views: [UIView], containerWidth: CGFloat) -> [UIView] {
        views.filter { view in
            let className = NSStringFromClass(type(of: view)).lowercased()
            let width = view.bounds.width
            let looksLikeItemClass =
                className.contains("item") ||
                className.contains("button") ||
                className.contains("label") ||
                className.contains("icon")
            let looksLikeSegment =
                width > 24 &&
                width < containerWidth * 0.6 &&
                view.bounds.height > 20
            return looksLikeItemClass || looksLikeSegment
        }
    }

    private func logicalTabIndices(for controls: [UIControl]) -> [Int] {
        var logicalCenters: [CGFloat] = []
        let tolerance: CGFloat = 2

        return controls.map { control in
            let centerX = control.frame.midX
            if let existingIndex = logicalCenters.firstIndex(where: { abs($0 - centerX) <= tolerance }) {
                return existingIndex
            }
            logicalCenters.append(centerX)
            logicalCenters.sort()
            return logicalCenters.firstIndex(where: { abs($0 - centerX) <= tolerance }) ?? 0
        }
    }

    private func unbindTabBarCandidates() {
        observedCandidateControls.removeAll()
        observedLogicalIndices.removeAll()
    }

    private func installTabBarTapGestureIfNeeded() {
        guard let tabBar = observedTabBar else { return }
        guard tabBarTapGestureRecognizer?.view !== tabBar else { return }

        removeTabBarTapGesture()

        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTabBarTap(_:)))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        tabBar.addGestureRecognizer(recognizer)
        tabBarTapGestureRecognizer = recognizer
    }

    private func removeTabBarTapGesture() {
        if let recognizer = tabBarTapGestureRecognizer {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }
        tabBarTapGestureRecognizer = nil
    }

    private func frameForLogicalTabIndex(_ logicalIndex: Int) -> CGRect? {
        let frames = zip(observedCandidateControls, observedLogicalIndices)
            .filter { _, index in index == logicalIndex }
            .map(\.0.frame)

        guard !frames.isEmpty else {
            return nil
        }

        let bestFrame = frames.min { lhs, rhs in
            if lhs.width == rhs.width {
                return lhs.minX < rhs.minX
            }
            return lhs.width < rhs.width
        }
        return bestFrame
    }

    @objc
    private func handleTabBarTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        guard selectedTab == .search else { return }
        guard let searchIndex = visibleTabs.firstIndex(of: .search) else { return }
        guard let searchFrame = frameForLogicalTabIndex(searchIndex) else { return }

        let location = recognizer.location(in: observedTabBar)
        guard searchFrame.contains(location) else { return }

        DispatchQueue.main.async { [weak self] in
            self?.onReselect?(.search)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        true
    }

    private func findTabBar() -> UITabBar? {
        guard let rootViewController = window?.rootViewController else { return nil }
        return findTabBar(in: rootViewController)
    }

    private func findTabBar(in viewController: UIViewController) -> UITabBar? {
        if let tabBarController = viewController as? UITabBarController {
            return tabBarController.tabBar
        }

        for child in viewController.children {
            if let tabBar = findTabBar(in: child) {
                return tabBar
            }
        }

        if let presentedViewController = viewController.presentedViewController {
            return findTabBar(in: presentedViewController)
        }

        return nil
    }
}
