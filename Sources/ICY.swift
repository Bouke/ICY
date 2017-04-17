import Foundation

public enum Weekday: Int {
    case monday = 0, tuesday, wednesday, thursday, friday, saturday, sunday
}

public enum ThermostatSetting {
    case away, comfort, saving, fixed
}

public struct ThermostatTimeSwitch {
    public var day: Weekday
    public var time: Int
    public var setting: ThermostatSetting

    init?(rawValue: Int) {
        var rawValue = rawValue
        switch rawValue {
        case let x where x == 1<<16-1: return nil
        case let x where x>>15 & 1 == 1: setting = .comfort
        case let x where x>>14 & 1 == 1: setting = .saving
        default: setting = .away
        }
        rawValue &= ~(1<<15|1<<14)
        day = Weekday(rawValue: rawValue / (24*60))!
        time = rawValue % (24*60)
    }

    public init(day: Weekday, time: Int, setting: ThermostatSetting) {
        self.day = day
        self.time = time
        self.setting = setting
    }

    var rawValue: Int? {
        var value = time + day.rawValue * 24 * 60
        switch setting {
        case .comfort: value += 1<<15
        case .saving: value += 1<<14
        case .away: break
        default: return nil
        }
        return value
    }

    public var dateComponents: DateComponents {
        var components = DateComponents()
        components.hour = time / 60
        components.minute = time % 60
        components.weekday = (day.rawValue + 1) % 7 + 1 // Sunday = 1
        return components
    }
}

public struct ThermostatStatus {
    let uid: String
    let firstSeen: Date
    public let lastSeen: Date
    public var currentTemperature: Double
    public var desiredTemperature: Double
    public var schedule: [ThermostatTimeSwitch]
    public var configuration: [Int]

    public var setting: ThermostatSetting {
        get {
            // some examples:
            // 0 -> away
            // 4 -> away + heating
            // 40 -> comfort
            // 52 -> comfort + heating
            // 56 -> comfort + schedule
            // 60 -> comfort + schedule + heating
            // 92 -> saving + schedule + heating
            // 188 -> fixed + schedule + heating
            // 160 -> fixed
            // 164 -> fixed + heating
            // 176 -> fixed + schedule

            // bits:
            // 3 (4) -> heating
            // 4 (8) ->
            // 5 (16) ->
            // 6 (32) -> comfort
            // 7 (64) -> saving
            // 8 (128) -> fixed (with 6)
            switch(configuration[0]) {
            case let x where x & 128 == 128: return .fixed
            case let x where x & 64 == 64: return .saving
            case let x where x & 32 == 32: return .comfort
            default: return .away
            }
        }
        mutating set(value) {
            switch value {
            case .away:
                configuration[0] = 0
                desiredTemperature = defaultAwayTemperature
            case .comfort:
                configuration[0] = 32
                desiredTemperature = defaultComfortTemperature
            case .saving:
                configuration[0] = 64
                desiredTemperature = defaultSavingTemperature
            case .fixed:
                configuration[0] = 160
                desiredTemperature = defaultAwayTemperature
            }
        }
    }

    public var isHeating: Bool {
        return configuration[0] & 4 == 4
    }
    public var defaultComfortTemperature: Double {
        return Double(configuration[6] / 2)
    }
    public var defaultAwayTemperature: Double {
        return Double(configuration[4] / 2)
    }
    public var defaultSavingTemperature: Double {
        return Double(configuration[5] / 2)
    }
}

enum ICYError: Error {
    case error(String)
    case offlineSince(Date)
}

let dateFormatter = { () -> DateFormatter in
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
}()

public enum Result<T> {
    case success(T)
    case error(Error)

    public func unpack() throws -> T {
        switch self {
        case .success(let result): return result
        case .error(let error): throw error
        }
    }
}

let sharedURLSession: URLSession = {
    #if os(macOS)
        return URLSession.shared
    #elseif os(Linux)
        let configuration = URLSessionConfiguration()
        return URLSession(configuration: configuration)
    #endif
}()

func performRequest(_ request: URLRequest, completionHandler: @escaping (Result<[String: Any]>) -> ()) {
    let task = sharedURLSession.dataTask(with: request) { (data, response, error) in
        if let error = error {
            return completionHandler(.error(error))
        }
        guard
            let data = data,
            let json = (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any],
            let status = json["status"] as? [String: Any] else
        {
            return completionHandler(.error(ICYError.error("Deserialization error")))
        }
        guard status["code"] as? Int == 200 else {
            return completionHandler(.error(ICYError.error(status["message"] as? String ?? "Unspecified error")))
        }
        return completionHandler(.success(json))
    }
    task.resume()
}

func validateStatus(_ status: ThermostatStatus) throws -> ThermostatStatus {
    guard status.lastSeen.timeIntervalSinceNow > -600 else { throw ICYError.offlineSince(status.lastSeen) }
    return status
}

// JSON deserialization on Linux (Swift 3.1) returns integer if the
// wire-format doesn't include a decimal separator. So we need to take
// care of this. https://bugs.swift.org/browse/SR-4599
func doubleFromJSON(_ value: Any) -> Double {
    switch value {
    case let value as Double: return value
    case let value as Int: return Double(value)
    default: fatalError("Could not cast \(type(of: value)) to Double")
    }
}

public struct Session {
    let name: (first: String, infix: String, last: String)
    let username: String
    let token: String
    let email: String

    public func getStatus(completionHandler: @escaping (Result<ThermostatStatus>) -> ()) {
        var request = URLRequest(url: URL(string: "https://portal.icy.nl/data")!)
        request.setValue(token, forHTTPHeaderField: "Session-Token")
        performRequest(request) { result in
            switch result {
            case .success(let json):
                let status = ThermostatStatus(
                    uid: json["uid"] as! String,
                    firstSeen: dateFormatter.date(from: json["first-seen"] as! String)!,
                    lastSeen: dateFormatter.date(from: json["last-seen"] as! String)!,
                    currentTemperature: doubleFromJSON(json["temperature2"]!),
                    desiredTemperature: doubleFromJSON(json["temperature1"]!),
                    schedule: (json["week-clock"] as! [Int]).flatMap { ThermostatTimeSwitch(rawValue: $0) },
                    configuration: json["configuration"] as! [Int])
                completionHandler(.success(status))

            case .error(let error):
                completionHandler(.error(error))
            }
        }
    }

    public func setStatus(_ status: ThermostatStatus, completionHandler: @escaping (Result<Void>) -> ()) {
        var request = URLRequest(url: URL(string: "https://portal.icy.nl/data")!)
        request.setValue(token, forHTTPHeaderField: "Session-Token")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpMethod = "POST"
        var params = ["uid=\(status.uid)", "temperature1=\(status.desiredTemperature)"]
        status.configuration.forEach { params.append("configuration%5B%5D=\($0)") }
        status.schedule.forEach { params.append("week-clock%5B%5D=\($0.rawValue!)") }
        request.httpBody = params.joined(separator: "&").data(using: .ascii, allowLossyConversion: false)
        performRequest(request) { result in
            switch result {
            case .success(_):
                completionHandler(.success())
            case .error(let error):
                completionHandler(.error(error))
            }
        }
    }
}

public func login(username: String, password: String, completionHandler: @escaping (Result<Session>) -> ()) {
    var request = URLRequest(url: URL(string: "https://portal.icy.nl/login")!)
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpMethod = "POST"
    request.httpBody = "username=\(username)&password=\(password)&remember=1".data(using: String.Encoding.ascii, allowLossyConversion: false)
    performRequest(request as URLRequest) { result in
        switch result {
        case .success(let json):
            let session = Session(
                name: (json["name"] as! String, json["preposition"] as! String, json["lastname"] as! String),
                username: json["username"] as! String,
                token: json["token"] as! String,
                email: json["email"] as! String)
            completionHandler(.success(session))
        case .error(let error):
            completionHandler(.error(error))
        }
    }
}
