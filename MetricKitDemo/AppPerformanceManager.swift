//
//  AppPerformanceManager.swift
//  MetricKitDemo
//
//  Created by Itsuki on 2026/08/18.
//

import MetricKit
import StateReporting
import SwiftUI

// Stable metadata: provides the context for categorization.
// to exclude a property, use the ReportableMetadataIgnored() macro
@ReportableMetadata
struct UserNavigationMetadata {
    static let domain: StateReportingDomain =
        "itsuki.enjoy.MetricKitDemo.UserInteractionMetadata"

    let screen: Screen.RawValue
    @ReportableMetadataKey("timestamptz") let date: Date = Date()

    enum Screen: String {
        case detail
        case settings
    }
}

// Use volatile metadata to annotate the active state with data that changes within it, without triggering a transition.
// NOTE: MetricKit only surfaces stable metadata.
// volatileMetadata is available to other diagnostic tools such as Instruments, but is not visible to MetricKit.
@ReportableMetadata
struct UserInteractionVolatileMetadata {
    let interaction: InteractionType

    enum InteractionType: String {
        case textEntry
        case confirmButton
        case cancelButton
    }
}

@Observable
class AppPerformanceManager {

    private let metricManager: MetricManager

    @ObservationIgnored
    private var metricReportTask: Task<Void, Error>?

    @ObservationIgnored
    private var diagnosticReportTask: Task<Void, Error>?

    init() {
        let metricsManager = MetricManager(enabledStateReportingDomains: [
            UserNavigationMetadata.domain
        ])
        self.metricManager = metricsManager
        self.startGettingReports()
    }

    // MARK: - Handle Reports
    private func startGettingReports() {
        self.metricReportTask = Task {
            // A daily performance report that contains metric values for the app.
            // Each report provides two complementary views of your performance data:
            // - stateEntries with metrics segmented by app state, and
            // - intervalEntries with metrics aggregated over time windows
            //
            // To generate reports during development without waiting for the daily delivery schedule,
            // choose Debug > Simulate MetricKit Payloads in Xcode.
            for await report in metricManager.metricReports {
                self.handleReport(report)
            }
        }

        self.diagnosticReportTask = Task {
            // reports for a single occurrence of a crash, hang, or exception
            for await report in metricManager.diagnosticReports {
                self.handleDiagnostic(report)
            }
        }
    }

    // MARK: - StateReporting
    // tracking states of a specific domain
    //
    // NOTE:
    // StateReporting applies a rate limit.
    // Call reportTransition(to:stableMetadata:volatileMetadata:) and reportVolatileMetadataUpdate(_:) at human-interaction timescales.
    // Calling them on every frame or in a tight loop causes StateReporting to drop data.

    private let userNavigationReporter = StateReporter.reporter(
        for: UserNavigationMetadata.domain.rawValue,
        // The type to use for stable metadata (defaults to Never).
        stableMetadata: UserNavigationMetadata.self,
        // The type to use for volatile metadata (defaults to Never).
        volatileMetadata: UserInteractionVolatileMetadata.self
    )

    func reportUserNavigation(_ destination: UserNavigationMetadata.Screen) {
        // NOTE:
        // A transition occurs only when stateLabel or stableMetadata changes from the current state.
        // If both are equal to the current values, this call is a no-op.
        userNavigationReporter.reportTransition(
            // to stateLabel must not be empty
            to: destination.rawValue,
            stableMetadata: UserNavigationMetadata(
                screen: destination.rawValue
            )
        )
    }

    // for example, when heading back to home screen
    func endNavigation() {
        userNavigationReporter.reportTransition(to: nil)
    }

    // Call reportVolatileMetadataUpdate(_:) to update volatile metadata without triggering a new transition. This call has no effect if no state is currently active.
    func userInteracted(
        _ interaction: UserInteractionVolatileMetadata.InteractionType
    ) {
        userNavigationReporter.reportVolatileMetadataUpdate(
            UserInteractionVolatileMetadata(interaction: interaction)
        )
    }

    // MARK: - Capture custom metrics with signposts
    // This can be used for measuring the duration of specific operations in the app,
    // such as network requests, database queries, image processing pipelines,
    // or any other work we want to track in production

    // An OSLog object tied to the MetricKit collection pipeline
    private let networkLog = MetricManager.logHandle(
        category: "NetworkRequests"
    )

    // alternative with OSSignposter
    // NOTE: will NOT populate the SignpostIntervalMetric measurement properties
    //
    // private let signposter = OSSignposter(
    //     logHandle: MetricManager.logHandle(
    //         category: "NetworkRequests"
    //     )
    // )

    func fetchWithMetrics(
        _ fetch: @escaping () async throws -> Void,
        operationName: StaticString
    ) async rethrows {
        // Surround each custom operation with the signpost wrapper mxSignpost(_:dso:log:name:signpostID:_:_:)
        // This enables the full `SignpostIntervalMetric` result under `MetricResult`
        // SignpostIntervalMetric also exposes optional resource-consumption properties populated automatically by MetricKit
        // — cpuTime, logicalWrites, averageMemory, hitchTimeRatio, totalHitchTime, and totalAnimationTime
        //
        // to tag an operation as an animation interval
        // and populate hitchTimeRatio, totalHitchTime, and totalAnimationTime,
        // use mxSignpostAnimationIntervalBegin(dso:log:name:signpostID:_:_:) instead
        mxSignpost(.begin, log: networkLog, name: operationName)
        try await fetch()
        mxSignpost(.end, log: networkLog, name: operationName)

        // alternative with OSSignposter
        //
        // let signpostID = signposter.makeSignpostID()
        // let state = signposter.beginInterval(operationName, id: signpostID)
        // try await fetch()
        // signposter.endInterval(operationName, state)
    }

    // MARK: - Launch Tracking
    // Wrap launch-critical asynchronous work in trackLaunchTask(id:onTrackingError:_:) to extend the MetricKit launch measurement to measure, for example, asynchronous work that forms part of the perceived launch experience, such as data bootstrapping, configuration fetching, or initial content loading
    // Standard launch metrics end at `applicationDidFinishLaunching`.

    func trackLaunchTask(
        _ task: @escaping () async throws -> Void,
        taskId: LaunchTaskID
    ) async rethrows {
        try await metricManager.trackLaunchTask(id: taskId, task)
    }
}

// MARK: - Sample Report Handling
// use this as a chance to save the report in CloudKit/File/Send to server
// `MetricReport` and `DiagnosticReport` conform to Codable,
// so we can encode them for upload to a backend database or archive them locally with ease
extension AppPerformanceManager {
    private func handleReport(_ report: MetricReport) {
        print("Received metric report")

        print("environment: \(report.environment, default: "Unknown")")
        print("\(report.timeRange.start) - \(report.timeRange.end)")

        func printState(_ state: MetricManager.ReportedState) {
            print(
                """
                State information:
                - domain: \(state.domain)
                - duration: \(state.duration)
                - label: \(state.label)
                - stableMetadata: \(state.stableMetadata)
                """
            )
        }

        func printMetricResults(_ results: [MetricResult]) {
            for value in results {
                switch value {
                case .hangTime(let hangTimeMetric):
                    print("Hang time:", hangTimeMetric)
                case .hitchTime(let hitchTimeMetric):
                    print("Hitch time:", hitchTimeMetric)
                case .foregroundTermination(let foregroundTerminationMetric):
                    print(
                        "Foreground termination:",
                        foregroundTerminationMetric.memoryLimitTerminationCount
                    )
                case .backgroundTermination(let backgroundTerminationMetric):
                    print(
                        "Background termination:",
                        backgroundTerminationMetric.memoryLimitTerminationCount
                    )
                case .signpostInterval(let signpostIntervalMetric):
                    print(
                        "Signpost interval:",
                        signpostIntervalMetric.signpostName
                    )
                case .locationActivityTime(let locationActivityTimeMetric):
                    print(
                        "Location activity time:",
                        locationActivityTimeMetric
                    )
                case .totalForegroundTime(let totalForegroundTimeMetric):
                    print(
                        "Total foreground time:",
                        totalForegroundTimeMetric
                    )
                case .totalBackgroundTime(let totalBackgroundTimeMetric):
                    print(
                        "Total background time:",
                        totalBackgroundTimeMetric
                    )
                case .totalBackgroundAudioTime(
                    let totalBackgroundAudioTimeMetric
                ):
                    print(
                        "Total background audio time:",
                        totalBackgroundAudioTimeMetric
                    )
                case .totalBackgroundLocationTime(
                    let totalBackgroundLocationTimeMetric
                ):
                    print(
                        "Total background location time:",
                        totalBackgroundLocationTimeMetric
                    )
                case .cpuTime(let cPUTimeMetric):
                    print("CPU time:", cPUTimeMetric)
                case .cpuInstructionsCount(let cPUInstructionsCountMetric):
                    print(
                        "CPU instructions count:",
                        cPUInstructionsCountMetric
                    )
                case .peakMemory(let peakMemoryMetric):
                    print("Peak memory:", peakMemoryMetric)
                case .suspendedMemory(let suspendedMemoryMetric):
                    print("Suspended memory:", suspendedMemoryMetric)
                case .totalWiFiUpload(let totalWiFiUploadMetric):
                    print("Total WiFi upload:", totalWiFiUploadMetric)
                case .totalWiFiDownload(let totalWiFiDownloadMetric):
                    print("Total WiFi download:", totalWiFiDownloadMetric)
                case .totalCellularUpload(let totalCellularUploadMetric):
                    print(
                        "Total cellular upload:",
                        totalCellularUploadMetric
                    )
                case .totalCellularDownload(let totalCellularDownloadMetric):
                    print(
                        "Total cellular download:",
                        totalCellularDownloadMetric
                    )
                case .logicalDiskWrites(let logicalDiskWritesMetric):
                    print("Logical disk writes:", logicalDiskWritesMetric)
                case .pixelLuminance(let pixelLuminanceMetric):
                    print("Pixel luminance:", pixelLuminanceMetric)
                case .gpuTime(let gPUTimeMetric):
                    print("GPU time:", gPUTimeMetric)
                case .cellularConditionTime(let cellularConditionTimeMetric):
                    print(
                        "Cellular condition time:",
                        cellularConditionTimeMetric
                    )
                case .timeToFirstDraw(let timeToFirstDrawMetric):
                    print("Time to first draw:", timeToFirstDrawMetric)
                case .applicationResumeTime(let applicationResumeTimeMetric):
                    print(
                        "Application resume time:",
                        applicationResumeTimeMetric
                    )
                case .optimizedTimeToFirstDraw(
                    let optimizedTimeToFirstDrawMetric
                ):
                    print(
                        "Optimized time to first draw:",
                        optimizedTimeToFirstDrawMetric
                    )
                case .extendedLaunch(let extendedLaunchMetric):
                    print("Extended launch:", extendedLaunchMetric)
                case .totalFileCount(let totalFileCountMetric):
                    print("Total file count:", totalFileCountMetric)
                case .totalFileSize(let totalFileSizeMetric):
                    print("Total file size:", totalFileSizeMetric)
                case .totalDiskSpaceCapacity(let totalDiskSpaceCapacityMetric):
                    print(
                        "Total disk space capacity:",
                        totalDiskSpaceCapacityMetric
                    )
                case .metalFrameRate(let metalFrameRateMetric):
                    print("Metal frame rate:", metalFrameRateMetric)
                @unknown default:
                    print("received unknown MetricResult: ", value)
                    break
                }
            }

        }

        // Metrics segmented by app state.
        for entry in report.stateEntries {
            print("---Metrics by app state---")
            printState(entry.state)
            printMetricResults(entry.values)
            print("------")
        }

        // Metrics aggregated over time intervals.
        for entry in report.intervalEntries {
            print("---Metrics aggregated over time intervals---")
            for state in entry.states {
                printState(state)
            }
            printMetricResults(entry.values)
            print("------")
        }

        print("------END------")

    }

    private func handleDiagnostic(_ report: DiagnosticReport) {
        print("Received diagnostic report")

        print("environment: \(report.environment, default: "Unknown")")
        print("\(report.timeRange.start) - \(report.timeRange.end)")

        switch report.result {
        case .crash(let crashDiagnostic):
            print("Crash: ", crashDiagnostic)
        case .hang(let hangDiagnostic):
            print("Hang: ", hangDiagnostic)
        case .cpuException(let cPUExceptionDiagnostic):
            print("CPU Exception: ", cPUExceptionDiagnostic)
        case .diskWriteException(let diskWriteExceptionDiagnostic):
            print("Disk Write Exception: ", diskWriteExceptionDiagnostic)
        case .appLaunch(let appLaunchDiagnostic):
            print("App Launch: ", appLaunchDiagnostic)
        case .memoryException(let memoryExceptionDiagnostic):
            print("Memory Exception: ", memoryExceptionDiagnostic)
        @unknown default:
            print("received unknown report result: ", report.result)
            break
        }

        print("------END------")
    }
}
