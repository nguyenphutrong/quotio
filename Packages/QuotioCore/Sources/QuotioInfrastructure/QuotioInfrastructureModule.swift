import QuotioApplication
import QuotioDomain

public enum QuotioInfrastructureModule {
    public static let name = "QuotioInfrastructure"
    public static let dependencyNames = [
        QuotioApplicationModule.name,
        QuotioDomainModule.name,
    ]
}
