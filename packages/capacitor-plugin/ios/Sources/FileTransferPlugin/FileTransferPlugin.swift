import Foundation
import Combine
import Capacitor
import IONFileTransferLib
import QuartzCore

private enum Action: String {
    case download
    case upload
}

/// A Capacitor plugin that enables file upload and download using the IONFileTransferLib.
///
/// This plugin provides two main JavaScript-exposed methods: `uploadFile` and `downloadFile`.
/// Internally, it uses Combine to observe progress and results, and bridges data using CAPPluginCall.
@objc(FileTransferPlugin)
public class FileTransferPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "FileTransferPlugin"
    public let jsName = "FileTransfer"
    public let pluginMethods: [CAPPluginMethod] = [
        .init(selector: #selector(downloadFile), returnType: CAPPluginReturnPromise),
        .init(selector: #selector(uploadFile), returnType: CAPPluginReturnPromise)
    ]
    private lazy var manager: IONFLTRManager = .init()
    private lazy var cancellables: Set<AnyCancellable> = []
    private var lastProgressReportTime = CACurrentMediaTime()
    private let progressUpdateInterval: TimeInterval = 0.1 // 100ms

    /// Downloads a file from the provided URL to the specified local path.
    ///
    /// - Parameter call: The Capacitor call containing `url`, `path`, and optional HTTP options.
    @objc func downloadFile(_ call: CAPPluginCall) {
        do {
            let prepData = try validateAndPrepare(call: call, action: .download)
            if let requestBody = try extractRequestBody(call: call) {
                try downloadFileWithRequestBody(
                    call: call,
                    prepData: prepData,
                    requestBody: requestBody
                )
                return
            }

            try manager.downloadFile(
                fromServerURL: prepData.serverURL,
                toFileURL: prepData.fileURL,
                withHttpOptions: prepData.httpOptions
            ).sink(
                receiveCompletion: handleCompletion(call: call, source: prepData.serverURL.absoluteString, target: prepData.fileURL.absoluteString),
                receiveValue: handleReceiveValue(
                    call: call,
                    type: .download,
                    url: prepData.serverURL.absoluteString,
                    path: prepData.fileURL.path,
                    shouldTrackProgress: prepData.shouldTrackProgress
                )
            ).store(in: &cancellables)
        } catch {
            call.sendError(error, source: call.getString("url"), target: call.getString("path"))
        }
    }

    private func extractRequestBody(call: CAPPluginCall) throws -> Data? {
        if let dataString = call.getString("data") {
            return dataString.data(using: .utf8)
        }

        if let dataObject = call.getObject("data"),
           JSONSerialization.isValidJSONObject(dataObject) {
            return try JSONSerialization.data(withJSONObject: dataObject)
        }

        if let dataArray = call.getArray("data"),
           JSONSerialization.isValidJSONObject(dataArray) {
            return try JSONSerialization.data(withJSONObject: dataArray)
        }

        return nil
    }

    private func buildURLWithParams(call: CAPPluginCall, baseURL: URL) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw FileTransferError.invalidServerUrl(baseURL.absoluteString)
        }

        let params = call.getObject("params") ?? JSObject()
        if !params.isEmpty {
            let shouldEncode = call.getBool("shouldEncodeUrlParams", true)
            let queryItems = extractParams(from: params).flatMap { key, values in
                values.map { value in
                    URLQueryItem(name: key, value: shouldEncode ? value : value.removingPercentEncoding ?? value)
                }
            }
            components.queryItems = queryItems
        }

        guard let url = components.url else {
            throw FileTransferError.invalidServerUrl(baseURL.absoluteString)
        }
        return url
    }

    private func downloadFileWithRequestBody(
        call: CAPPluginCall,
        prepData: TransferPreparationData,
        requestBody: Data
    ) throws {
        let requestURL = try buildURLWithParams(call: call, baseURL: prepData.serverURL)
        var request = URLRequest(url: requestURL)
        request.httpMethod = call.getString("method") ?? defaultHTTPMethod(for: .download)
        request.httpBody = requestBody
        request.timeoutInterval = TimeInterval(call.getInt("connectTimeout", call.getInt("readTimeout", 60000)) / 1000)

        let headers = extractHeaders(from: call.getObject("headers") ?? JSObject())
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let shouldTrackProgress = prepData.shouldTrackProgress
        URLSession.shared.downloadTask(with: request) { temporaryURL, response, error in
            if let error = error {
                call.sendError(error, source: prepData.serverURL.absoluteString, target: prepData.fileURL.absoluteString)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                call.sendError(
                    FileTransferError.genericError(),
                    source: prepData.serverURL.absoluteString,
                    target: prepData.fileURL.absoluteString
                )
                return
            }

            let responseHeaders = httpResponse.allHeaderFields.reduce(into: [String: String]()) { result, pair in
                if let key = pair.key as? String, let value = pair.value as? String {
                    result[key] = value
                }
            }

            guard (200...299).contains(httpResponse.statusCode) else {
                let errorBody: String? = temporaryURL.flatMap { try? String(contentsOf: $0) }
                call.sendError(
                    FileTransferError.httpError(
                        responseCode: httpResponse.statusCode,
                        message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                        responseBody: errorBody,
                        headers: responseHeaders
                    ),
                    source: prepData.serverURL.absoluteString,
                    target: prepData.fileURL.absoluteString
                )
                return
            }

            guard let temporaryURL else {
                call.sendError(
                    FileTransferError.genericError(),
                    source: prepData.serverURL.absoluteString,
                    target: prepData.fileURL.absoluteString
                )
                return
            }

            do {
                let directory = prepData.fileURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
                if FileManager.default.fileExists(atPath: prepData.fileURL.path) {
                    try FileManager.default.removeItem(at: prepData.fileURL)
                }
                try FileManager.default.moveItem(at: temporaryURL, to: prepData.fileURL)

                if shouldTrackProgress {
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: prepData.fileURL.path)[.size] as? NSNumber)?.intValue ?? 0
                    self.reportProgressIfNeeded(
                        type: .download,
                        url: prepData.serverURL.absoluteString,
                        bytes: fileSize,
                        contentLength: fileSize,
                        lengthComputable: true,
                        shouldTrack: true,
                        force: true
                    )
                }

                call.resolve(["path": prepData.fileURL.path])
            } catch {
                call.sendError(error, source: prepData.serverURL.absoluteString, target: prepData.fileURL.absoluteString)
            }
        }.resume()
    }

    /// Uploads a file from the provided path to the specified server URL.
    ///
    /// - Parameter call: The Capacitor call containing `url`, `path`, `fileKey`, and optional HTTP options.
    @objc func uploadFile(_ call: CAPPluginCall) {
        do {
            let prepData = try validateAndPrepare(call: call, action: .upload)
            let chunkedMode = call.getBool("chunkedMode", false)
            let mimeType = call.getString("mimeType")
            let fileKey = call.getString("fileKey") ?? "file"
            let uploadOptions = IONFLTRUploadOptions(
                chunkedMode: chunkedMode,
                mimeType: mimeType,
                fileKey: fileKey
            )

            try manager.uploadFile(
                fromFileURL: prepData.fileURL,
                toServerURL: prepData.serverURL,
                withUploadOptions: uploadOptions,
                andHttpOptions: prepData.httpOptions
            ).sink(
                receiveCompletion: handleCompletion(call: call, source: prepData.fileURL.absoluteString, target: prepData.serverURL.absoluteString),
                receiveValue: handleReceiveValue(
                    call: call,
                    type: .upload,
                    url: prepData.serverURL.absoluteString,
                    path: prepData.fileURL.path,
                    shouldTrackProgress: prepData.shouldTrackProgress
                )
            ).store(in: &cancellables)
        } catch {
            call.sendError(error, source: call.getString("path"), target: call.getString("url"))
        }
    }

    /// Structure to hold transfer preparation data.
    private struct TransferPreparationData {
        let serverURL: URL
        let fileURL: URL
        let shouldTrackProgress: Bool
        let httpOptions: IONFLTRHttpOptions
    }

    /// Validates parameters from the call and prepares transfer-related data.
    ///
    /// - Parameters:
    ///   - call: The plugin call.
    ///   - action: The type of action (`upload` or `download`).
    /// - Throws: An error if validation fails.
    /// - Returns: Structure containing server URL, file URL, progress flag, and HTTP options.
    private func validateAndPrepare(call: CAPPluginCall, action: Action) throws -> TransferPreparationData {
        guard let url = call.getString("url") else {
            throw FileTransferError.invalidServerUrl(nil)
        }

        guard let serverURL = URL(string: url) else {
            throw FileTransferError.invalidServerUrl(url)
        }

        guard let path = call.getString("path") else {
            throw FileTransferError.invalidParameters("Path is required.")
        }

        guard let fileURL = URL(string: path) else {
            throw FileTransferError.invalidParameters("Path is invalid.")
        }

        let shouldTrackProgress = call.getBool("progress", false)
        let headers = call.getObject("headers") ?? JSObject()
        let params = call.getObject("params") ?? JSObject()

        let httpOptions = IONFLTRHttpOptions(
            method: call.getString("method") ?? defaultHTTPMethod(for: action),
            params: extractParams(from: params),
            headers: extractHeaders(from: headers),
            timeout: call.getInt("connectTimeout", call.getInt("readTimeout", 60000)) / 1000, // Timeouts in iOS are in seconds. So read the value in millis and divide by 1000
            disableRedirects: call.getBool("disableRedirects", false),
            shouldEncodeUrlParams: call.getBool("shouldEncodeUrlParams", true)
        )

        return TransferPreparationData(
            serverURL: serverURL,
            fileURL: fileURL,
            shouldTrackProgress: shouldTrackProgress,
            httpOptions: httpOptions
        )
    }

    /// Provides the default HTTP method for the given action.
    private func defaultHTTPMethod(for action: Action) -> String {
        switch action {
        case .download:
            return "GET"
        case .upload:
            return "POST"
        }
    }

    /// Converts a JSObject to a string dictionary used for headers.
    private func extractHeaders(from jsObject: JSObject) -> [String: String] {
        return jsObject.reduce(into: [String: String]()) { result, pair in
            if let stringValue = pair.value as? String {
                result[pair.key] = stringValue
            }
        }
    }

    /// Converts a JSObject to a dictionary of arrays, supporting both string and string-array values.
    private func extractParams(from jsObject: JSObject) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (key, value) in jsObject {
            if let stringValue = value as? String {
                result[key] = [stringValue]
            } else if let arrayValue = value as? [Any] {
                let stringArray = arrayValue.compactMap { $0 as? String }
                if !stringArray.isEmpty {
                    result[key] = stringArray
                }
            }
        }
        return result
    }

    /// Handles completion of the upload or download Combine pipeline.
    private func handleCompletion(call: CAPPluginCall, source: String, target: String) -> (Subscribers.Completion<Error>) -> Void {
        return { completion in
            if case let .failure(error) = completion {
                call.sendError(error, source: source, target: target)
            }
        }
    }

    /// Handles received value from the Combine stream.
    ///
    /// - Parameters:
    ///   - call: The original plugin call.
    ///   - type: Whether it's an upload or download.
    ///   - url: The source or destination URL as string.
    ///   - path: The file path used in the transfer.
    ///   - shouldTrackProgress: Whether progress events should be emitted.
    private func handleReceiveValue(
        call: CAPPluginCall,
        type: Action,
        url: String,
        path: String,
        shouldTrackProgress: Bool
    ) -> (IONFLTRTransferResult) -> Void {
        return { result in
            switch result {
            case .ongoing(let status):
                self.reportProgressIfNeeded(
                    type: type,
                    url: url,
                    bytes: status.bytes,
                    contentLength: status.contentLength,
                    lengthComputable: status.lengthComputable,
                    shouldTrack: shouldTrackProgress
                )

            case .complete(let data):
                self.reportProgressIfNeeded(
                    type: type,
                    url: url,
                    bytes: data.totalBytes,
                    contentLength: data.totalBytes,
                    lengthComputable: true,
                    shouldTrack: shouldTrackProgress,
                    force: true
                )

                let result: JSObject = {
                    switch type {
                    case .download:
                        return ["path": path]
                    case .upload:
                        return [
                            "bytesSent": data.totalBytes,
                            "responseCode": "\(data.responseCode)",
                            "response": data.responseBody ?? "",
                            "headers": data.headers.reduce(into: JSObject()) { result, entry in
                                result[entry.key] = entry.value
                            }
                        ]
                    }
                }()
                call.resolve(result)
            }
        }
    }

    /// Reports a progress event to JavaScript listeners if conditions are met.
    ///
    /// This method emits a `"progress"` event with details about the transfer status, including
    /// the number of bytes transferred and the total expected content length. It respects a
    /// throttling interval (`progressUpdateInterval`) to avoid sending too many events, unless
    /// forced via the `force` parameter.
    ///
    /// - Parameters:
    ///   - type: The type of file transfer operation (`upload` or `download`).
    ///   - url: The source or destination URL of the file transfer.
    ///   - bytes: The number of bytes transferred so far.
    ///   - contentLength: The total number of bytes expected to be transferred.
    ///   - lengthComputable: A Boolean value indicating whether the content length is known.
    ///   - shouldTrack: A flag indicating whether progress tracking is enabled.
    ///   - force: A flag that, if true, bypasses throttling and sends the event immediately. Defaults to `false`.
    private func reportProgressIfNeeded(
        type: Action,
        url: String,
        bytes: Int,
        contentLength: Int,
        lengthComputable: Bool,
        shouldTrack: Bool,
        force: Bool = false
    ) {
        guard shouldTrack else { return }

        let current = CACurrentMediaTime()
        guard force || (current - lastProgressReportTime >= progressUpdateInterval) else { return }
        lastProgressReportTime = current

        let progressData: JSObject = [
            "type": type.rawValue,
            "url": url,
            "bytes": bytes,
            "contentLength": contentLength,
            "lengthComputable": lengthComputable
        ]
        notifyListeners("progress", data: progressData)
    }
}

extension CAPPluginCall {
    func sendError(_ error: Error, source: String?, target: String?) {
        var pluginError: FileTransferError
        switch error {
        case let error as FileTransferError:
            pluginError = error
        case let error as IONFLTRException:
            pluginError = error.toFileTransferError()
        default:
            pluginError = .genericError(cause: error)
        }
        pluginError.source = source
        pluginError.target = target
        self.reject(pluginError.message, pluginError.code, nil, pluginError.errorInfo)
    }
}
