//
//  ReadabilityViewController.swift
//  SwiftReadability
//
//  Created by Chloe on 2016-06-20.
//  Copyright © 2016 Chloe Horgan. All rights reserved.
//

import Foundation
import UIKit
import WebKit

open class ReadabilityViewController: UIViewController {
    let webView = WKWebView()
    private var inProgressReadability: Readability?
    
    override open func loadView() {
        view = webView
    }
    
    private func makeReadabilityCallback(url: URL, userCompletionHandler: ((_ content: String?, _ error: Error?) -> Void)? = nil) -> ((String?, Error?) -> Void) {
        return { (content: String?, error: Error?) in
            guard let content = content else {
                print(error?.localizedDescription as Any)
                if let userCompletionHandler = userCompletionHandler {
                    userCompletionHandler(nil, error)
                }
                return
            }
            
            DispatchQueue.main.async { [weak self] in
                _ = self?.webView.loadHTMLString(content, baseURL: url)
                self?.inProgressReadability = nil
                
                if let userCompletionHandler = userCompletionHandler {
                    userCompletionHandler(content, error)
                }
            }
        }
    }
    
    public func loadURL(url: URL, completionHandler: ((_ content: String?, _ error: Error?) -> Void)? = nil, progressCallback: ((_ estimatedProgress: Double) -> Void)? = nil) {
        inProgressReadability = Readability(
            url: url,
            conversionTime: .atDocumentEnd,
            suppressSubresourceLoadingDuringConversion: .all,
            completionHandler: makeReadabilityCallback(url: url, userCompletionHandler: completionHandler),
            progressCallback: progressCallback)
    }
    
    public func loadHTML(html: String, withBaseURL url: URL) {
        inProgressReadability = Readability(html: html, conversionTime: .atDocumentEnd, suppressSubresourceLoadingDuringConversion: .all, completionHandler: makeReadabilityCallback(url: url))
    }
}
