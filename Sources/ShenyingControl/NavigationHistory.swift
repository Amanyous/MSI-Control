struct NavigationHistory<Destination: Equatable> {
    private(set) var history: [Destination]
    private(set) var currentIndex = 0

    init(initial: Destination) {
        history = [initial]
    }

    var current: Destination { history[currentIndex] }
    var canGoBack: Bool { currentIndex > 0 }
    var canGoForward: Bool { currentIndex < history.count - 1 }

    mutating func visit(_ destination: Destination) {
        guard destination != current else { return }
        history = Array(history.prefix(currentIndex + 1))
        history.append(destination)
        currentIndex += 1
    }

    mutating func goBack() {
        guard canGoBack else { return }
        currentIndex -= 1
    }

    mutating func goForward() {
        guard canGoForward else { return }
        currentIndex += 1
    }
}
