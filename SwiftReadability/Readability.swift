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

private let tagsWithExternalSubresourcesViaSrc = ["img", "embed", "object", "script", "audio", "iframe"]
private let tagsWithExternalSubresourcesViaHref = ["link", "a", "style"]

public class Readability: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView: WKWebView
    private let completionHandler: ((_ content: String?, _ error: Error?) -> Void)
    private var hasRenderedReadabilityHTML = false
    private let conversionTime: ReadabilityConversionTime
    private let suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType
    private var allowNavigationFailures = 0
    
    public init(url: URL, conversionTime: ReadabilityConversionTime = .atDocumentEnd, suppressSubresourceLoadingDuringConversion: ReadabilitySubresourceSuppressionType = .none, completionHandler: @escaping (_ content: String?, _ error: Error?) -> Void) {
        
        self.completionHandler = completionHandler
        self.conversionTime = conversionTime
        self.suppressSubresourceLoadingDuringConversion = suppressSubresourceLoadingDuringConversion
        
        webView = WKWebView(frame: CGRect.zero, configuration: WKWebViewConfiguration())
        
        super.init()
        
        webView.configuration.suppressesIncrementalRendering = true
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "readabilityJavascriptLoaded")
        
        addReadabilityUserScript()
        
        if suppressSubresourceLoadingDuringConversion != .none {
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
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }
    
    private func addReadabilityUserScript() {
        let script = ReadabilityUserScript(scriptInjectionTime: .atDocumentEnd)
        webView.configuration.userContentController.addUserScript(script)
    }
    
    private func downloadHTMLWithoutSubresources(url: URL, callbackHandler: @escaping (String?, Error?) -> Void) {
        let session = URLSession(configuration: .default)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        let task = session.dataTask(with: request) { [weak self] (data, response, error) in
            guard var data = data, error == nil else {
                callbackHandler(nil, error)
                return
            }
            
            var html: String? = String(data: data, encoding: .utf8)
            if html == nil {
                // https://stackoverflow.com/a/44611946/89373
                data.append(0)
                let s = data.withUnsafeBytes { (p: UnsafePointer<CChar>) in String(cString: p) }
                let clean = s.replacingOccurrences(of: "\u{FFFD}", with: "")
                html = clean
            }
            
            guard let cleanedHtml = html, let transformedHtml = self?.suppressSubresources(html: cleanedHtml) else {
                callbackHandler(nil, ReadabilityError.decodingFailure)
                return
            }
            callbackHandler(transformedHtml, nil)
        }
        task.resume()
    }
    
    private func suppressSubresources(html: String) -> String? {
        guard let doc = try? SwiftSoup.parse(html) else {
            print("Failed to parse HTML in order to strip subresources.")
            return nil
        }
        
        do {
            let srcTags: [String]
            switch suppressSubresourceLoadingDuringConversion {
            case .allExceptScripts: srcTags = tagsWithExternalSubresourcesViaSrc.filter { $0 != "script" }
            case .imagesOnly: srcTags = ["img"]
            default: srcTags = tagsWithExternalSubresourcesViaSrc
            }
            for tagName in srcTags {
                for tag in try doc.getElementsByTag(tagName) {
                    try tag.attr("data-swift-readability-src", tag.attr("src"))
                    try tag.removeAttr("src")
                }
            }
            if suppressSubresourceLoadingDuringConversion == .all {
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
        initializeReadability() { [weak self] (html: String?, error: Error?) in
            self?.hasRenderedReadabilityHTML = true
            guard let html = html else {
                self?.completionHandler(nil, error)
                return
            }
            DispatchQueue.main.async { [weak self] in
                self?.webView.loadHTMLString(html, baseURL: self?.webView.url?.baseURL)
            }
        }
    }
    
    // MARK: WKScriptMessageHandler delegate
    
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "readabilityJavascriptLoaded" else {
            print("Unexpected script message name \(message.name)")
            return
        }
        
        if hasRenderedReadabilityHTML {
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
        if !hasRenderedReadabilityHTML {
            rawPageFinishedLoading()
        } else {
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

