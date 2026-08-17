//
//  MyAppMetricKitDemo.swift
//  ContentView
//
//  Created by Itsuki on 2026/08/16.
//

import MetricKit
import StateReporting
import SwiftUI

struct ContentView: View {
    @Environment(AppPerformanceManager.self) private var manager
    var body: some View {
        VStack {
            Button("record navigation to detail") {
                manager.reportUserNavigation(.detail)
            }

            Button("record navigation to settings") {
                manager.reportUserNavigation(.settings)
            }

            Button("Measure dummy networking") {
                Task {
                    do {
                        try await manager.fetchWithMetrics(
                            {
                                try await Task.sleep(for: .milliseconds(500))
                            },
                            operationName: "fetch-sleep"
                        )
                    } catch {
                        print(error)
                    }
                }
            }
        }
    }
}
