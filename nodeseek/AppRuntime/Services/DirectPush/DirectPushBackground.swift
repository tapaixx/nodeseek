import BackgroundTasks

@MainActor
enum DirectPushBackground {
    static let identifier = "com.mistj.nodeseek.direct-push-refresh"
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
            Task { @MainActor in
                schedule()
                let work = Task {
                    await AppMessageCenter.shared.refresh()
                    if !Task.isCancelled { await DirectPushMonitor.shared.check() }
                }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: !work.isCancelled)
            }
        }
    }
    static func schedule() {
        guard AppMessageCenter.shared.alertsEnabled || DirectPushChannel.allCases.contains(where: { DirectPushStore.shared.configuration($0)?.enabled == true }) else { return }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
