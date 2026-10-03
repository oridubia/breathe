/// Text the pacer shows besides the count.
public enum Readout {
    /// "m:ss" in whole seconds, truncated, like breathe.py's fmt. Minutes are
    /// not wrapped into hours: a long sit reads "75:00".
    public static func clock(_ seconds: Double) -> String {
        let whole = seconds > 0 ? Int(seconds) : 0
        let rest = whole % 60
        return "\(whole / 60):\(rest < 10 ? "0" : "")\(rest)"
    }
}
