# Интеграция в iAPS 8.x

## Важно: версии 8.0.3 не существует

В репозитории `Artificial-Pancreas/iAPS` есть теги
`v8.0.2`, **`v8.0.4`**, `v8.0.5`, `v8.2.0`, `v8.2.1`, `v8.3.0`.
Тега `v8.0.3` нет.

Значит «8.0.3» на твоём телефоне — либо промежуточная dev-сборка,
либо собственная нумерация форка Замотаевой. Всё ниже проверено
по **v8.0.4** (архитектура в v8.3.0 та же).

## Архитектура CGM в 8.x

Здесь я раньше ошибался: `GlucoseSource` / `FetchGlucoseManager` —
это архитектура iAPS **7.x и раньше**. В 8.x её нет.

В 8.x используется **плагинная модель LoopKit**:
CGM — это реализация `CGMManagerUI`, регистрируемая по `pluginIdentifier`.
Встроенные примеры: `AppGroupCGM`, `MockCGMManager`.
Внешние: `G7SensorKit`, `CGMBLEKit`, `LibreTransmitter`.

Поэтому адаптер здесь написан как `CGMManagerUI` по образцу
`FreeAPS/Sources/APS/CGM/AppGroupCGM/`.

## Файлы

Положить в `FreeAPS/Sources/APS/CGM/Aidex/`:

```
AidexCrypto.swift          вывод ключей, AES-128-CFB, CRC
AidexProtocol.swift        UUID, команды, разбор пакетов
AidexBLEManager.swift      BLE-транспорт, автомат сессии
AidexCGMManager.swift      адаптер LoopKit CGMManager
AidexCGMManager+UI.swift   CGMManagerUI + экран настроек
AidexCGMPlugin.swift       регистрация плагина
```

Все шесть добавить в таргет `FreeAPS` в Xcode.

## Правка DeviceDataManager.swift

Файл `FreeAPS/Sources/APS/DeviceDataManager.swift`, строки ~63–71.

Было:

```swift
private let staticCGMManagers: [CGMManagerDescriptor] = [
    CGMManagerDescriptor(identifier: MockCGMManager.pluginIdentifier, localizedTitle: MockCGMManager.localizedTitle),
    CGMManagerDescriptor(identifier: AppGroupCGM.pluginIdentifier, localizedTitle: AppGroupCGM.localizedTitle)
]

private let staticCGMManagersByIdentifier: [String: CGMManager.Type] = [
    MockCGMManager.pluginIdentifier: MockCGMManager.self,
    AppGroupCGM.pluginIdentifier: AppGroupCGM.self
]
```

Стало:

```swift
private let staticCGMManagers: [CGMManagerDescriptor] = [
    CGMManagerDescriptor(identifier: MockCGMManager.pluginIdentifier, localizedTitle: MockCGMManager.localizedTitle),
    CGMManagerDescriptor(identifier: AppGroupCGM.pluginIdentifier, localizedTitle: AppGroupCGM.localizedTitle),
    CGMManagerDescriptor(identifier: AidexCGMManager.pluginIdentifier, localizedTitle: AidexCGMManager.localizedTitle)
]

private let staticCGMManagersByIdentifier: [String: CGMManager.Type] = [
    MockCGMManager.pluginIdentifier: MockCGMManager.self,
    AppGroupCGM.pluginIdentifier: AppGroupCGM.self,
    AidexCGMManager.pluginIdentifier: AidexCGMManager.self
]
```

Больше **ничего править не нужно** — `CGMType.swift` в 8.x
уже не является списком источников, а только legacy-маппингом.

## Info.plist

Убедиться, что есть строки разрешений (для Libre они уже там):

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Связь с сенсором глюкозы</string>
```

И фоновый режим `bluetooth-central` в `UIBackgroundModes`.

## Что почти наверняка не соберётся с первого раза

Я не компилировал этот код — Swift/iOS SDK есть только на macOS.
Ожидаемые места:

1. **`Locked` и `WeakSynchronizedDelegate`** — из LoopKit,
   должны подтянуться с `import LoopKit`, но проверь модуль.
2. **`debug(.deviceManager, ...)`** — функция логирования iAPS,
   уточни её сигнатуру в проекте.
3. **`NewGlucoseSample`** — набор параметров менялся между
   версиями LoopKit. Сверь с `AppGroupSource.swift`.
4. **`GlucoseRangeCategory`, `DeviceStatusHighlightState`** —
   имена кейсов могут отличаться.
5. **SwiftUI-настройки** — `CGMManagerSettingsNavigationViewController`
   ожидает конкретный тип, возможна правка.

## Порядок проверки

1. Собрать, починить ошибки компиляции.
2. Поставить на телефон, ввести серийный номер.
3. **Смотреть лог** — там видно каждый шаг: скан, подключение,
   обмен ключами, CRC. Если CRC8 сессионного ключа не сходится —
   ошибка в выводе ключа/IV. Если CRC16 пакета не сходится —
   ошибка в разборе.
4. Параллельно с рабочим приложением сверять значения глюкозы
   **несколько дней**, прежде чем позволять этому считать дозы.

Особое внимание — полю `trend`. Масштаб этого поля я по исходнику
Juggluco не подтвердил, пороги в `loopKitTrend` поставлены
по общепринятой шкале и могут оказаться неверными.

---

# Дополнение: срок жизни сенсора в KnownPlugins

Чтобы iAPS показывал срок годности сенсора, в
`FreeAPS/Sources/APS/KnownPlugins.swift` добавить:

В `cgmExpirationByPluginIdentifier`:

```swift
case AidexCGMManager.pluginIdentifier:
    return (cgmManager as? AidexCGMManager)?.sensorExpiration?
        .timeIntervalSince((cgmManager as? AidexCGMManager)?.sensorStartDate ?? Date())
```

В `sessionStart`:

```swift
case AidexCGMManager.pluginIdentifier:
    return (cgmManager as? AidexCGMManager)?.sensorStartDate
```

Оба блока необязательны — без них всё работает,
просто не будет индикатора срока годности.

# Дополнение: что проверять в логе

Порядок сообщений при нормальном подключении:

```
Aidex: старт, SN=222225C99G, ключ отсутствует
Aidex: состояние: scanning
Aidex: найден AiDEX X-222225C99G RSSI=-62
Aidex: состояние: connecting
Aidex: состояние: discoveringServices
Aidex: -> F001 askKey
Aidex: сессионный ключ принят          <- если тут CRC8, ошибка в выводе ключа
Aidex: состояние: running
Aidex: -> F002 10 C1 F3
Aidex: прошивка 1.8.2.0, срок 15 дн
Aidex: -> F002 21 B3 D5
Aidex: старт сенсора: 2026-07-20 14:32:05 UTC+3.00 dst=0
Aidex: -> F002 22 D0 E5
Aidex: на сенсоре доступно до id=8412, получено до 0
Aidex: запрос истории с id=1 (rel=1)
Aidex: получено N исторических значений, id 1…N
...
Aidex: глюкоза 118 мг/дл, -0.30 мг/дл/мин, id=8412
```

Диагностика по месту сбоя:

- **CRC8 ключа не сошёлся** — ошибка в `makeIV` или `askKey`,
  либо серийный номер введён неверно
- **CRC16 пакета не сошёлся** — расшифровка идёт, но разбор неверен,
  либо не тот ключ (сессионный vs askKey)
- **Неизвестный код 0x…** — появился ответ, которого нет в
  `AidexResponse`; посмотреть `java.cpp: switch(short1)`
- **«время старта неизвестно»** — не прошёл обмен `0x0121`,
  глюкоза принудительно отбрасывается (как в оригинале)
- **История запрашивается бесконечно** — смотреть `indexShift`
  в логе строки «запрос истории с id=N (rel=M, сдвиг=K)».
  Если `rel` не совпадает с нумерацией сенсора, история будет
  приходить не с того места и `lastReceivedID` не сдвинется.

- **Время записей уехало на N минут** — почти наверняка `indexShift`.
  В диагностике видно `indexShift: N мин + M с`. При первой привязке
  оба должны быть нулями.
