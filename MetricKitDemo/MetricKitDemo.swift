//
//  MyAppMetricKitDemo.swift
//  MetricKitDemo
//
//  Created by Itsuki on 2026/08/16.
//

import SwiftUI
import MetricKit

@main
struct MetricKitDemo: App {
    private let manager = AppPerformanceManager()
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(manager)
                .task {
                    // measure launch tasks
                    await manager.trackLaunchTask({
                        try? await Task.sleep(for: .milliseconds(100))
                    }, taskId: "launch-sleep")
                }
        }
    }
}
