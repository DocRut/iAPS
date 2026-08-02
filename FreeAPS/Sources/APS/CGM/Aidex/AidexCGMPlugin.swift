import LoopKitUI

class AidexCGMPlugin: NSObject, CGMManagerUIPlugin {
    public var cgmManagerType: CGMManagerUI.Type? {
        AidexCGMManager.self
    }

    override init() {
        super.init()
    }
}
