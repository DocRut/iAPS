//
//  AidexCGMManager+UI.swift
//  CGMManagerUI + экран настроек.
//  Шаблон: AppGroupCGM+UI.swift (iAPS v8.0.4)
//

import Combine
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
        let host = AidexSettingsHostingController(manager: self)
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

// Образец: AppGroupCGMSettingsViewController.swift — там используется
// только CompletionNotifying. Протокола CGMManagerOnboardNotifying
// в этой версии LoopKitUI нет.
public final class AidexSettingsHostingController: UIHostingController<AidexSettingsView>,
    CompletionNotifying
{
    public var completionDelegate: CompletionDelegate?

    private let manager: AidexCGMManager

    public init(manager: AidexCGMManager) {
        self.manager = manager
        super.init(rootView: AidexSettingsView(manager: manager))
        // Замыкания задаём после super.init — rootView уже создан
        rootView.onDelete = { [weak self] in self?.deleteCGM() }
        rootView.onClose = { [weak self] in self?.closeSettings() }
    }

    /// Образец: AppGroupCGMSettingsViewController.subscribeOnChanges()
    /// notifyDelegateOfDeletion приводит к cgmManagerWantsDeletion в iAPS,
    /// там cgmManager = nil — и снова появляется список вариантов CGM.
    private func deleteCGM() {
        manager.disconnect()
        manager.notifyDelegateOfDeletion {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.completionDelegate?.completionNotifyingDidComplete(self)
                self.dismiss(animated: true)
            }
        }
    }

    private func closeSettings() {
        completionDelegate?.completionNotifyingDidComplete(self)
        dismiss(animated: true)
    }

    @available(*, unavailable)
    @objc dynamic required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override public func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        completionDelegate?.completionNotifyingDidComplete(self)
    }
}

public struct AidexSettingsView: View {
    let manager: AidexCGMManager

    /// Заполняется контроллером после инициализации
    var onDelete: (() -> Void)?
    var onClose: (() -> Void)?

    @State private var serial: String = ""
    @State private var showUnpairConfirm = false
    @State private var showClearConfirm = false
    @State private var showDeleteConfirm = false
    @State private var logText = ""

    private let logRefreshTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(manager: AidexCGMManager) {
        self.manager = manager
    }

    private var serialIsValid: Bool { serial.count == 10 }

    public var body: some View {
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

            Section {
                Toggle("Ежеминутные показания", isOn: Binding(
                    get: { manager.minuteReadings },
                    set: { manager.setMinuteReadings($0) }
                ))
            } header: {
                Text("Частота показаний")
            } footer: {
                Text("""
                Сенсор отдаёт историю по запросу: в обычном режиме iAPS \
                опрашивает его каждые 5 минут, а при включении этого режима — \
                каждую минуту, получая ежеминутные значения глюкозы.
                """)
            }

            Section("Диагностика") {
                Text(manager.debugDescription)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.secondary)

                if !logText.isEmpty {
                    Text(logText)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            Section {
                Button("Отвязать сенсор от телефона", role: .destructive) {
                    showUnpairConfirm = true
                }
                .confirmationDialog(
                    "Отвязать сенсор от этого телефона? Данные на сенсоре сохранятся, его можно будет подключить к другому устройству.",
                    isPresented: $showUnpairConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Отвязать", role: .destructive) { manager.unpairSensor() }
                    Button("Отмена", role: .cancel) {}
                }
            } header: {
                Text("Управление сенсором")
            } footer: {
                Text("Чтобы подключить сенсор к другому телефону, сначала отвяжите его здесь.")
            }

            Section {
                Button("Перезапустить сенсор (Clear)", role: .destructive) {
                    showClearConfirm = true
                }
                .confirmationDialog(
                    "Стереть с сенсора все значения глюкозы и запустить его заново?",
                    isPresented: $showClearConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Перезапустить", role: .destructive) { manager.clearSensor() }
                    Button("Отмена", role: .cancel) {}
                }
            } footer: {
                Text("""
                Сенсор Aidex X рассчитан на 15 дней. Эта команда стирает с него всю \
                историю глюкозы, после чего он работает как новый.

                ВНИМАНИЕ: по данным разработчика Juggluco, показания перезапущенного \
                сенсора сильно расходятся с истинными — в его примере Libre 3 показывал \
                9.4 ммоль/л, а перезапущенный Aidex X — 3.7 ммоль/л. Использовать \
                только для тестов, не для принятия решений о дозах инсулина.
                """)
            }

            Section {
                Button("Удалить Aidex из iAPS", role: .destructive) {
                    showDeleteConfirm = true
                }
                .confirmationDialog(
                    "Удалить Aidex как источник CGM? После этого можно будет выбрать другой сенсор.",
                    isPresented: $showDeleteConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Удалить", role: .destructive) { onDelete?() }
                    Button("Отмена", role: .cancel) {}
                }
            } footer: {
                Text("Настройки сенсора будут удалены. Сам сенсор при этом не отвязывается — для этого используй «Отвязать сенсор» выше.")
            }
        }
        .navigationTitle("Aidex")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Готово") { onClose?() }
            }
        }
        .onAppear { serial = manager.serialNumber }
        .onReceive(logRefreshTimer) { _ in
            logText = manager.logHistory.reversed().joined(separator: "\n")
        }
    }
}
