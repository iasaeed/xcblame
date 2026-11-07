import ProjectDescription

let project = Project(
    name: "AcmeTuist",
    targets: [
        .target(
            name: "AcmeTuist",
            destinations: .iOS,
            product: .app,
            bundleId: "com.example.acme.acmetuist",
            deploymentTargets: .iOS("17.0"),
            infoPlist: .default,
            sources: ["AcmeTuist/**"]
        ),
    ]
)
