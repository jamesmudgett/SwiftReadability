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
    
    private func makeReadabilityCallback(url: URL) -> ((String?, Error?) -> Void) {
        return { (content: String?, error: Error?) in
            guard let content = content else {
                print(error?.localizedDescription)
                return
            }
            
            DispatchQueue.main.async { [weak self] in
                _ = self?.webView.loadHTMLString(content, baseURL: url)
                self?.inProgressReadability = nil
            }
        }
    }
    
    public func loadURL(url: URL) {
        inProgressReadability = Readability(url: url, conversionTime: .atDocumentEnd, suppressSubresourceLoadingDuringConversion: .all, completionHandler: makeReadabilityCallback(url: url))
    }
    
    public func loadHTML(html: String, withBaseURL url: URL) {
        inProgressReadability = Readability(html: html, conversionTime: .atDocumentEnd, suppressSubresourceLoadingDuringConversion: .all, completionHandler: makeReadabilityCallback(url: url))
    }
}
