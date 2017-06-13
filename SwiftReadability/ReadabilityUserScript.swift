//
//  ReadabilityUserScript.swift
//  SwiftReadability
//
//  Created by Chloe on 2016-06-22.
//  Copyright © 2016 Chloe Horgan. All rights reserved.
//

import Foundation
import WebKit

class ReadabilityUserScript: WKUserScript {
    convenience init(scriptInjectionTime: WKUserScriptInjectionTime) {
        let js: String
        do {
            js = (
                try loadFile(name: "Readability", type: "js")
                + "\nwindow.webkit.messageHandlers.readabilityJavascriptLoaded.postMessage({})"
            )
        } catch {
            fatalError("Couldn't load Readability.js")
        }
        
        self.init(source: js, injectionTime: scriptInjectionTime, forMainFrameOnly: true)
    }
}
