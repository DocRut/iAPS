//
//  AidexCGMManager+UI.swift
//  CGMManagerUI + экран настроек.
//  Шаблон: AppGroupCGM+UI.swift (iAPS v8.0.4)
//

import Foundation
import LoopKit
import LoopKitUI
import SwiftUI

extension AidexCGMManager: CGMManagerUI {

    public static var onboardingImage: UIImage? { nil }

    public static func setupViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference _: DisplayGlucosePreference,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool,
        prefersToSkipUserInteraction _: Bool
    ) -> SetupUIResult<CGMManagerViewController, CGMManagerUI> {
        // Серийный номер вводится в настройках после добавления
        .createdAndOnboarded(AidexCGMManager())
    }

    public func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        displayGlucosePreference _: DisplayGlucosePreference,
        colorPalette _: LoopUIColorPalette,
        allowDebugFeatures _: Bool
    ) -> CGMManagerViewController {
        let host = AidexSettingsHostingController(
            rootView: AidexSettingsView(manager: self)
        )
        return CGMManagerSettingsNavigationViewController(rootViewController: host)
    }

    public var smallImage: UIImage? { nil }

    public var cgmStatusHighlight: DeviceStatusHighlight? {
        switch currentSessionState {
        case .running:
            return AidexStatusHighlight(
                localizedMessage: NSLocalizedString("Connected", comment: "Aidex connected"),
                imageName: "dot.radiowaves.left.and.right",
                state: .normalCGM
            )
        case .scanning, .connecting, .discoveringServices, .awaitingSessionKey:
            return AidexStatusHighlight(
                localizedMessage: NSLocalizedString("Connecting", comment: "Aidex connecting"),
                imageName: "dot.radiowaves.left.and.right",
                state: .normalCGM
            )
        case let .failed(reason):
            return AidexStatusHighlight(
                localizedMessage: reason,
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        case .sensorEnded:
            return AidexStatusHighlight(
                localizedMessage: NSLocalizedString("Sensor ended", comment: "Aidex sensor ended"),
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        case .unpaired:
            return AidexStatusHighlight(
                localizedMessage: NSLocalizedString("Sensor unpaired", comment: "Aidex unpaired"),
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        case .bluetoothUnavailable:
            return AidexStatusHighlight(
                localizedMessage: NSLocalizedString("Bluetooth off", comment: "Aidex BT off"),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        case .idle:
            return AidexStatusHighlight(
                localizedMessage: NSLocalizedString("Not connected", comment: "Aidex not connected"),
                imageName: "exclamationmark.circle.fill",
                state: .warning
            )
        }
    }

    public var cgmStatusBadge: DeviceStatusBadge? { nil }

    public var cgmLifecycleProgress: DeviceLifecycleProgress? {
        guard let start = sensorStartDate, let expiry = sensorExpiration else { return nil }
        let total = expiry.timeIntervalSince(start)
        guard total > 0 else { return nil }
        let elapsed = Date().timeIntervalSince(start)
        let progress = min(1.0, max(0.0, elapsed / total))

        let remainingDays = expiry.timeIntervalSinceNow / 86400
        let state: DeviceLifecycleProgressState = remainingDays < 1
            ? .critical
            : (remainingDays < 2 ? .warning : .normalCGM)

        return AidexLifecycleProgress(percentComplete: progress, progressState: state)
    }
}

struct AidexStatusHighlight: DeviceStatusHighlight {
    let localizedMessage: String
    let imageName: String
    let state: DeviceStatusHighlightState
}

struct AidexLifecycleProgress: DeviceLifecycleProgress {
    let percentComplete: Double
    let progressState: DeviceLifecycleProgressState
}

// MARK: - Экран настроек

final class AidexSettingsHostingController: UIHostingController<AidexSettingsView>,
    CGMManagerOnboardNotifying, CompletionNotifying
{
    weak var cgmManagerOnboardingDelegate: CGMManagerOnboardingDelegate?
    weak var completionDelegate: CompletionDelegate?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        completionDelegate?.completionNotifyingDidComplete(self)
    }
}

struct AidexSettingsView: View {
    let manager: AidexCGMManager

    @State private var serial: String = ""
    @State private var showUnpairConfirm = false
    @State private var showClearConfirm = false

    private var serialIsValid: Bool { serial.count == 10 }

    var body: some View {
        Form {
            Section {
                TextField("напр. 222225C99G", text: $serial)
                    .textInputAutocapitalization(.characters)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))

                Button("Подключить сенсор") {
                    manager.setSerialNumber(serial)
                }
                .disabled(!serialIsValid || serial == manager.serialNumber)
            } header: {
                Text("Серийный номер")
            } footer: {
                Text("10 символов с коробки сенсора. Тот же номер стоит в имени устройства Bluetooth: AiDEX X-…")
            }

            if let start = manager.sensorStartDate {
                Section("Сенсор") {
                    LabeledContent("Запущен", value: start.formatted(date: .abbreviated, time: .shortened))
                    if let expiry = manager.sensorExpiration {
                        LabeledContent(
                            "Заканчивается",
                            value: expiry.formatted(date: .abbreviated, time: .shortened)
                        )
                        let days = max(0, Int(expiry.timeIntervalSinceNow / 86400))
                        LabeledContent("Осталось", value: "\(days) дн")
                    }
                }
            }

            Section("Диагностика") {
                Text(manager.debugDescription)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Section {
                Button("Отвязать сенсор", role: .destructive) {
                    showUnpairConfirm = true
                }
                .confirmationDialog(
                    "Отвязать сенсор от этого телефона?",
                    isPresented: $showUnpairConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Отвязать", role: .destructive) { manager.unpairSensor() }
                    Button("Отмена", role: .cancel) {}
                }

                Button("Сбросить привязку", role: .destructive) {
                    showClearConfirm = true
                }
                .confirmationDialog(
                    "Сбросить привязку полностью? Потребуется заново подключить сенсор.",
                    isPresented: $showClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Сбросить", role: .destructive) { manager.clearSensor() }
                    Button("Отмена", role: .cancel) {}
                }
            }
        }
        .navigationTitle("Aidex")
        .onAppear { serial = manager.serialNumber }
    }
}
