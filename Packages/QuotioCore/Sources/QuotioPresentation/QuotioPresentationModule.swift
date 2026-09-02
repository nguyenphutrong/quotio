import QuotioApplication
import QuotioDomain

public enum QuotioPresentationModule {
    public static let name = "QuotioPresentation"
    public static let dependencyNames = [
        QuotioApplicationModule.name,
        QuotioDomainModule.name,
    ]
}
