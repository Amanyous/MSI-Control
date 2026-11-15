@main
enum NavigationHistoryChecks {
    static func main() {
        var navigation = NavigationHistory(initial: "dashboard")
        precondition(!navigation.canGoBack && !navigation.canGoForward)
        navigation.goBack()
        navigation.goForward()
        precondition(navigation.current == "dashboard")
        navigation.visit("fan")
        navigation.visit("settings")
        navigation.goBack()
        precondition(navigation.current == "fan" && navigation.canGoForward)
        navigation.visit("fan")
        precondition(navigation.history.count == 3 && navigation.canGoForward)
        navigation.goForward()
        precondition(navigation.current == "settings" && !navigation.canGoForward)
        navigation.goBack()
        navigation.visit("battery")
        precondition(navigation.history == ["dashboard", "fan", "battery"])
        precondition(!navigation.canGoForward)
        navigation.goBack()
        navigation.goBack()
        precondition(navigation.current == "dashboard" && !navigation.canGoBack)
        print("Navigation history checks passed")
    }
}
