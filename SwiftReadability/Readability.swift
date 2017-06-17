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
    case loadingFailure
}

public enum ReadabilityConversionTime {
    case atDocumentStart
    case atDocumentEnd
}

private let tagsWithExternalSubresourcesViaSrc = ["img", "embed", "object", "script", "audio", "iframe"]
private let tagsWithExternalSubresourcesViaHref = ["link", "a", "style"]

public class Readability: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let webView: WKWebView
    private let completionHandler: ((_ content: String?, _ error: Error?) -> Void)
    private var hasRenderedReadabilityHTML = false
    private let conversionTime: ReadabilityConversionTime
    private let suppressSubresourceLoadingDuringConversion: Bool
    
    public init(url: URL, conversionTime: ReadabilityConversionTime = .atDocumentEnd, suppressSubresourceLoadingDuringConversion: Bool = false, completionHandler: @escaping (_ content: String?, _ error: Error?) -> Void) {

        self.completionHandler = completionHandler
        self.conversionTime = conversionTime
        self.suppressSubresourceLoadingDuringConversion = suppressSubresourceLoadingDuringConversion
        
        webView = WKWebView(frame: CGRect.zero, configuration: WKWebViewConfiguration())
        
        super.init()
        
        webView.configuration.suppressesIncrementalRendering = true
        webView.navigationDelegate = self
        
        addReadabilityUserScript()
        
        if suppressSubresourceLoadingDuringConversion {
            downloadHTMLWithoutSubresources(url: url) { [weak self] (html, error) in
                guard let html = html, error == nil else {
                    completionHandler(nil, ReadabilityError.loadingFailure)
                    return
                }
                self?.webView.loadHTMLString(html, baseURL: url)
            }
        } else {
            let request = URLRequest(url: url)
            webView.load(request)
        }
    }
    
    private func addReadabilityUserScript() {
        let script = ReadabilityUserScript(scriptInjectionTime: conversionTime == .atDocumentStart ? WKUserScriptInjectionTime.atDocumentStart : WKUserScriptInjectionTime.atDocumentEnd)
        webView.configuration.userContentController.addUserScript(script)
    }
    
    private func downloadHTMLWithoutSubresources(url: URL, callbackHandler: @escaping (String?, Error?) -> Void) {
        let session = URLSession(configuration: .default)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        
        let task = session.dataTask(with: request) { [weak self] (data, response, error) in
            guard let data = data, error == nil else {
                callbackHandler(nil, error)
                return
            }
            guard let html = String(data: data, encoding: .utf8), let transformedHtml = self?.suppressSubresources(html: html) else {
                callbackHandler(nil, ReadabilityError.unableToParseScriptResult(rawResult: nil))
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
            for tagName in tagsWithExternalSubresourcesViaSrc {
                for tag in try doc.getElementsByTag(tagName) {
                    try tag.attr("data-swift-readability-src", tag.attr("src"))
                    try tag.removeAttr("src")
                }
            }
            for tagName in tagsWithExternalSubresourcesViaHref {
                for tag in try doc.getElementsByTag(tagName) {
                    try tag.attr("data-swift-readability-href", tag.attr("href"))
                    try tag.removeAttr("href")
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
            
            if self?.suppressSubresourceLoadingDuringConversion ?? false {
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
            _ = self?.webView.loadHTMLString(html, baseURL: self?.webView.url?.baseURL)
        }
    }
    
    // MARK: WKScriptMessageHandler delegate
    
    public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "readabilityJavascriptLoaded" else {
            print("Unexpected script message name \(message.name)")
            return
        }
        
        if conversionTime == .atDocumentStart {
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
        completionHandler(nil, error)
    }
}


