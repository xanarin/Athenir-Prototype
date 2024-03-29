// MultipartFormData.swift
//
// Copyright (c) 2014–2015 Alamofire Software Foundation (http://alamofire.org/)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation

#if os(iOS)
import MobileCoreServices
#elseif os(OSX)
import CoreServices
#endif

/**
    Constructs `multipart/form-data` for uploads within an HTTP or HTTPS body. There are currently two ways to encode 
    multipart form data. The first way is to encode the data directly in memory. This is very efficient, but can lead 
    to memory issues if the dataset is too large. The second way is designed for larger datasets and will write all the 
    data to a single file on disk with all the proper boundary segmentation. The second approach MUST be used for 
    larger datasets such as video content, otherwise your app may run out of memory when trying to encode the dataset.

    For more information on `multipart/form-data` in general, please refer to the RFC-2388 and RFC-2045 specs as well
    and the w3 form documentation.

    - https://www.ietf.org/rfc/rfc2388.txt
    - https://www.ietf.org/rfc/rfc2045.txt
    - https://www.w3.org/TR/html401/interact/forms.html#h-17.13
*/
public class MultipartFormData {

    // MARK: - Helper Types

    /**
        Used to specify whether encoding was successful.
    */
    public enum EncodingResult {
        case Success(NSData)
        case Failure(NSError)
    }

    struct EncodingCharacters {
        static let CRLF = "\r\n"
    }

    struct BoundaryGenerator {
        enum BoundaryType {
            case Initial, Encapsulated, Final
        }

        static func randomBoundary() -> String {
            return String(format: "alamofire.boundary.%08x%08x", arc4random(), arc4random())
        }

        static func boundaryData(boundaryType boundaryType: BoundaryType, boundary: String) -> NSData {
            let boundaryText: String

            switch boundaryType {
            case .Initial:
                boundaryText = "--\(boundary)\(EncodingCharacters.CRLF)"
            case .Encapsulated:
                boundaryText = "\(EncodingCharacters.CRLF)--\(boundary)\(EncodingCharacters.CRLF)"
            case .Final:
                boundaryText = "\(EncodingCharacters.CRLF)--\(boundary)--\(EncodingCharacters.CRLF)"
            }

            return boundaryText.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)!
        }
    }

    class BodyPart {
        let headers: [String: String]
        let bodyStream: NSInputStream
        let bodyContentLength: UInt64
        var hasInitialBoundary = false
        var hasFinalBoundary = false

        init(headers: [String: String], bodyStream: NSInputStream, bodyContentLength: UInt64) {
            self.headers = headers
            self.bodyStream = bodyStream
            self.bodyContentLength = bodyContentLength
        }
    }

    // MARK: - Properties

    /// The `Content-Type` header value containing the boundary used to generate the `multipart/form-data`.
    public var contentType: String { return "multipart/form-data; boundary=\(boundary)" }

    /// The content length of all body parts used to generate the `multipart/form-data` not including the boundaries.
    public var contentLength: UInt64 { return bodyParts.reduce(0) { $0 + $1.bodyContentLength } }

    /// The boundary used to separate the body parts in the encoded form data.
    public let boundary: String

    private var bodyParts: [BodyPart]
    private var bodyPartError: NSError?
    private let streamBufferSize: Int

    // MARK: - Lifecycle

    /**
        Creates a multipart form data object.

        - returns: The multipart form data object.
    */
    public init() {
        self.boundary = BoundaryGenerator.randomBoundary()
        self.bodyParts = []

        /**
         *  The optimal read/write buffer size in bytes for input and output streams is 1024 (1KB). For more 
         *  information, please refer to the following article:
         *    - https://developer.apple.com/library/mac/documentation/Cocoa/Conceptual/Streams/Articles/ReadingInputStreams.html
         */

        self.streamBufferSize = 1024
    }

    // MARK: - Body Parts

    /**
        Creates a body part from the data and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - `Content-Disposition: form-data; name=#{name}` (HTTP Header)
        - Encoded data
        - Multipart form boundary

        - parameter data: The data to encode into the multipart form data.
        - parameter name: The name to associate with the data in the `Content-Disposition` HTTP header.
    */
    public func appendBodyPart(data data: NSData, name: String) {
        let headers = contentHeaders(name: name)
        let stream = NSInputStream(data: data)
        let length = UInt64(data.length)

        appendBodyPart(stream: stream, length: length, headers: headers)
    }

    /**
        Creates a body part from the data and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - `Content-Disposition: form-data; name=#{name}` (HTTP Header)
        - `Content-Type: #{generated mimeType}` (HTTP Header)
        - Encoded data
        - Multipart form boundary

        - parameter data: The data to encode into the multipart form data.
        - parameter name: The name to associate with the data in the `Content-Disposition` HTTP header.
        - parameter mimeType: The MIME type to associate with the data content type in the `Content-Type` HTTP header.
    */
    public func appendBodyPart(data data: NSData, name: String, mimeType: String) {
        let headers = contentHeaders(name: name, mimeType: mimeType)
        let stream = NSInputStream(data: data)
        let length = UInt64(data.length)

        appendBodyPart(stream: stream, length: length, headers: headers)
    }

    /**
        Creates a body part from the data and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - `Content-Disposition: form-data; name=#{name}; filename=#{filename}` (HTTP Header)
        - `Content-Type: #{mimeType}` (HTTP Header)
        - Encoded file data
        - Multipart form boundary

        - parameter data:     The data to encode into the multipart form data.
        - parameter name:     The name to associate with the data in the `Content-Disposition` HTTP header.
        - parameter fileName: The filename to associate with the data in the `Content-Disposition` HTTP header.
        - parameter mimeType: The MIME type to associate with the data in the `Content-Type` HTTP header.
    */
    public func appendBodyPart(data data: NSData, name: String, fileName: String, mimeType: String) {
        let headers = contentHeaders(name: name, fileName: fileName, mimeType: mimeType)
        let stream = NSInputStream(data: data)
        let length = UInt64(data.length)

        appendBodyPart(stream: stream, length: length, headers: headers)
    }

    /**
        Creates a body part from the file and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - `Content-Disposition: form-data; name=#{name}; filename=#{generated filename}` (HTTP Header)
        - `Content-Type: #{generated mimeType}` (HTTP Header)
        - Encoded file data
        - Multipart form boundary

        The filename in the `Content-Disposition` HTTP header is generated from the last path component of the
        `fileURL`. The `Content-Type` HTTP header MIME type is generated by mapping the `fileURL` extension to the
        system associated MIME type.

        - parameter fileURL: The URL of the file whose content will be encoded into the multipart form data.
        - parameter name:    The name to associate with the file content in the `Content-Disposition` HTTP header.
    */
    public func appendBodyPart(fileURL fileURL: NSURL, name: String) {
        if let
            fileName = fileURL.lastPathComponent,
            pathExtension = fileURL.pathExtension
        {
            let mimeType = mimeTypeForPathExtension(pathExtension)
            appendBodyPart(fileURL: fileURL, name: name, fileName: fileName, mimeType: mimeType)
        } else {
            let failureReason = "Failed to extract the fileName of the provided URL: \(fileURL)"
            let userInfo = [NSLocalizedFailureReasonErrorKey: failureReason]
            let error = NSError(domain: AlamofireErrorDomain, code: NSURLErrorBadURL, userInfo: userInfo)

            setBodyPartError(error)
        }
    }

    /**
        Creates a body part from the file and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - Content-Disposition: form-data; name=#{name}; filename=#{filename} (HTTP Header)
        - Content-Type: #{mimeType} (HTTP Header)
        - Encoded file data
        - Multipart form boundary

        - parameter fileURL:  The URL of the file whose content will be encoded into the multipart form data.
        - parameter name:     The name to associate with the file content in the `Content-Disposition` HTTP header.
        - parameter fileName: The filename to associate with the file content in the `Content-Disposition` HTTP header.
        - parameter mimeType: The MIME type to associate with the file content in the `Content-Type` HTTP header.
    */
    public func appendBodyPart(fileURL fileURL: NSURL, name: String, fileName: String, mimeType: String) {
        let headers = contentHeaders(name: name, fileName: fileName, mimeType: mimeType)

        //============================================================
        //                 Check 1 - is file URL?
        //============================================================

        guard fileURL.fileURL else {
            let failureReason = "The file URL does not point to a file URL: \(fileURL)"
            let error = errorWithCode(NSURLErrorBadURL, failureReason: failureReason)
            setBodyPartError(error)
            return
        }

        //============================================================
        //              Check 2 - is file URL reachable?
        //============================================================

        var isReachable = false

        do {
            try fileURL.checkResourceIsReachable()
            isReachable = true
        } catch {
            // No-op
        }

        guard isReachable else {
            let error = errorWithCode(NSURLErrorBadURL, failureReason: "The file URL is not reachable: \(fileURL)")
            setBodyPartError(error)
            return
        }

        //============================================================
        //            Check 3 - is file URL a directory?
        //============================================================

        var isDirectory: ObjCBool = false

        guard let
            path = fileURL.path
            where NSFileManager.defaultManager().fileExistsAtPath(path, isDirectory: &isDirectory) && !isDirectory else
        {
            let failureReason = "The file URL is a directory, not a file: \(fileURL)"
            let error = errorWithCode(NSURLErrorBadURL, failureReason: failureReason)
            setBodyPartError(error)
            return
        }

        //============================================================
        //          Check 4 - can the file size be extracted?
        //============================================================

        var bodyContentLength: UInt64?

        do {
            if let
                path = fileURL.path,
                fileSize = try NSFileManager.defaultManager().attributesOfItemAtPath(path)[NSFileSize] as? NSNumber
            {
                bodyContentLength = fileSize.unsignedLongLongValue
            }
        } catch {
            // No-op
        }

        guard let length = bodyContentLength else {
            let failureReason = "Could not fetch attributes from the file URL: \(fileURL)"
            let error = errorWithCode(NSURLErrorBadURL, failureReason: failureReason)
            setBodyPartError(error)
            return
        }

        //============================================================
        //       Check 5 - can a stream be created from file URL?
        //============================================================

        guard let stream = NSInputStream(URL: fileURL) else {
            let failureReason = "Failed to create an input stream from the file URL: \(fileURL)"
            let error = errorWithCode(NSURLErrorCannotOpenFile, failureReason: failureReason)
            setBodyPartError(error)
            return
        }

        appendBodyPart(stream: stream, length: length, headers: headers)
    }

    /**
        Creates a body part from the stream and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - `Content-Disposition: form-data; name=#{name}; filename=#{filename}` (HTTP Header)
        - `Content-Type: #{mimeType}` (HTTP Header)
        - Encoded stream data
        - Multipart form boundary

        - parameter stream:   The input stream to encode in the multipart form data.
        - parameter length:   The content length of the stream.
        - parameter name:     The name to associate with the stream content in the `Content-Disposition` HTTP header.
        - parameter fileName: The filename to associate with the stream content in the `Content-Disposition` HTTP header.
        - parameter mimeType: The MIME type to associate with the stream content in the `Content-Type` HTTP header.
    */
    public func appendBodyPart(stream stream: NSInputStream, length: UInt64, name: String, fileName: String, mimeType: String) {
        let headers = contentHeaders(name: name, fileName: fileName, mimeType: mimeType)
        appendBodyPart(stream: stream, length: length, headers: headers)
    }

    /**
        Creates a body part with the headers, stream and length and appends it to the multipart form data object.

        The body part data will be encoded using the following format:

        - HTTP headers
        - Encoded stream data
        - Multipart form boundary

        - parameter stream:  The input stream to encode in the multipart form data.
        - parameter length:  The content length of the stream.
        - parameter headers: The HTTP headers for the body part.
    */
    public func appendBodyPart(stream stream: NSInputStream, length: UInt64, headers: [String: String]) {
        let bodyPart = BodyPart(headers: headers, bodyStream: stream, bodyContentLength: length)
        bodyParts.append(bodyPart)
    }

    // MARK: - Data Encoding

    /**
        Encodes all the appended body parts into a single `NSData` object.

        It is important to note that this method will load all the appended body parts into memory all at the same 
        time. This method should only be used when the encoded data will have a small memory footprint. For large data 
        cases, please use the `writeEncodedDataToDisk(fileURL:completionHandler:)` method.

        - returns: EncodingResult containing an `NSData` object if the encoding succeeded, an `NSError` otherwise.
    */
    public func encode() -> EncodingResult {
        if let bodyPartError = bodyPartError {
            return .Failure(bodyPartError)
        }

        let encoded = NSMutableData()

        bodyParts.first?.hasInitialBoundary = true
        bodyParts.last?.hasFinalBoundary = true

        for bodyPart in bodyParts {
            let encodedDataResult = encodeBodyPart(bodyPart)

            switch encodedDataResult {
            case .Failure:
                return encodedDataResult
            case let .Success(data):
                encoded.appendData(data)
            }
        }

        return .Success(encoded)
    }

    /**
        Writes the appended body parts into the given file URL asynchronously and calls the `completionHandler`
        when finished.

        This process is facilitated by reading and writing with input and output streams, respectively. Thus,
        this approach is very memory efficient and should be used for large body part data.

        - parameter fileURL:           The file URL to write the multipart form data into.
        - parameter completionHandler: A closure to be executed when writing is finished.
    */
    public func writeEncodedDataToDisk(fileURL: NSURL, completionHandler: (NSError?) -> Void) {
        if let bodyPartError = bodyPartError {
            completionHandler(bodyPartError)
            return
        }

        var error: NSError?

        if let path = fileURL.path where NSFileManager.defaultManager().fileExistsAtPath(path) {
            let failureReason = "A file already exists at the given file URL: \(fileURL)"
            error = errorWithCode(NSURLErrorBadURL, failureReason: failureReason)
        } else if !fileURL.fileURL {
            let failureReason = "The URL does not point to a valid file: \(fileURL)"
            error = errorWithCode(NSURLErrorBadURL, failureReason: failureReason)
        }

        if let error = error {
            completionHandler(error)
            return
        }

        let outputStream: NSOutputStream

        if let possibleOutputStream = NSOutputStream(URL: fileURL, append: false) {
            outputStream = possibleOutputStream
        } else {
            let failureReason = "Failed to create an output stream with the given URL: \(fileURL)"
            let error = errorWithCode(NSURLErrorCannotOpenFile, failureReason: failureReason)

            completionHandler(error)
            return
        }

        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) {
            outputStream.scheduleInRunLoop(NSRunLoop.currentRunLoop(), forMode: NSDefaultRunLoopMode)
            outputStream.open()

            self.bodyParts.first?.hasInitialBoundary = true
            self.bodyParts.last?.hasFinalBoundary = true

            var error: NSError?

            for bodyPart in self.bodyParts {
                if let writeError = self.writeBodyPart(bodyPart, toOutputStream: outputStream) {
                    error = writeError
                    break
                }
            }

            outputStream.close()
            outputStream.removeFromRunLoop(NSRunLoop.currentRunLoop(), forMode: NSDefaultRunLoopMode)

            dispatch_async(dispatch_get_main_queue()) {
                completionHandler(error)
            }
        }
    }

    // MARK: - Private - Body Part Encoding

    private func encodeBodyPart(bodyPart: BodyPart) -> EncodingResult {
        let encoded = NSMutableData()

        let initialData = bodyPart.hasInitialBoundary ? initialBoundaryData() : encapsulatedBoundaryData()
        encoded.appendData(initialData)

        let headerData = encodeHeaderDataForBodyPart(bodyPart)
        encoded.appendData(headerData)

        let bodyStreamResult = encodeBodyStreamDataForBodyPart(bodyPart)

        switch bodyStreamResult {
        case .Failure:
            return bodyStreamResult
        case let .Success(data):
            encoded.appendData(data)
        }

        if bodyPart.hasFinalBoundary {
            encoded.appendData(finalBoundaryData())
        }

        return .Success(encoded)
    }

    private func encodeHeaderDataForBodyPart(bodyPart: BodyPart) -> NSData {
        var headerText = ""

        for (key, value) in bodyPart.headers {
            headerText += "\(key): \(value)\(EncodingCharacters.CRLF)"
        }
        headerText += EncodingCharacters.CRLF

        return headerText.dataUsingEncoding(NSUTF8StringEncoding, allowLossyConversion: false)!
    }

    private func encodeBodyStreamDataForBodyPart(bodyPart: BodyPart) -> EncodingResult {
        let inputStream = bodyPart.bodyStream
        inputStream.scheduleInRunLoop(NSRunLoop.currentRunLoop(), forMode: NSDefaultRunLoopMode)
        inputStream.open()

        var error: NSError?
        let encoded = NSMutableData()

        while inputStream.hasBytesAvailable {
            var buffer = [UInt8](count: streamBufferSize, repeatedValue: 0)
            let bytesRead = inputStream.read(&buffer, maxLength: streamBufferSize)

            if inputStream.streamError != nil {
                error = inputStream.streamError
                break
            }

            if bytesRead > 0 {
                encoded.appendBytes(buffer, length: bytesRead)
            } else if bytesRead < 0 {
                let failureReason = "Failed to read from input stream: \(inputStream)"
                error = errorWithCode(AlamofireInputStreamReadFailed, failureReason: failureReason)
                break
            } else {
                break
            }
        }

        inputStream.close()
        inputStream.removeFromRunLoop(NSRunLoop.currentRunLoop(), forMode: NSDefaultRunLoopMode)

        if let error = error {
            return .Failure(error)
        }

        return .Success(encoded)
    }

    // MARK: - Private - Writing Body Part to Output Stream

    private func writeBodyPart(bodyPart: BodyPart, toOutputStream outputStream: NSOutputStream) -> NSError? {
        if let error = writeInitialBoundaryDataForBodyPart(bodyPart, toOutputStream: outputStream) {
            return error
        }

        if let error = writeHeaderDataForBodyPart(bodyPart, toOutputStream: outputStream) {
            return error
        }

        if let error = writeBodyStreamForBodyPart(bodyPart, toOutputStream: outputStream) {
            return error
        }

        if let error = writeFinalBoundaryDataForBodyPart(bodyPart, toOutputStream: outputStream) {
            return error
        }

        return nil
    }

    private func writeInitialBoundaryDataForBodyPart(bodyPart: BodyPart, toOutputStream outputStream: NSOutputStream) -> NSError? {
        let initialData = bodyPart.hasInitialBoundary ? initialBoundaryData() : encapsulatedBoundaryData()
        return writeData(initialData, toOutputStream: outputStream)
    }

    private func writeHeaderDataForBodyPart(bodyPart: BodyPart, toOutputStream outputStream: NSOutputStream) -> NSError? {
        let headerData = encodeHeaderDataForBodyPart(bodyPart)
        return writeData(headerData, toOutputStream: outputStream)
    }

    private func writeBodyStreamForBodyPart(bodyPart: BodyPart, toOutputStream outputStream: NSOutputStream) -> NSError? {
        var error: NSError?

        let inputStream = bodyPart.bodyStream
        inputStream.scheduleInRunLoop(NSRunLoop.currentRunLoop(), forMode: NSDefaultRunLoopMode)
        inputStream.open()

        while inputStream.hasBytesAvailable {
            var buffer = [UInt8](count: streamBufferSize, repeatedValue: 0)
            let bytesRead = inputStream.read(&buffer, maxLength: streamBufferSize)

            if inputStream.streamError != nil {
                error = inputStream.streamError
                break
            }

            if bytesRead > 0 {
                if buffer.count != bytesRead {
                    buffer = Array(buffer[0..<bytesRead])
                }

                if let writeError = writeBuffer(&buffer, toOutputStream: outputStream) {
                    error = writeError
                    break
                }
            } else if bytesRead < 0 {
                let failureReason = "Failed to read from input stream: \(inputStream)"
                error = errorWithCode(AlamofireInputStreamReadFailed, failureReason: failureReason)
                break
            } else {
                break
            }
        }

        inputStream.close()
        inputStream.removeFromRunLoop(NSRunLoop.currentRunLoop(), forMode: NSDefaultRunLoopMode)

        return error
    }

    private func writeFinalBoundaryDataForBodyPart(bodyPart: BodyPart, toOutputStream outputStream: NSOutputStream) -> NSError? {
        if bodyPart.hasFinalBoundary {
            return writeData(finalBoundaryData(), toOutputStream: outputStream)
        }

        return nil
    }

    // MARK: - Private - Writing Buffered Data to Output Stream

    private func writeData(data: NSData, toOutputStream outputStream: NSOutputStream) -> NSError? {
        var buffer = [UInt8](count: data.length, repeatedValue: 0)
        data.getBytes(&buffer, length: data.length)

        return writeBuffer(&buffer, toOutputStream: outputStream)
    }

    private func writeBuffer(inout buffer: [UInt8], toOutputStream outputStream: NSOutputStream) -> NSError? {
        var error: NSError?

        var bytesToWrite = buffer.count

        while bytesToWrite > 0 {
            if outputStream.hasSpaceAvailable {
                let bytesWritten = outputStream.write(buffer, maxLength: bytesToWrite)

                if outputStream.streamError != nil {
                    error = outputStream.streamError
                    break
                }

                if bytesWritten < 0 {
                    let failureReason = "Failed to write to output stream: \(outputStream)"
                    error = errorWithCode(AlamofireOutputStreamWriteFailed, failureReason: failureReason)
                    break
                }

                bytesToWrite -= bytesWritten

                if bytesToWrite > 0 {
                    buffer = Array(buffer[bytesWritten..<buffer.count])
                }
            } else if outputStream.streamError != nil {
                error = outputStream.streamError
                break
            }
        }

        return error
    }

    // MARK: - Private - Mime Type

    private func mimeTypeForPathExtension(pathExtension: String) -> String {
        if let
            id = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, pathExtension, nil)?.takeRetainedValue(),
            contentType = UTTypeCopyPreferredTagWithClass(id, kUTTagClassMIMEType)?.takeRetainedValue()
        {
            return contentType as String
        }

        return "application/octet-stream"
    }

    // MARK: - Private - Content Headers

    private func contentHeaders(name name: String) -> [String: String] {
        return ["Content-Disposition": "form-data; name=\"\(name)\""]
    }

    private func contentHeaders(name name: String, mimeType: String) -> [String: String] {
        return [
            "Content-Disposition": "form-data; name=\"\(name)\"",
            "Content-Type": "\(mimeType)"
        ]
    }

    private func contentHeaders(name name: String, fileName: String, mimeType: String) -> [String: String] {
        return [
            "Content-Disposition": "form-data; name=\"\(name)\"; filename=\"\(fileName)\"",
            "Content-Type": "\(mimeType)"
        ]
    }

    // MARK: - Private - Boundary Encoding

    private func initialBoundaryData() -> NSData {
        return BoundaryGenerator.boundaryData(boundaryType: .Initial, boundary: boundary)
    }

    private func encapsulatedBoundaryData() -> NSData {
        return BoundaryGenerator.boundaryData(boundaryType: .Encapsulated, boundary: boundary)
    }

    private func finalBoundaryData() -> NSData {
        return BoundaryGenerator.boundaryData(boundaryType: .Final, boundary: boundary)
    }

    // MARK: - Private - Errors

    private func setBodyPartError(error: NSError) {
        if bodyPartError == nil {
            bodyPartError = error
        }
    }

    private func errorWithCode(code: Int, failureReason: String) -> NSError {
        let userInfo = [NSLocalizedFailureReasonErrorKey: failureReason]
        return NSError(domain: AlamofireErrorDomain, code: code, userInfo: userInfo)
    }
}
