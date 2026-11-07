import PackagePlugin

@main
struct AcmeGen: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] { [] }
}
