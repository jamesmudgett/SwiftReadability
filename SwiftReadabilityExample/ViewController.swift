//
//  ViewController.swift
//  SwiftReadabilityExample
//
//  Created by Alex Ehlke on 2017-06-17.
//  Copyright © 2017 Chloe Horgan. All rights reserved.
//

import SwiftReadability
import UIKit

class ViewController: ReadabilityViewController {
    
    //    let articleURL = URL(string: "http://www.cnn.com/2016/06/27/foodanddrink/german-beer-purity-us-beer-gardens/index.html")
    //    let articleURL = URL(string: "https://ca.yahoo.com/?p=us")
    //    let articleURL = URL(string: "http://m.huffpost.com/jp/entry/16733188")//http://www.huffingtonpost.jp/2017/05/20/shogi-master-loses-to-ai_n_16733188.html")
//    let articleURL = URL(string: "http://www.huffingtonpost.jp/techcrunch-japan/amazon-is-gobbling-whole-foods-for-a-reported-13-7-billion_b_17171132.html?utm_hp_ref=japan&ir=Japan")
//    let articleURL = URL(string: "http://natgeo.nikkeibp.co.jp/atcl/news/16/c/061500045/?rss")
    let articleURL = URL(string: "https://github.com/blog/2195-the-shape-of-open-source")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        guard let articleURL = articleURL else { return }
        
        loadURL(url: articleURL)
    }
}
