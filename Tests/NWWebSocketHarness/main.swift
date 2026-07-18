import Foundation
import Network

guard CommandLine.arguments.count == 2,
      let baseURL = URL(string: CommandLine.arguments[1]) else {
    fputs("usage: nw-smoke https://relay.example\n", stderr)
    exit(2)
}

let createDone = DispatchSemaphore(value: 0)
var room: [String: Any]?
var createFailure: String?
var request = URLRequest(url: baseURL.appendingPathComponent("v1/rooms"))
request.httpMethod = "POST"
request.setValue("application/json", forHTTPHeaderField: "Content-Type")
request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Sofa-Client-ID")
request.setValue("1", forHTTPHeaderField: "X-Sofa-Protocol")
request.httpBody = Data("{}".utf8)
URLSession.shared.dataTask(with: request) { data, response, error in
    defer { createDone.signal() }
    guard error == nil,
          (response as? HTTPURLResponse)?.statusCode == 201,
          let data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        createFailure = error?.localizedDescription ?? "room creation failed"
        return
    }
    room = object
}.resume()

guard createDone.wait(timeout: .now() + 15) == .success,
      createFailure == nil,
      let room,
      let socketURLString = room["webSocketURL"] as? String,
      let socketURL = URL(string: socketURLString),
      let secret = room["secret"] as? String else {
    fputs("FAIL: \(createFailure ?? "invalid create response")\n", stderr)
    exit(1)
}

let params = NWParameters.tls
let webSocket = NWProtocolWebSocket.Options()
webSocket.autoReplyPing = true
webSocket.maximumMessageSize = 64 * 1024
params.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
let connection = NWConnection(to: .url(socketURL), using: params)
let welcomeDone = DispatchSemaphore(value: 0)
var succeeded = false

connection.stateUpdateHandler = { state in
    switch state {
    case .ready:
        let hello: [String: Any] = [
            "type": "hello",
            "token": secret,
            "name": "Native Network.framework",
            "from": "spoofed",
        ]
        let data = try! JSONSerialization.data(withJSONObject: hello)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "hello", metadata: [metadata])
        connection.send(content: data, contentContext: context, completion: .contentProcessed { error in
            if error != nil { welcomeDone.signal() }
        })
    case .failed, .cancelled:
        welcomeDone.signal()
    default:
        break
    }
}

connection.receiveMessage { data, _, _, _ in
    if let data,
       let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       message["type"] as? String == "welcome",
       message["peerID"] as? String != nil,
       !String(data: data, encoding: .utf8)!.contains(secret) {
        succeeded = true
    }
    welcomeDone.signal()
}
connection.start(queue: DispatchQueue(label: "sofa.nw-relay-smoke"))

let completed = welcomeDone.wait(timeout: .now() + 15) == .success
connection.cancel()
guard completed, succeeded else {
    fputs("FAIL: native WSS did not receive a valid welcome\n", stderr)
    exit(1)
}
print("Native Network.framework WSS smoke test passed")
