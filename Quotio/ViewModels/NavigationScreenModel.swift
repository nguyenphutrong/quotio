import Observation

@MainActor
@Observable
final class NavigationScreenModel {
    var currentPage: NavigationPage = .dashboard
}
