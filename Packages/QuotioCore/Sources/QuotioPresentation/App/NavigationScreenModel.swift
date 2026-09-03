import Observation

@MainActor
@Observable
public final class NavigationScreenModel {
    public var currentPage: NavigationPage = .dashboard

    public init() {}
}
