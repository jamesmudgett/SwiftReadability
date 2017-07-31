//
//  String+MalformedUnicode.swift
//  SwiftReadability
//
//  Created by Alex Ehlke on 2017-07-08.
//  Copyright © 2017 Chloe Horgan. All rights reserved.
//

import Foundation

// https://stackoverflow.com/a/44611946/89373
extension String {
    init(malformedData data: Data, encoding: String.Encoding) {
        var str = ""
        var iterator = data.makeIterator()
        var utf8codec = UTF8()
        var done = false
        while !done {
            switch utf8codec.decode(&iterator) {
            case .emptyInput:
                done = true
            case let .scalarValue(val):
                str.unicodeScalars.append(val)
            case .error:
                break // ignore errors
            }
        }
        self = str
    }
}
