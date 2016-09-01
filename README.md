ICY / Essent e-thermostaat client in Swift
==========================================

Swift client library for ICY / Essent thermostats.

**Usage:**

See [my-homekit](https://github.com/Bouke/my-homekit) for an actual implementation.

    ICY.login(username: "xxx", password: "xxx") { result in
        let session = try! result.unpack()

        session.getStatus() {
            let status = try! result.unpack()

            print("The current temperature is \(status.currentTemperature)")
            print("The target temperature is \(status.desiredTemperature)")
        }
    }
