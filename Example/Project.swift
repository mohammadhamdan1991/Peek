import ProjectDescription

let project = Project(
    name: "PeekExample",
    targets: [
        .target(
            name: "PeekExample",
            destinations: .iOS,
            product: .app,
            bundleId: "dev.peek.example",
            deploymentTargets: .iOS("16.6"),
            infoPlist: .extendingDefault(with: ["UILaunchScreen": [:]]),
            sources: ["Sources/**"],
            dependencies: [.external(name: "Peek")]
        ),
    ]
)
