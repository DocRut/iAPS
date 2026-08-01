//
//  AidexCGMPlugin.swift
//  Регистрация плагина. Шаблон: AppGroupCGMPlugin.swift (iAPS v8.0.4)
//

import LoopKitUI

class AidexCGMPlugin: NSObject, CGMManagerUIPlugin {
    public var cgmManagerType: CGMManagerUI.Type? {
        AidexCGMManager.self
    }

    override init() {
        super.init()
    }
}
