//
//  Readability.swift
//  SwiftReadability
//
//  Created by Chloe on 2016-06-20.
//  Copyright © 2016 Chloe Horgan. All rights reserved.
//

import Foundation
import WebKit
import SwiftSoup

public enum ReadabilityError: Error {
    case unableToParseScriptResult(rawResult: String?)
    case decodingFailure
    case loadingFailure
}

public enum ReadabilityConversionTime {
    case atDocumentEnd
    case atNavigationFinished
}

public enum ReadabilitySubresourceSuppressionType {
    case none
    case all
    case allExceptScripts
    case imagesOnly
}

private let tagsWithSubresourcesToStrip = ["script", "style"]
private let tagsWithExternalSubresourcesViaSrc = ["img", "embed", "object", "audio", "iframe"]
private let tagsWithExternalSubresourcesViaHref = ["link", "a"]

fileprivate let HTMLDownloadProgressEndsAt = 0.75
fileprivate let RawPageLoadingProgressEndsAt = 0.9

public class Readability: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView: WKWebView
    private let completionHandler: ((_ content: String?, _ error: Error?) -> Void)
    private var isRenderingReadabilityHTML = false
    private var hasRenderedReadabilityHTML = false
    private let conversionTime: ReadabilityConversionTime
    private let suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType
    private var allowNavigationFailures = 0
    
    fileprivate var webViewProgressStartsFrom: Double = 0.0
    fileprivate var webViewProgressEndsAt: Double = 1.0
    fileprivate var progressCallback: ((_ estimatedProgress: Double) -> Void)?
    fileprivate var downloadBuffer = Data()
    fileprivate var expectedContentLength = 0
    fileprivate var htmlDownloadCompletionHandler: ((String?, Error?) -> Void)?
    
    public init(conversionTime: ReadabilityConversionTime = .atDocumentEnd, suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType = .none, completionHandler: @escaping (_ content: String?, _ error: Error?) -> Void, progressCallback: ((_ estimatedProgress: Double) -> Void)? = nil) {
        let webView = WKWebView(frame: CGRect.zero, configuration: WKWebViewConfiguration())
        
        func completionHandlerWrapper(_ content: String?, _ error: Error?) {
            // See: https://stackoverflow.com/a/32443423/89373
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "readabilityJavascriptLoaded")
            completionHandler(content, error)
        }
        
        self.progressCallback = progressCallback
        self.completionHandler = completionHandlerWrapper
        self.conversionTime = conversionTime
        self.suppressSubresourceLoadingDuringConversion = suppressSubresourceLoadingDuringConversion
        self.webView = webView
        
        super.init()
        
        webView.configuration.suppressesIncrementalRendering = true
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "readabilityJavascriptLoaded")
        webView.addObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress), options: .new, context: nil)
        
        addReadabilityUserScript()
    }
    
    public convenience init(url: URL, conversionTime: ReadabilityConversionTime = .atDocumentEnd, suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType = .none, completionHandler: @escaping (_ content: String?, _ error: Error?) -> Void, progressCallback: ((_ estimatedProgress: Double) -> Void)? = nil) {
        
        self.init(
            conversionTime: conversionTime,
            suppressSubresourceLoadingDuringConversion: suppressSubresourceLoadingDuringConversion,
            completionHandler: completionHandler,
            progressCallback: progressCallback)
        
        if suppressSubresourceLoadingDuringConversion != .none {
            webViewProgressEndsAt = HTMLDownloadProgressEndsAt
            
            downloadHTMLWithoutSubresources(url: url) { [weak self] (html, error) in
                guard let html = html, error == nil else {
                    completionHandler(nil, ReadabilityError.loadingFailure)
                    return
                }
                
                DispatchQueue.main.async { [weak self] in
                    self?.webView.loadHTMLString(html, baseURL: url)
                }
            }
        } else {
            webViewProgressEndsAt = RawPageLoadingProgressEndsAt
            
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }
    
    public convenience init(html: String, baseUrl: URL? = nil, conversionTime: ReadabilityConversionTime = .atDocumentEnd, suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType = .none, completionHandler: @escaping (_ content: String?, _ error: Error?) -> Void) {
        
        self.init(conversionTime: conversionTime, suppressSubresourceLoadingDuringConversion: suppressSubresourceLoadingDuringConversion, completionHandler: completionHandler)
        
        var htmlToLoad = html
        if suppressSubresourceLoadingDuringConversion != .none {
            guard let transformedHtml = suppressSubresources(html: html) else {
                completionHandler(nil, ReadabilityError.loadingFailure)
                return
            }
            htmlToLoad = transformedHtml
        }
        DispatchQueue.main.async { [weak self] in
            self?.webView.loadHTMLString(htmlToLoad, baseURL: baseUrl)
        }
    }
    
    deinit {
        webView.removeObserver(self, forKeyPath: #keyPath(WKWebView.estimatedProgress))
    }
    
    private func addReadabilityUserScript() {
        let script = ReadabilityUserScript(scriptInjectionTime: .atDocumentEnd)
        webView.configuration.userContentController.addUserScript(script)
    }
    
    private func downloadHTMLWithoutSubresources(url: URL, callbackHandler: @escaping (String?, Error?) -> Void) {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        
        htmlDownloadCompletionHandler = callbackHandler
        
        let task = session.dataTask(with: request)
        task.resume()
    }
    
    fileprivate func suppressSubresources(html: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html) else {
            print("Failed to parse HTML in order to strip subresources.")
            return nil
        }
        do {
            if suppressSubresourceLoadingDuringConversion == .all || suppressSubresourceLoadingDuringConversion == .allExceptScripts {
                let toStrip = suppressSubresourceLoadingDuringConversion == .allExceptScripts ? tagsWithSubresourcesToStrip.filter { $0 != "script" } : tagsWithSubresourcesToStrip
                for tagName in toStrip {
                    for tag in try doc.getElementsByTag(tagName) {
                        try tag.remove()
                    }
                }
            }
            
            let srcTags: [String]
            switch suppressSubresourceLoadingDuringConversion {
            case .imagesOnly: srcTags = ["img"]
            default: srcTags = tagsWithExternalSubresourcesViaSrc
            }
            for tagName in srcTags {
                for tag in try doc.getElementsByTag(tagName) {
                    if try tag.attr("src") != "" {
                        try tag.attr("data-swift-readability-src", tag.attr("src"))
                        if tagName == "img" {
                            try tag.attr("src", "")
                        } else {
                            try tag.removeAttr("src")
                        }
                    }
                }
            }
            if ![ReadabilitySubresourceSuppressionType.imagesOnly, ReadabilitySubresourceSuppressionType.none].contains(suppressSubresourceLoadingDuringConversion) {
                for tagName in tagsWithExternalSubresourcesViaHref {
                    for tag in try doc.getElementsByTag(tagName) {
                        try tag.attr("data-swift-readability-href", tag.attr("href"))
                        try tag.removeAttr("href")
                    }
                }
            }
            return try doc.outerHtml()
        } catch {
            print("Failed to reconstitute HTML in order to strip subresources.")
            return nil
        }
    }
    
    private func restoreSubresources(html: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html) else {
            print("Failed to parse HTML in order to restore subresources.")
            return nil
        }
        
        do {
            for tagName in tagsWithExternalSubresourcesViaSrc {
                for tag in try doc.getElementsByTag(tagName) {
                    try tag.attr("src", tag.attr("data-swift-readability-src"))
                    try tag.removeAttr("data-swift-readability-src")
                }
            }
            for tagName in tagsWithExternalSubresourcesViaHref {
                for tag in try doc.getElementsByTag(tagName) {
                    try tag.attr("href", tag.attr("data-swift-readability-href"))
                    try tag.removeAttr("data-swift-readability-href")
                }
            }
            return try doc.outerHtml()
        } catch {
            print("Failed to reconstitute HTML in order to restore subresources.")
            return nil
        }
    }
    
    private func renderHTML(readabilityTitle: String?, readabilityByline: String?, readabilityContent: String) -> String {
        do {
            let template = try loadFile(name: "Reader.template", type: "html")
            
            let mozillaCSS = try loadFile(name: "Reader", type: "css")
            let swiftReadabilityCSS = try loadFile(name: "SwiftReadability", type: "css")
            let css = mozillaCSS + swiftReadabilityCSS
            
            let html = template
                .replacingOccurrences(of: "##CSS##", with: css)
                .replacingOccurrences(of: "##TITLE##", with: readabilityTitle ?? "")
                .replacingOccurrences(of: "##BYLINE##", with: readabilityByline ?? "")
                .replacingOccurrences(of: "##CONTENT##", with: readabilityContent)
            
            return html
            
        } catch {
            // TODO: Need better error handling
            fatalError("Failed to render Readability HTML")
        }
    }
    
    private func initializeReadability(completionHandler: @escaping (_ html: String?, _ error: Error?) -> Void) {
        let readabilityInitializationJS: String
        do {
            readabilityInitializationJS = try loadFile(name: "readability_initialization", type: "js")
        } catch {
            fatalError("Couldn't load readability_initialization.js")
        }
        
        webView.evaluateJavaScript(readabilityInitializationJS) { [weak self] (result, error) in
            let parseError = ReadabilityError.unableToParseScriptResult(rawResult: result as? String)
            
            guard let resultData = (result as? String)?.data(using: .utf8) else {
                self?.completionHandler(nil, error)
                return
            }
            guard let jsonResultOptional = try? JSONSerialization.jsonObject(with: resultData, options: []), let jsonResult = jsonResultOptional as? [String: String?], let contentOptional = jsonResult["content"], var content = contentOptional, let titleOptional = jsonResult["title"], let bylineOptional = jsonResult["byline"] else {
                self?.completionHandler(nil, parseError)
                return
            }
            
            if (self?.suppressSubresourceLoadingDuringConversion ?? .none) != .none {
                guard let restoredSubresourcesContent = self?.restoreSubresources(html: content) else {
                    self?.completionHandler(nil, ReadabilityError.unableToParseScriptResult(rawResult: nil))
                    return
                }
                content = restoredSubresourcesContent
            }
            
            guard let html = self?.renderHTML(
                readabilityTitle: titleOptional,
                readabilityByline: bylineOptional,
                readabilityContent: content) else {
                    self?.completionHandler(nil, parseError)
                    return
            }
            completionHandler(html, nil)
        }
    }
    
    private func updateImageMargins(completionHandler: @escaping (_ html: String?, _ error: Error?) -> Void) {
        let readabilityImagesJS: String
        do {
            readabilityImagesJS = try loadFile(name: "readability_images", type: "js")
        } catch {
            fatalError("Couldn't load readability_images.js")
        }
        
        webView.evaluateJavaScript(readabilityImagesJS) { [weak self] (result, error) in
            guard let result = result as? String else {
                self?.completionHandler(nil, error)
                return
            }
            completionHandler(result, nil)
        }
    }
    
    private func rawPageFinishedLoading() {
        isRenderingReadabilityHTML = true
        initializeReadability() { [weak self] (html: String?, error: Error?) in
            self?.isRenderingReadabilityHTML = false
            self?.hasRenderedReadabilityHTML = true
            guard let html = html else {
                self?.completionHandler(nil, error)
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.webViewProgressStartsFrom = RawPageLoadingProgressEndsAt
                self?.webViewProgressEndsAt = 1.0
                self?.webView.configuration.userContentController.removeAllUserScripts()
                self?.webView.loadHTMLString(html, baseURL: self?.webView.url?.baseURL)
            }
        }
    }
    
    override public func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        if keyPath == "estimatedProgress" {
            let estimatedProgress = webView.estimatedProgress
            
            if let progressCallback = progressCallback {
                progressCallback(
                    webViewProgressStartsFrom + (webViewProgressEndsAt - webViewProgressStartsFrom) * estimatedProgress)
            }
        } else {
            super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
    }
    
    // MARK: WKScriptMessageHandler delegate
    
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "readabilityJavascriptLoaded" else {
            print("Unexpected script message name \(message.name)")
            return
        }
        
        if isRenderingReadabilityHTML || hasRenderedReadabilityHTML {
            return
        }
        
        if conversionTime == .atDocumentEnd {
            allowNavigationFailures += 1
            webView.stopLoading()
            rawPageFinishedLoading()
        }
    }
    
    //  MARK: WKNavigationDelegate
    
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if !(isRenderingReadabilityHTML || hasRenderedReadabilityHTML) {
            rawPageFinishedLoading()
        } else if !isRenderingReadabilityHTML {
            updateImageMargins() { [weak self] (html: String?, error: Error?) in
                self?.completionHandler(html, error)
            }
        }
    }
    
    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if allowNavigationFailures > 0 {
            allowNavigationFailures -= 1
        } else {
            completionHandler(nil, error)
        }
    }
}

extension Readability: URLSessionDataDelegate {
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        expectedContentLength = Int(response.expectedContentLength)
        
        completionHandler(.allow)
    }
    
    public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let progressCallback = progressCallback else { return }
        
        webViewProgressStartsFrom = HTMLDownloadProgressEndsAt
        
        // https://stackoverflow.com/a/45290601/89373
        downloadBuffer.append(data)
        let percentDownloaded = Double(downloadBuffer.count) / Double(expectedContentLength)
        progressCallback(percentDownloaded * HTMLDownloadProgressEndsAt)
    }
    
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let callbackHandler = htmlDownloadCompletionHandler else { return }
        
        guard error == nil else {
            callbackHandler(nil, error)
            return
        }
        
        var data = downloadBuffer
        
        guard let asciiHtml = String(data: data, encoding: .ascii), let doc = try? SwiftSoup.parse(asciiHtml) else {
            print("Failed to parse HTML in order to detect charset.")
            callbackHandler(nil, ReadabilityError.decodingFailure)
            return
        }
        var encoding = String.Encoding.utf8
        func updateEncoding(charset: String) {
            switch charset.lowercased() {
            case "shift_jis": encoding = String.Encoding.shiftJIS
            case "euc-jp": encoding = String.Encoding.japaneseEUC
            case "iso-2022-jp": encoding = String.Encoding.iso2022JP
            default: break
            }
        }
        if let contentType = try? doc.select("meta[http-equiv=content-type]").first()?.attr("content"), let charset = contentType?.lowercased().components(separatedBy: "charset=").last {
            updateEncoding(charset: charset)
        }
        if let charsetOptional = try? doc.select("meta[charset]").first()?.attr("charset"), let charset = charsetOptional {
            updateEncoding(charset: charset)
        }
        var html: String? = String(data: data, encoding: encoding)
        if html == nil {
            // https://stackoverflow.com/a/44611946/89373
            data.append(0)
            let s = data.withUnsafeBytes { (p: UnsafePointer<CChar>) in String(cString: p) }
            let clean = s.replacingOccurrences(of: "\u{FFFD}", with: "")
            html = clean
        }
        
        guard let cleanedHtml = html else {
            callbackHandler(nil, ReadabilityError.decodingFailure)
            return
        }
        
        guard let transformedHtml = suppressSubresources(html: cleanedHtml) else {
            callbackHandler(nil, ReadabilityError.decodingFailure)
            return
        }
        
        callbackHandler(transformedHtml, nil)
    }
}
