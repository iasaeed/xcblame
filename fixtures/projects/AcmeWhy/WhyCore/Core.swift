public enum Core {
    public static func value() -> Int {
        #if WHY_A
        return 1
        #else
        return 2
        #endif
    }
}
